# LoRA Fleet Lifecycle Management — Design Notes & ADRs

Working notes plus architecture decisions. Claims marked **[verify]** are reasoned
from architecture or secondary sources, not confirmed against current source —
check these before committing to a design that depends on them.

All external references are collected with links in [§13 References](#13-references).

---

## 0. TL;DR

- **Vocabulary is broken and it hides real gaps.** "Pod" means two different things
  in the requirements. Split into *endpoint* (routing) and *serving instance* (one
  vLLM engine, one adapter cache, one `max_loras` budget). Fixing this generalises
  the MoE requirement and exposes a missing prefill/decode requirement. → ADR-001
- **Three loops, one homeless.** Dispatch (µs, scheduler — exists) and declaration
  (minutes, controller) are fine. Shard management (~seconds, on churn) has no
  home. Both prior attempts died trying to squash it into an end. → ADR-002
- **`minWarmReplicas` cannot be guaranteed today.** Only "achieve" is available;
  retain, detect, restore, verify are blocked upstream. Honest ceiling is "usually
  warm." → §4, ADR-008
- **The pin API is the missing requirement**, and it is unfiled. **[verify]**
- **Loading executes lazily in the engine**, not pushed by a controller. The
  resolver turns placement into a consequence of routing. → ADR-004
- **Phase 0 has no upstream dependencies.** Blind consistent-hash sharding needs
  only endpoint enumeration and adapter-aware dispatch, and delivers the single
  biggest win by shrinking each instance's working set below `max_loras`. → ADR-010
- **The portable artifact is the vLLM primitives, not the controller.** Every router
  needs residency metrics, pin, and events; none can build fleet management without
  them. The placement algorithm is inherently router-specific.
- **llm-d-router#709 is already accepted and assigned.** Talk to the assignees
  before writing more, or you are building a competing design.

---

## 1. What we want

Declarative adapter lifecycle management across a serving fleet. A Platform
Operator declares which adapters should be warm and on how many serving instances;
the system maintains those targets across demand shifts, scale events, and local
cache pressure.

---

## 2. Landscape

### 2.1 vLLM (per serving instance)

| Capability | State |
|---|---|
| Two-tier LRU cache (`max_loras` GPU / `max_cpu_loras` CPU) | Exists, policy hardwired. Evictions cascade GPU → CPU → gone |
| Pinning | Exists internally in the cache manager; **not reachable over HTTP** **[verify]** |
| Static declaration (`--lora-modules`) | Exists. Populates CPU tier at boot; **not** a residency guarantee; cannot be unloaded without restart |
| Load API | Exists behind `VLLM_ALLOW_RUNTIME_LORA_UPDATING` |
| Unload API | Same gate. **The only way to deterministically remove an adapter** |
| LoRA resolvers | Exists. `vllm/plugins/lora_resolvers/{filesystem,hf_hub}_resolver.py`; base + registry in `vllm/lora/resolver.py` |
| Residency metrics | [vllm#45820](https://github.com/vllm-project/vllm/pull/45820) — stalled, `needs-rebase`, no approving review |
| Lifecycle events | [vllm#45411](https://github.com/vllm-project/vllm/pull/45411) umbrella; first split [vllm#51433](https://github.com/vllm-project/vllm/pull/51433) active, ready for review, code owners assigned. LoRA events are an explicit follow-up |
| Configurable eviction policy | Nothing |
| In-flight refcount | Historically evictable while in use ([vllm#14497](https://github.com/vllm-project/vllm/issues/14497)) **[verify on your version]** |

**On the production-readiness caveat:**
[RFC vllm#12174](https://github.com/vllm-project/vllm/issues/12174) calls the
`VLLM_ALLOW_RUNTIME_LORA_UPDATING` path a development-mode method, inappropriate
for production because it does not ensure the adapter is loaded across all
replicas. The [v0.7.2 docs](https://docs.vllm.ai/en/v0.7.2/features/lora.html)
state enabling it in production is risky since users may participate in adapter
management. **[verify]** whether the
[current stable docs](https://docs.vllm.ai/en/stable/features/lora/) still carry
this — the page has been restructured and now has an "In-Place LoRA Reloading"
section that did not previously exist. If the caveat was dropped, the "needs
promoting to a production API" argument weakens materially.

**On the metrics gap:** vllm#45820's own note says GPU-tier hit counters stay at
zero because `activate_adapter()` uses `__contains__`/`.touch()`, which bypass the
hit tracker. Eviction is only inferable from label churn. This must be fixed before
any frequency-weighted policy can be *evaluated* — you cannot weight by a frequency
you do not measure.

### 2.2 The resolver — what it actually is

Not a component. A **plugin class inside the vLLM process**. Nothing to deploy.
API ref:
[filesystem_resolver](https://docs.vllm.ai/en/latest/api/vllm/plugins/lora_resolvers/filesystem_resolver/);
design doc:
[LoRA resolver plugins](https://docs.vllm.ai/en/stable/design/lora_resolver_plugins/).
Came from [RFC vllm#12174](https://github.com/vllm-project/vllm/issues/12174) via
[vllm#14634](https://github.com/vllm-project/vllm/pull/14634).

Enable with two env vars on the vLLM container: `VLLM_PLUGINS` including
`lora_filesystem_resolver`, and `VLLM_LORA_RESOLVER_CACHE_DIR` pointing at a
mounted directory. Off unless you do that. Sibling `lora_hf_hub_resolver` works
against HF repos via `VLLM_LORA_RESOLVER_HF_REPO_LIST`.

It is a **miss handler**:

1. Request names adapter `foo`
2. Registry hit → serve
3. Miss → walk registered resolvers; filesystem resolver looks for a `foo`
   directory under the cache dir
4. Found → load, register, serve. Not found → request errors

This inverts the syncer model: the
[sidecar](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/main/tools/dynamic-lora-sidecar)
*pushed* (reconcile a ConfigMap into per-pod load/unload calls); the resolver
*pulls* lazily on the miss path. Which is why GIE could drop the syncer — the
control plane collapses into whatever populates the volume.

What it changes:

- **No pre-warming.** Only handles the miss; does not anticipate it.
- **No pinning.** Residency is entirely demand-driven plus LRU.
- **No removal path.** Deleting the directory does not evict copies already in the
  cache.
- **`/v1/models` discoverability is delayed** — resolver-loaded adapters appear only
  after first use.

The extension point matters: `LoRAResolver` + `LoRAResolverRegistry` means you can
ship a resolver that pulls from an internal registry, an OCI artifact, or a
LocalModelCache layout. Likely a cleaner integration seam than reviving a syncer.

### 2.3 Routing (llm-d-router / GIE)

| Capability | State |
|---|---|
| `LoRAAffinityScorer` | Exists, routes to endpoints serving the required adapter from `lora-info-metric`. But reads `running_lora_adapters` (request state), not residency. Switching the extractor to `gpu_cached_adapters` / `cpu_cached_adapters` is a small PR, **blocked on vllm#45820** |
| Dynamic LoRA placement | [llm-d-router#709](https://github.com/llm-d/llm-d-router/issues/709) — open, `triage/accepted`, assigned (opened Mar 2026 by nilig, assigned dmitripikus) |
| Shuffle-sharding placement | [llm-d-router#720](https://github.com/llm-d/llm-d-router/pull/720) — closed by stale bot Jul 2026. Working implementation on branch `dmitripikus:loras-shuffle-sharding` |
| ConfigMap sidecar syncer | Deprecated in [GIE v1.3.0](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/tag/v1.3.0), code being removed. Equivalent functionality "moving elsewhere" — unnamed. Prior usage documented in the [adapter rollout guide](https://gateway-api-inference-extension.sigs.k8s.io/guides/adapter-rollout/) |
| Automated adapter rollout pipeline | Still listed as GIE future work |

**llm-d-router#709 is your problem statement, written by someone else.** It asks for
routing each LoRA to a bounded subset of pods (k replicas) with adaptive
reshuffling and k-expansion on overload, respecting max loaded LoRAs per pod to
avoid eviction storms. It names three failure modes:

- prefer-loaded concentrates a hot LoRA on whichever pods have it → those overload
  while others idle
- adding load scoring spills the LoRA onto more pods → pushes out other adapters at
  MAX capacity → evictions and reloads across the pool
- cold LoRAs get repeatedly evicted → load penalties, tail latency, intermittent
  starvation

**llm-d-router#720 is the attempt, and how it failed is informative.** Implemented
as a scorer in `pkg/plugins/scorer/lora_aware.go`. The two things deferred to a
follow-up PR were *rebalance on endpoint restart and scale up/down* and *base model
discovery* — i.e. exactly the join/leave P1s. They were deferred because they do not
fit in a scorer: they need cluster state and a reconcile loop, not a per-request
scoring function.

It also died on a specific question: a reviewer (ahg-g) asked what validation and
benchmarking would establish the algorithm and what the baseline is. That was
March; never answered in-thread; stale-closed in July. **Expect the same question.**

The branch is reusable — review feedback already applied (single-mutex cache
invalidation, `getShardForAdapter` reduced to one allocation and one copy by
shuffling in place, sized for hundreds of pods).

### 2.4 Control plane (KServe)

| Capability | State |
|---|---|
| LLMInferenceService `LoRASpec` | Exists — adapter declaration ([llmisvc overview](https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/llmisvc-overview)) |
| LoRA affinity scorer wiring | Exists (llmisvc default config, [kserve#5675](https://github.com/kserve/kserve/pull/5675)) |
| LocalModelCache + llmisvc | [kserve#5318](https://github.com/kserve/kserve/pull/5318) merged; [install docs](https://kserve.github.io/website/docs/install/overview) still say llmisvc unsupported **[verify]** |
| LocalModelCache multi-nodegroup | [kserve#4126](https://github.com/kserve/kserve/issues/4126); [modelcache docs](https://kserve.github.io/website/docs/model-serving/generative-inference/modelcache/localmodel) |
| Placement / warm targets | Nothing |

### 2.5 Prior art elsewhere

**AIBrix** built a `ModelAdapter` CRD with a lifecycle phase machine and transition
history — different shape (per-adapter CR with a Service abstraction). Worth reading
before designing yours, including their own conclusion that high-density LoRA cannot
be solved on the control plane side alone. **[verify]** — read their current docs
directly rather than relying on this summary.

**TRT-LLM** budgets host and device cache **by bytes** rather than a hard adapter
count, so the cache flexes between many small adapters or a few large ones. vLLM
counts slots, so `max_loras` must be sized for the worst-case rank.

---

## 3. The core problem: three loops, one homeless

| Loop | Timescale | Decides | Home |
|---|---|---|---|
| Dispatch | µs, per request | Which endpoint, among those holding the adapter | Scheduler scorer — exists |
| **Shard management** | **~seconds, on churn** | **Which instances should hold which adapters** | **Homeless** |
| Declaration | minutes, on operator edit | Minimums, priority, capacity validation | K8s controller |

- **llm-d-router#720 put the middle loop in the request path** and stalled at its
  deferred items (rebalance on churn, base model discovery).
- **The current requirements put it in the reconcile loop** and will stall on
  staleness. LRU decides in milliseconds; a controller acts on a seconds-old scrape.
  Any victim the controller picks is chosen from stale state. **This cannot be fixed
  by reconciling faster.**

---

## 4. "Ensure minWarmReplicas" decomposed

| Verb | Needs | Available today |
|---|---|---|
| **Achieve** — get it resident on N instances | Load call, or synthetic request via resolver | Yes |
| **Retain** — hold against local LRU | Pin API | No |
| **Detect** — notice it dropped below N | Residency metrics / events | No |
| **Restore** — reload after loss | Detect + achieve | Gated |
| **Verify** — report the target met | Detect | Gated |

Only "achieve" exists. Everything that makes it a *guarantee* is blocked upstream.

### 4.1 Why the failure lands exactly where it hurts

The requirements' own example scenario: adapter X's traffic drops while Y spikes. At
that moment X is the least-recently-used adapter on every instance holding it, and
Y's arrival is what evicts it. **The mechanism that keeps X warm in steady state
(its own traffic) disappears at the moment the guarantee becomes load-bearing.**

Without pinning the loop is: controller loads X on instance 7 → other adapters
arrive → LRU evicts X → controller notices at next reconcile → reloads X → evicts
something else. Period = reconcile interval, amplitude = fleet size, worst near
capacity.

### 4.2 Capacity invariants (missing from the requirements)

Pinning consumes the budget it protects. The scheduler caps distinct adapters per
batch at `max_loras`, so pinning all slots silently converts an instance into a
dedicated one — no unpinned adapter can ever be batched there.

- **Per instance:** `pinned <= max_loras - reserve`, `reserve >= 1`, configurable
- **Fleet:** `SUM(minWarmReplicas) <= SUM(max_loras - reserve)` across instances

Enforce with a validating webhook on create/update, plus a **degraded status
condition** when scale-down invalidates a previously valid declaration. Also needs a
defined **priority order** for which declarations are honoured when oversubscribed.
Without this, an operator declaring 5 adapters x 4 replicas on a 12-instance fleet
with `max_loras=2` gets silent partial enforcement.

### 4.3 Pin within the shard

Do not choose instances arbitrarily. Pin **within the adapter's shard**, so
residency and routing agree — otherwise the scorer sends X to shard members while
the pins sit on instances that never see X's traffic. This is the concrete reason the
shard manager and pin enforcement should be the same loop, not two components with
independent opinions.

### 4.4 Instance departure

- **Graceful** (scale-down, drain, cordon): react to **terminating** endpoints, not
  removed ones. Pre-load on the replacement before the old endpoint leaves. If you
  only notice after removal you get a window below minimum *plus* a synchronised cold
  start on whoever picks up the traffic.
- **Abrupt** (crash, node loss): detect on endpoint removal, restore on survivors,
  with cooldown so a rolling restart does not trigger a fleet-wide reload storm.

### 4.5 Status must report observed, not intended

The warm count must come from scraped residency, with a **staleness bound surfaced
alongside it**. The tempting implementation — report what the controller believes it
placed — makes the resource always claim success. That is worse than no status,
because it is what an operator will page on.

---

## 5. Architecture decisions

Each ADR: decision, why, consequences, and what it costs. Discarded alternatives are
in [§6](#6-discarded-options) with the reasoning kept intact.

---

### ADR-001 — The serving instance, not the pod, is the unit of adapter residency

**Status:** proposed

**Context.** `max_loras` and `max_cpu_loras` are per *engine process*. In a
multi-node deployment (LWS, TP, PP) a leader plus its workers is one vLLM instance
with one adapter cache and one metrics endpoint on the leader. Eight pods, one set of
slots. The requirements say "pod" for both the routing target and the cache owner.

**Decision.** Split the vocabulary:

| Term | Definition | Used for |
|---|---|---|
| **Endpoint** | What the scheduler routes to and scores | Routing, scoring, pool membership |
| **Serving instance** | One vLLM engine process — one adapter cache, one `max_loras` budget. A single pod, an LWS/TP/PP group, or one side of a P/D pair | Warmth, capacity, load, eviction |

Rename `minWarmPods` to `minWarmReplicas`, defined against serving instance.

**Consequences.**

1. **The MoE atomicity requirement generalises.** "Lifecycle operations atomic across
   the expert parallel group" is the special case of a general rule: the serving
   instance is the atomic unit for *any* multi-pod topology. Rewrite it that way
   rather than special-casing MoE.
2. **Prefill/decode needs an explicit requirement.** An adapter modifies model
   weights, so the prefill instance needs it resident to compute the prompt's KV *and*
   the decode instance needs it for every generated token — both, for the same
   request. Placement is per-role plus a pairing constraint; independently computed
   shards can intersect thinly or not at all. Neither llm-d-router#709 nor #720
   addresses this; both treat endpoints as a flat homogeneous set.
3. **Shard size cannot be a constant.** Prefill and decode instances are often
   provisioned differently, so they have different `max_loras` budgets. Shard size must
   derive from available slots per role, or you over-subscribe the smaller side and
   cause exactly the eviction storms llm-d-router#709 exists to prevent.
4. A warm target counts as met only when it is satisfiable **end-to-end for a
   request**, not per-role in isolation. New AC.

**Cost.** A pass over the whole requirements doc for the word "pod" — not a patch of
three instances.

---

### ADR-002 — Shard management runs as a background loop in the scheduler process

**Status:** proposed

**Context.** See §3. The middle loop needs endpoint churn in seconds and residency
data fresh enough to act on. A K8s controller does not have that; a per-request scorer
cannot own state that outlives a request.

**Decision.** Shard computation runs as a background goroutine in the scheduler (EPP)
process — recomputing on endpoint-set change and metric refresh. The scorer reads the
current map; it does not compute it.

**Why here.**

- Already watches InferencePool endpoints → join/leave arrives immediately, not on the
  next reconcile
- Already scrapes every instance's metrics → residency data is free, not a duplicated
  scrape
- Dispatch and shard management share one view of the world. Split them across
  processes and you get skew: the controller thinks adapter X is on instance 7, the
  scorer routes on different data

This is also the **smallest change to llm-d-router#720 that unblocks its deferred
work**. Its review comments were already circling this — a shard cache with a mutex
living inside a request handler is a background-loop-shaped thing.

**Consequences.** Needs three things a scorer does not:

- **Leader election** if the scheduler is replicated, or two replicas issue conflicting
  directives
- **Desired state read from a CR**, not held in memory — a restart must not lose
  placement intent
- **A cooldown / minimum dwell**, so it does not chase every metrics blip. Nothing in
  the current requirements prevents rebalancing on noise. New AC.

**Cost / risk.** GIE's stated remit for EPP is scheduling decisions from metrics and
capabilities. A goroutine making side-effecting `load_lora_adapter` calls is arguably
outside that, and is vLLM-specific. Expect this contested upstream. Precedent for
capability-gated vLLM-specific behaviour exists — Triton and SGLang already get LoRA
affinity disabled by setting an empty `lora-info-metric`.

---

### ADR-003 — The controller declares floors; the engine selects eviction victims

**Status:** proposed

**Context.** The requirement reads *"when the controller coordinates eviction, the
decision considers fleet-wide adapter coverage and respects declared minimums"* — which
implies the controller picks victims. It cannot do so correctly: it acts on stale
state and loses every race with a millisecond-scale LRU.

**Decision.** The controller expresses **floors** (which adapters must stay resident,
where). The engine's local policy selects victims among **unpinned** adapters. The
controller never names a victim.

**Consequences.**

- "Fleet-wide eviction decisions respect local pod state" becomes true **by
  construction** rather than a distributed-consistency problem
- The control surface the engine needs is *pin*, not *evict* — which is why the pin API
  is a P0 dependency (ADR-008)
- Reconcile-loop staleness stops mattering for correctness; it only affects how quickly
  a *new* floor takes effect

**Cost.** Requires the pin API, which is unfiled. Until it lands, floors are
best-effort (see ADR-008).

---

### ADR-004 — Adapter loading executes lazily in the engine via the LoRA resolver

**Status:** proposed

**Context.** Three different things get called "loading": deciding *that* an adapter
should be warm, deciding *which* instances hold it, and *executing* the load. The
syncer model made all three a control-plane push.

**Decision.** Split them by owner:

| Concern | Owner |
|---|---|
| *That* an adapter should be warm | Controller, from declared intent |
| *Which* instances hold it | Shard manager (ADR-002) |
| *Executing* the load | **The engine, on the resolver miss path** |

The controller and shard manager issue **routing intent**, not load commands. Routing
a request to an instance is sufficient to load the adapter there.

**Why.** With weights already node-local and the resolver enabled: no
`VLLM_ALLOW_RUNTIME_LORA_UPDATING` dependency on the common path; no per-pod
reconciler and no desired/actual drift; no pod-level connectivity requirement from the
control plane; and the load happens at the moment and place the request needs it.
Placement becomes a *consequence* of dispatch rather than a separate imperative
action.

**Consequences.** Three exception paths where routing-induced loading is not enough,
all **shard-manager-initiated** (they must name a specific instance and know its
state):

1. **Pre-warm on scale-up** — a new instance should get adapters before traffic, not on
   first miss
2. **Retirement** — unload is the only deterministic removal
3. **Pinning** — the floor; routing pressure is exactly what disappears when an adapter
   goes cold

**Uncomfortable dependency.** Two of the three exception paths (pin, production-grade
unload) are the upstream gaps. The lazy path is available today; the exception paths are
not. Another argument for Phase 0 being sharding-only (ADR-010).

**Note on warm-up requests.** They are real inference requests — they occupy a batch
slot and run a forward pass. Use `max_tokens: 1` and a minimal prompt. Under P/D they
follow normal routing, so they warm whichever prefill/decode instances the router picked;
to warm a *specific* instance you must bypass the router and address the pod directly.
That means the shard manager needs pod-level connectivity, not just gateway access —
check against network policy assumptions.

---

### ADR-005 — Extend LLMInferenceService `LoRASpec`; do not add an `AdapterPlacement` CRD

**Status:** proposed, **gated on an open verification**

**Decision.** `minWarmReplicas` and `priority` become additive fields on the existing
`LoRASpec`. No new CRD.

**Why.** They are per-adapter attributes. A separate CR buys a two-resource lifecycle to
keep in sync, duplicate RBAC, and a split status — for benefits that only appear at a
scale not yet in evidence. llmisvc already owns the pods and the pool, which is what
placement status needs to describe.

**The verification that decides it.** Does editing `LoRASpec` today roll the pods? If
adapters are rendered into container args (`--lora-modules ...`) or anywhere in the pod
template, every placement edit changes the pod-spec hash and triggers a rolling update —
violating the runtime-change P0 *and* evicting every warm adapter in the fleet. **[verify]
in the llmisvc reconciler before committing either way.**

If it does roll pods, the fix is still not a new CRD:

1. **Split the field, not the resource** — declaration stays where it affects pod spec;
   placement targets move to a path the workload reconciler ignores
2. **Better: get adapters out of the pod template entirely.** With the resolver,
   `--lora-modules` is unnecessary and the pod spec becomes adapter-agnostic. Aligns with
   where GIE just moved; may be a prerequisite regardless

**Consequences.**

- New AC: **editing placement targets must not mutate the pod template**
- **Keep the reconcile loops separate** — same controller-manager, distinct controllers
  keyed off the same object. Workload reconcile is slow and idempotent; placement
  reconcile is metrics-driven with its own rate limiter and cooldown. Merge them and a hot
  placement loop starves workload reconciles

---

### ADR-006 — Placement intent is read from a schema'd API, not a ConfigMap

**Status:** proposed

**Context.** The deprecated GIE syncer took desired state from a ConfigMap, so seeding a
ConfigMap from llmisvc is proven precedent.

**Decision.** The scheduler reads placement intent from the InferencePool or a CR it owns.
llmisvc *populates* that — the same way it already populates the pool.

**Why not the ConfigMap.** No schema, no status subresource, no conditions — and the P1
"operator can see whether each adapter meets its target" needs somewhere to write observed
state. You would end up writing status back into the same ConfigMap or into annotations. No
validating webhook either, so the capacity-feasibility check (§4.2) has nowhere to live and
infeasible declarations fail silently. And it couples the scheduler to KServe: EPP would only
work when llmisvc is present to seed it — moving the coupling rather than removing it.

**Consequences.** KServe users get `LoRASpec` as their surface; plain llm-d / raw GIE users
write the CR directly; the scheduler has one input either way, with schema and status.

---

### ADR-007 — Weight distribution is a precondition, not owned by this feature

**Status:** proposed

**Context.** The requirements scope out node-level distribution, but nothing currently does
it *for adapters*, so it must be named with an owner.

**Decision.** Adapter weights are made available on node-local disk by an existing
mechanism — **LocalModelCache** where available. This feature *validates* availability; it
does not cause it.

**Why LocalModelCache.** It is pull-to-node with a per-node agent, not a shared RWX volume
and not a push. Four CRDs: `LocalModelCache` (which model from persistent storage to cache
on node-local storage), `LocalModelNodeGroup` (which nodes), `LocalModelNode` (per-node cache
status), plus namespace-scoped `LocalModelNamespaceCache` for multi-tenancy isolation.
Declare `sourceModelUri`, `modelSize`, target `nodeGroups`; KServe runs a download job and
creates an agent DaemonSet on matching nodes. Disabled by default — enable `localModel` in
the `inferenceservice-config` ConfigMap. Multiple node groups supported with separate
download jobs per group ([kserve#4126](https://github.com/kserve/kserve/issues/4126)).

Three things fall out for free: **runtime addition without restart** (a download job, no pod
churn — satisfies the runtime-add P0 at the distribution layer); **a fleet-wide availability
view** (`LocalModelNode` per-node status is exactly the input the availability check needs);
and **deletion exists** (delete verb on localmodel PV/PVC RBAC was added recently).

**Three adapter-specific gaps.**

1. **Node-group affinity breaks the flat-fleet assumption.** Using the cache requires a
   node-group annotation on the workload so it schedules onto matching nodes, and
   `sourceModelUri`/`nodeGroup` must match. Sharding assumes any instance can serve any
   adapter. If adapter A is cached on the H100 group and A's shard includes an A100-node
   instance, resolution fails at request time. Either every adapter caches to every node
   group the pool spans (multiplying jobs and disk), or **the shard manager must be
   node-group-aware** and compute shards within the set of instances whose nodes hold the
   weights. This is a real constraint on the placement algorithm and belongs in the
   requirements. *Nobody in either upstream thread has raised it.*
2. **Granularity.** Designed for a handful of large base models — `modelSize` per CR, a
   download job per CR per node group. 15–50 adapters x 3 node groups is a lot of CRs and jobs
   for artifacts of tens of MB. Check whether a grouping notion exists or is needed.
3. **Path layout contract.** The filesystem resolver wants a directory named exactly as the
   adapter is requested, under `VLLM_LORA_RESOLVER_CACHE_DIR`. LocalModelCache materialises to
   its own layout. Reconcile by pointing the resolver's cache dir at the mount and constraining
   naming, **or** write a custom `LoRAResolver` that understands the LocalModelCache layout —
   the registry extension point exists for exactly this.

**Consequences.** Availability is validated with an `AdapterNotAvailable` status condition.
The resolver's native failure mode is a request error at load time, invisible to the operator
until a user complains.

**Layout contract to write down explicitly:** directory name = adapter name = model name in
the request = key in `LoRASpec`. A rename on one side without the other is a silent 404.

**Fallback if LocalModelCache is unavailable for adapters:**

| | Init container | RWX PVC + writer | Object/OCI mount |
|---|---|---|---|
| Runtime add without restart | **No** | Yes | Yes |
| Infrastructure owned | None | Sync job + GC | None |
| Fits adapter size (10s–100s MB) | — | — | Well — registry semantics, immutable digests, existing RBAC |
| Blocks runtime-add P0 | Yes | No | No |

Prefer mounting the store directly (object CSI or OCI artifact volume) — it is the option
where nothing is built.

---

### ADR-008 — Retention is the pin API; keepalive traffic is interim only

**Status:** proposed; pin API **unfiled**

**Decision.** `minWarmReplicas` is enforced by pinning within the adapter's shard. Until the
pin API exists, enforcement is best-effort and the doc says so.

**Why not keepalive as the mechanism.** It works, and it is all that is available today, but
X survives only if touched more often than `max_loras` other distinct adapters are. With
`max_loras=4` and 20 adapters in rotation the required synthetic rate is a significant
fraction of real traffic. It burns batch slots and GPU time and pollutes request counts,
TTFT, and — most awkwardly — the P2 cold-start-rate metric, which would count traffic you
generated as warm-served.

If keepalive ships as an interim, synthetic traffic needs a marker (header or reserved
request-id prefix) so metrics can exclude it. Label it interim in the doc and make the pin API
the thing that deletes it.

**What the pin API needs.** `pin_lora_adapter` / `unpin_lora_adapter` endpoints alongside the
existing load/unload ones (`vllm/entrypoints/serve/lora/api_router.py` + `protocol.py`),
plumbed frontend → `AsyncLLM` → engine core → `LRUCacheWorkerLoRAManager` → the cache
manager's pin path. Reject a pin that would consume the last free slot. Report pinned state in
residency metrics so the controller verifies rather than assumes. Apply across **all ranks** in
a multi-rank group. Pins are **process state**, so a restart loses them: the controller must
treat pinning as continuously reconciled, not fire-and-forget.

**Cost.** Engine-side work is roughly a week (a few hundred lines). The real cost is upstream:
a new public API on a security-sensitive surface — the same surface currently gated behind
`VLLM_ALLOW_RUNTIME_LORA_UPDATING` for exactly that reason. Expect design discussion on whether
it is an admin API, whether it needs its own gate, and how it interacts with the resolver's
lazy-load path. **Weeks to a couple of months of calendar time regardless of how fast you write
it** — which is why it should be filed first and depended on last.

**Unpinning is not unloading.** Unpinning returns an adapter to normal LRU candidacy, so it
*may* eventually be evicted under pressure. If you need it gone *now* — rollback, tenant
offboarding — you still need unload. Pinning removes the need for unload in the *rebalancing*
path but not in the *retirement* path. Resolver-only means "we removed it from config" and "no
instance can still serve it" are different statements with an unbounded gap.

---

### ADR-009 — Split by loop: shard manager in llm-d-router, declaration in KServe

**Status:** proposed

| | KServe llmisvc | llm-d-router | GIE | Standalone |
|---|---|---|---|---|
| Owns the workload | Yes | No | No | No |
| Owns pool endpoints | Via pool | Yes | Yes | Watch |
| Issue already accepted | No | **Yes (#709)** | No | — |
| Model-server-agnostic constraint | No | Looser | **Strict** | — |
| Reaches non-KServe users | No | Yes | Yes | Yes |

**Decision.**

- **Shard manager** → llm-d-router, where #709 is accepted and assigned. Written as a **GIE
  scheduler plugin** rather than router-specific code — the difference between one router
  having this and the interface having it
- **CRD + reconciler** → KServe, as the declarative surface
- Behind an **InferencePool-watching contract** so plain llm-d / raw GIE users are not excluded

**Why.** The requirements' own customer-impact statement says "any llm-d deployment," which
KServe-only delivery contradicts. And since the feature is inherently scheduler-dependent
(ADR-014), llm-d-router is the load-bearing home and KServe is the convenience surface — a
structural reason, not a political one.

---

### ADR-010 — Sharding first; declarative targets layered on top

**Status:** proposed

**Decision.** Implicit placement (consistent-hash sharding) is the baseline tier. Declared
minimums are a layer above it, not a replacement.

**Why both.**

| | Implicit (sharding) | Explicit (declared targets) |
|---|---|---|
| Mechanism | Consistent-hash adapter → k instances; routing keeps them warm via LRU | Controller declares floors; pinning enforces |
| Upstream deps | **None** | Metrics + pin + events |
| Guarantee | Statistical — bounded working set, eviction rarely fires | Declared floor, priority tiers |
| Expresses priority / tenancy | No | Yes |
| Prior art | #720 branch, ready to revive | None |
| Failure mode | Hot adapter can still overload its shard | Thrash against LRU without pinning |

Sharding shrinks each instance's working set below `max_loras`, at which point eviction rarely
fires and the pin gap stops being load-bearing. Declared minimums cover what sharding cannot
express — priority, guaranteed warmth for a paying tenant, coordinated scale behaviour.

**Consequence — the benchmark obligation.** Benchmark the declarative controller against
**sharding**, not against naive prefer-loaded. llm-d-router#720 died on precisely this
question. Prove you still thrash under sharded routing before committing to a control plane.
Metrics: p99 TTFT and reload counts under a Zipfian adapter distribution.

---

### ADR-011 — Eviction visibility comes from the engine notification channel, not only the gauge

**Status:** proposed, **[verify]** on delivery semantics

| | [vllm#45820](https://github.com/vllm-project/vllm/pull/45820) (Prometheus gauge) | [vllm#45411](https://github.com/vllm-project/vllm/pull/45411) / [vllm#51433](https://github.com/vllm-project/vllm/pull/51433) (engine notifications) |
|---|---|---|
| Status | Stalled, needs-rebase, no reviewer | Active, ready for review, code owners assigned |
| Delivery | Scrape — misses evict/reload pairs between scrapes | State-change driven for in-tree producers **[verify]** |
| Per-rank visibility | No | **Yes** — explicitly keeps every rank |
| Multi-API-server consistency | — | Broadcast so all `/metrics` agree |
| Covers "reason for action" | No | Intended (LoRA events are a follow-up PR) |

**Decision.** Treat the notification channel as the primary source for lifecycle events and
the gauge as the source for point-in-time residency. Do not gate the design on the gauge alone.

**Why.** A Prometheus gauge cannot satisfy "each lifecycle event visible with the reason" — you
miss every evict-reload pair between scrapes, which is exactly the churn that matters.

**#51433 detail.** `vllm/v1/notifications.py` defines a tagged msgspec union with
`CustomNotification(key, payload)` and a process-local worker buffer;
`WorkerBase.take_notifications()` drains it, `EngineCore.gather_worker_notifications()` collects
via `collective_rpc("take_notifications")`, and results ride out on
`EngineCoreOutputs.engine_notifications`.

Two properties matter most:

- **Per-rank events survive.** Draining into `ModelRunnerOutput` only reached the executor's
  output_rank, so producers on other ranks were discarded, and paths returning early (non-last PP
  rank via `with_kv_conn_output_only`) never drained. Keeping every rank is the **transport-level
  answer to the MoE atomicity requirement** — it is what makes detecting a *partial* load/unload
  across an EP group possible. Without it you only hear from rank 0 and cannot distinguish
  "loaded everywhere" from "loaded on the rank that answered."
- **All API servers agree.** `EngineCoreProc` broadcasts to every API server so their `/metrics`
  agree, removing a class of controller confusion where two scrapes of the same instance disagree.

**[verify]:** whether consumption is a **subscribable stream or terminates in `/metrics`** (the
referenced consumer is a separate Rust frontend PR and `/metrics` is mentioned explicitly) —
this sets the staleness bound on "local evictions visible to the controller"; whether **delivery
is state-change-driven or poll-gated** (`VLLM_WORKER_NOTIFICATION_POLL_INTERVAL`, off by
default — a LoRA manager is in-tree so it *should* trigger a gather at the state change); and
whether the **`mrv2` label** means Model Runner V2 only.

The author is at Red Hat. If that is your org, this is an internal conversation and the fastest
route to shaping LoRA eviction events to the controller's needs *while the schema is still being
designed*.

---

### ADR-012 — In-flight eviction behaviour: refcount invariant, admission-time fail-fast, no base fallback

**Status:** proposed

**Context.** The requirement bundles three configurable behaviours (queue-and-reload,
fail-fast, fallback-to-base) into one line. They have very different prospects.

**Decision.**

1. **Never evict an adapter with in-flight requests** — implement as a **correctness
   invariant**, not a policy: refcount, pin-while-referenced. This is what
   [vllm#14497](https://github.com/vllm-project/vllm/issues/14497) was really about. One
   ceiling: distinct in-flight adapters cannot exceed `max_loras` or you deadlock, so scope the
   refcount to the **running batch**, not everything queued. **Do this.**
2. **Queue-and-reload** — already the de facto behaviour (evicted from GPU, still in CPU tier,
   reloads transparently). The real ask is making it explicit and **bounded** (max wait, then
   what?). Little to configure.
3. **Fail-fast** — supported at **admission**, not mid-generation. Aborting a partially streamed
   response over a cache decision is a bad trade. As a 503 + Retry-After at enqueue, when the
   adapter is cold and the cache is thrashing, it is **load shedding** — genuinely useful, and it
   composes with gateway retry.
4. **Fallback-to-base — dropped.** Serving base output to a request that asked for a fine-tune is
   wrong, not degraded: SQL adapters, tool-call formats, tenant behaviour, safety tuning. Would
   need per-request opt-in plus an explicit response field marking what happened. Unlikely to be
   accepted as engine-level config.

**Framing.** "Adapter isn't warm here" is usually a **routing** decision. Pushing all three
behaviours into vLLM duplicates what the gateway should be doing with the residency signal.

---

### ADR-013 — Frequency-weighted eviction: CPU tier only, last phase

**Status:** proposed, deferred

**Decision.** If built: target the **CPU tier** (`_registered_adapters`), use an **ageing**
scheme, and sequence it last.

**Why CPU tier only.** CPU-tier eviction costs a disk/S3 reload (hundreds of ms to seconds);
GPU-tier eviction costs an H2D copy (single-digit ms) — two orders of magnitude. And GPU
membership is not a free choice: the scheduler caps distinct adapters per batch at `max_loras`,
so the worker must hold whatever the batch needs. The only degree of freedom is which *idle*
adapter keeps a spare slot.

**Why ageing.** Plain LFU pollutes — yesterday's hot adapter becomes immortal. W-TinyLFU
(count-min sketch + admission window, the Caffeine design) or an exponentially decayed score. A
size term is worth adding since reload cost scales with rank x target modules: something
GDSF-shaped, `freq / bytes + clock`.

**Prerequisite.** Fix the hit accounting first — GPU-tier counters are dead because
`activate_adapter()` bypasses the tracker.

**Code surface** (a few hundred lines):

- `vllm/utils/cache.py` — generalise `LoRALRUCache` to policy-parameterised victim selection
  instead of recency `popitem()`; keep the pinned-adapter skip
- `vllm/lora/model_manager.py` — `remove_oldest_adapter()` becomes a policy call; record hits on
  the activate path
- `vllm/lora/worker_manager.py` — same at the worker layer
- `vllm/config/lora.py` + `EngineArgs` — `--lora-eviction-policy`, decay half-life
- `tests/lora/` plus a Zipfian adapter benchmark

**Why last.** The code is not the hard part — maintainers will want p99 TTFT and reload counts
under skewed distributions versus LRU, and that chart needs the metrics first. And if ADR-010
works, the working set fits and eviction rarely fires, so a better policy buys little. Order:
vllm#45820 → accounting fix → policy.

---

### ADR-014 — Adapter-aware dispatch is a hard prerequisite

**Status:** proposed

**Context.** The feature does not depend on EPP specifically. It depends on four capabilities:

| Capability | Enables |
|---|---|
| 1. Enumerate instances and see churn | Shard assignment, rebalance on join/leave |
| 2. Observe per-instance residency | Detect, restore, verify, status |
| 3. Dispatch selectively to a chosen instance | Warm-serving — turning placement into hits |
| 4. Issue side-effecting calls to a specific instance | Explicit load/unload/pin |

| Topology | Capabilities | Result |
|---|---|---|
| llm-d-router EPP | 1, 2, 3, 4 | Full feature |
| Any GIE-conformant endpoint picker | 1, 3 natively; 2 via the metrics scrape GIE already does | Full feature **if the algorithm is a GIE scheduler plugin** |
| Third-party routers (Dynamo, production-stack, AIBrix) | Own equivalents of 1–3 | Reimplement the algorithm; cannot reimplement the engine side |
| Raw K8s Service / kube-proxy | None of 1–3 | Uniform residency only |

**Decision.** Add an explicit scope statement: *fleet lifecycle management requires
adapter-aware dispatch; without it, the only supported configuration is uniform residency
across all instances.*

**Why.** kube-proxy load balances at L4 with no adapter awareness, so you cannot route adapter A
preferentially to instances holding A. Sharding is impossible. Pinning still *works* (a
controller with pod-level connectivity can pin under any topology) but does not convert into warm
serving — pin on 4 of 12 instances and 8 of 12 requests still land somewhere without it. The one
configuration that works is the degenerate one: `minWarmReplicas` = instance count, i.e. size
`max_loras` to the whole adapter set. Which is genuinely the right advice for a small adapter set
with no router.

**Consequence.** Prevents "doesn't work with a plain Service" being filed as a bug later, and
tells that operator what to do instead.

**Corollary — the portable artifact is the vLLM primitives, not the controller.** Residency
metrics, the pin API, eviction events, configurable eviction policy: every router needs these and
none can build fleet management without them. The placement algorithm is inherently
router-specific. That is a stronger argument for filing the pin RFC now than "it unblocks our
P0," and a better pitch upstream.

---

## 6. Discarded options

Kept with reasoning so the decisions are not relitigated from scratch.

### 6.1 A dedicated `AdapterPlacement` CRD

**Rejected in favour of** extending `LoRASpec` (ADR-005).

`minWarmReplicas` and `priority` are per-adapter attributes — a purely additive field change on
an existing alpha API. A separate resource costs a two-object lifecycle to keep in sync,
duplicate RBAC, a split status, and a second reconcile relationship, and buys nothing until a
scale that is not yet in evidence. llmisvc already owns the pods and the pool, which is exactly
what placement status must describe.

*Would be reconsidered if:* editing `LoRASpec` proves to roll pods **and** neither
field-splitting nor removing adapters from the pod template is workable.

### 6.2 EPP owns placement in the request path (the llm-d-router#720 shape)

**Rejected in favour of** a background loop in the same process (ADR-002).

- A placement decision costs seconds (weight load); a routing decision costs microseconds.
  Coupling them means either blocking the hot path or firing async side effects from a
  per-request scorer — which is how you get thrash
- Scorer state is soft and rebuildable from a scrape. Placement is desired state that must
  survive restarts and be reconciled. Making the scorer authoritative means adding leader
  election, persistence, and a reconcile loop — growing a controller inside a data-plane
  component
- Failure semantics diverge: scheduler down should degrade to dumb load balancing; placement
  authority down should freeze desired state, not drift pods

The empirical evidence is #720 itself: the two items it deferred (rebalance on churn, base model
discovery) are the two that do not fit in a scorer, and it never came back.

### 6.3 A dedicated fleet control plane that picks eviction victims

**Rejected in favour of** floors plus engine-local victim selection (ADR-003).

A reconcile loop runs in seconds; the vLLM cache decides in milliseconds. Any victim the
controller names is chosen from stale state, and it will lose that race every time. Reconciling
faster does not close the gap, it just burns API calls. AIBrix reached a compatible conclusion
independently: high-density LoRA cannot be solved control-plane-only.

### 6.4 EPP reads placement from a ConfigMap seeded by llmisvc

**Rejected in favour of** a schema'd API (ADR-006). Full reasoning in that ADR: no schema, no
status subresource, no validating webhook, and it couples the scheduler to KServe rather than
decoupling it. Note this *was* the deprecated syncer's mechanism, so the pattern is proven —
proven and outgrown are different things.

### 6.5 Reviving the GIE dynamic-lora-sidecar

**Rejected.** Deprecated in GIE v1.3.0 with the code being removed. It also depends on
`VLLM_ALLOW_RUNTIME_LORA_UPDATING` on every pod, and it is a per-pod reconciler with all the
drift that implies. The resolver (ADR-004) covers the same ground pull-style with no gate and no
sidecar. If a custom source is needed, the right extension point is a `LoRAResolver` plugin, not
a sidecar.

### 6.6 Keepalive traffic as the permanent retention mechanism

**Rejected as permanent; accepted as interim** (ADR-008). The required synthetic rate scales with
`max_loras` and the number of adapters in rotation, it burns batch slots and GPU time, and it
corrupts the very cold-start metric the requirements ask for. Interim only, marked as such, with
a marker on synthetic traffic so metrics can exclude it.

### 6.7 Fallback-to-base for requests whose adapter was evicted

**Rejected** (ADR-012). Base output for a request that asked for a fine-tune is wrong, not
degraded — SQL adapters, tool-call formats, tenant behaviour, and safety tuning all change
meaning. Would require per-request opt-in plus a response field marking what happened, and is
unlikely to be accepted as engine-level config in any case.

### 6.8 Mid-generation fail-fast on eviction

**Rejected** (ADR-012). Aborting a partially streamed response over a cache decision is a bad
trade. Fail-fast belongs at admission, where it is load shedding and composes with gateway retry.

### 6.9 Exposing "static" and "dynamic" adapters as operator-facing modes

**Rejected.** Operators will read "static" as "guaranteed warm," which is false: `--lora-modules`
populates the CPU tier at boot, GPU residency is still LRU-governed, and if declared adapters
exceed `max_cpu_loras` they get evicted from CPU too. A statically declared adapter and a
dynamically loaded one are **indistinguishable in the cache** once resident.

One declaration surface; the controller picks the mechanism:

| | `--lora-modules` | Load/unload API | Resolver |
|---|---|---|---|
| Runtime add | No (restart) | Yes | Yes (lazy, on miss) |
| Runtime remove | **No** | **Yes — only mechanism** | No |
| Pod-spec coupling | Yes — edits roll pods | No | No |
| Production-ready | Yes | Gated, dev-mode | Yes |
| `/v1/models` at boot | Yes | On load | Only after first use |

`--lora-modules` is retained for two narrow cases: single-instance deployments with no scheduler,
and boot-time `/v1/models` discoverability if anything in the stack enumerates models before
traffic (client SDKs, gateway-side model-name validation).

Two consequences: **statically declared adapters are un-unloadable** — the controller must know
which they are and surface it, or rebalancing fails silently on exactly the instances where an
operator thought they were being careful. And **`max_lora_rank` is fixed at startup** — an
adapter arriving dynamically above the configured envelope is rejected at load, so the
declaration needs a validation rule (not a reason to keep static declaration).

### 6.10 A `LoRASpec`-driven weight sync controller

**Rejected** (ADR-007). Weights are immutable and shared (publish-once, GC-eventually);
declarations are mutable and frequent. Coupling them makes every placement edit a storage
operation, and removing an adapter from one CR would need cross-CR reference counting to know
whether the file is safe to delete. That *is* the "adapter storage, versioning, and registry"
scope the requirements explicitly exclude — building it anyway means quietly taking on what was
scoped out.

*If automated population is wanted later:* a separate, optional controller with its own CR
carrying a source (URI, registry ref, secret) and reference counting across consumers. A distinct
feature with a distinct scope; keeping it out is what lets the placement work ship.

### 6.11 Init-container-only weight distribution

**Rejected as the sole mechanism.** An init container populates a volume before the server
starts, so adding an adapter afterward means a pod restart — which evicts every warm adapter in
the fleet and violates the runtime-change P0. Fine as a bootstrap for a known adapter set; cannot
be the only path.

### 6.12 GPU-tier frequency-weighted eviction

**Rejected in favour of** CPU-tier only (ADR-013). GPU membership is largely forced: the
scheduler caps distinct adapters per batch at `max_loras`, so the worker must hold whatever the
batch needs. The only real freedom is which idle adapter keeps a spare slot, and the cost
differential (single-digit ms H2D vs seconds of reload) puts the value on the CPU tier.

### 6.13 Byte-budgeted cache (the TRT-LLM model)

**Not pursued now.** TRT-LLM budgets host and device cache by bytes rather than adapter count,
which lets the cache flex between many small adapters and a few large ones. It is arguably the
better model — vLLM's slot counting forces `max_loras` to be sized for the worst-case rank — but
it is a substantially larger change to vLLM's allocator and is not on the critical path.
Worth noting as a long-term direction.

---

## 7. What we need to implement

### 7.1 Upstream vLLM

| Item | Size | Status |
|---|---|---|
| Residency metrics | Small | [vllm#45820](https://github.com/vllm-project/vllm/pull/45820) exists — push it or take it over |
| **Pin/unpin over HTTP** | ~few hundred lines engine-side; **RFC + review cycle is the long pole** | **Unfiled. File the RFC now** |
| LoRA events on the notification channel | Follow-up to [vllm#51433](https://github.com/vllm-project/vllm/pull/51433) | In progress upstream — engage on schema now |
| In-flight refcount | Small | Correctness invariant. Scope to the running batch |
| Configurable eviction policy | Moderate | Nothing. Needs the hit-accounting fix first |

### 7.2 Routing

- Switch the affinity scorer's extractor to residency (`gpu_cached_adapters`) — small, blocked on
  vllm#45820
- Revive llm-d-router#720's shuffle sharding; move shard computation out of `Score()` into a
  background loop; add rebalance on endpoint churn and base model discovery (its two deferred
  items)
- Shard size derived from available slots **per role**, not a single constant
- **Node-group-aware** shard computation (ADR-007 gap 1)
- P/D pairing: only pair endpoints where the adapter is warm on both sides, or accept a defined
  cold-start cost on one
- Write it as a **GIE scheduler plugin**, not router-specific code

### 7.3 Control plane

- `LoRASpec` extension: `minWarmReplicas`, `priority`
- Validating webhook: capacity feasibility, adapter path availability, rank envelope
- Status: observed warm count with staleness bound, per-adapter conditions, lifecycle events with
  reason
- Ensure placement edits do not mutate the pod template
- Separate placement and workload reconcile loops with independent rate limiters

---

## 8. Recommended sequencing

**Phase 0 — no upstream dependency.** Revive sharding. Blind consistent-hash needs only endpoint
enumeration and adapter-aware dispatch — no metrics, no pin, no events. Shrink each instance's
working set below `max_loras`. Benchmark against naive prefer-loaded under a Zipfian adapter
distribution with p99 TTFT and reload counts. **This answers the question that killed
llm-d-router#720 and establishes the baseline everything else is measured against.**

**Phase 1 — declare and observe.** `LoRASpec` extension, controller, capacity validation, status.
Gated on eviction visibility — likely via the notification channel rather than the stalled gauge.

**Phase 2 — guarantee.** Pinning converts "usually warm" into a floor and lets the keepalive hack
be deleted. File the RFC in Phase 0 regardless; its calendar time is the long pole.

**Phase 3 — tune.** Frequency-weighted eviction. Genuinely independent, lowest value if Phase 0
worked, least missed if it slips.

**Do not make all three upstream dependencies blocking.** Scope the P0s to what sharding
delivers; let pinning and events upgrade the guarantee rather than gate the release.

Note the revised dependency order: **events are further along than metrics.** vllm#45820 is
stalled with no reviewer; vllm#51433 is active with code owners assigned. Consider whether
eviction visibility can come through the notification channel instead of waiting on the
Prometheus gauge.

---

## 9. Requirement changes this implies

| Current requirement | Change |
|---|---|
| "minimum warm pod count" | → `minWarmReplicas`, serving instance defined (ADR-001) |
| MoE expert-parallel atomicity | Generalise to all multi-pod serving units (ADR-001) |
| — | **New:** P/D — warm target met only when satisfiable end-to-end (ADR-001) |
| "controller coordinates eviction" | → controller declares floors; engine selects victims (ADR-003) |
| — | **New:** capacity feasibility validation + degraded condition + priority order when oversubscribed (§4.2) |
| — | **New:** cooldown / minimum dwell before rebalancing (ADR-002) |
| — | **New:** placement edits must not mutate the pod template (ADR-005) |
| — | **New:** adapter availability precondition + `AdapterNotAvailable` condition (ADR-007) |
| — | **New:** node-group-aware placement where LocalModelCache node groups are in use (ADR-007) |
| "in-flight behaviour configurable (3 modes)" | Refcount invariant + admission fail-fast; drop fallback-to-base (ADR-012) |
| AdapterPlacement CRD | → `LoRASpec` fields (ADR-005) |
| — | **New scope statement:** requires adapter-aware dispatch (ADR-014) |
| Status "meets declared warm target" | Must be observed, with staleness bound (§4.5) |

---

## 10. Open questions to verify

1. **Does editing `LoRASpec` roll pods in the llmisvc reconciler?** Decides ADR-005. Single
   afternoon of reading; do this first.
2. Does `filesystem_resolver` scan the cache dir at startup or on each miss? If at boot, adapters
   added later need a restart — breaking the runtime-add P0 through a path unrelated to the
   controller.
3. Is pinning genuinely present in the current cache manager, and genuinely unexposed? Load-bearing
   for ADR-003 and ADR-008.
4. Do current stable vLLM docs still carry the production caveat on
   `VLLM_ALLOW_RUNTIME_LORA_UPDATING`?
5. Does `LocalModelCache` support adapters (vs base-model semantics in size validation, layout,
   per-node assumptions), and does it now support llmisvc? kserve#5318 merged vs install docs
   saying otherwise. Read `pkg/controller/v1alpha1/localmodelcache/`.
6. Do prefill and decode land in one InferencePool with a role label, or two pools? Decides whether
   P/D pairing is a filter in one scorer or cross-pool coordination.
7. Is the vllm#51433 notification channel consumable as a stream, or does it terminate in
   `/metrics`? Is delivery state-change-driven or poll-gated? Is it `mrv2`-only?
8. Is LoRA load/unload already atomic across an EP group under partial failure? Treat as a spike,
   not an estimate.
9. Can the shard manager reach pods directly (for targeted warm-up / pin), or only via the gateway?
   Network policy implications.

---

## 11. People to talk to before writing more

- **dmitripikus / nilig** — llm-d-router#709 is accepted and assigned; #720 is their branch.
  Building in parallel means competing designs for one outcome. **Do this first.**
- **wseaton (Red Hat)** — engine notification channel vllm#51433. If same org, this is an internal
  conversation and the fastest route to shaping LoRA eviction events while the schema is still
  open.
- **VedantMahabaleshwarkar** — LocalModelCache + llmisvc (kserve#5318). Whether adapters are in
  scope for that mechanism.
- **ahg-g / kfswain** — GIE-side reviewers who will ask the benchmark question.

---

## 12. ADR index

| ADR | Decision |
|---|---|
| [ADR-001](#adr-001--the-serving-instance-not-the-pod-is-the-unit-of-adapter-residency) | Serving instance, not pod, is the unit of adapter residency |
| [ADR-002](#adr-002--shard-management-runs-as-a-background-loop-in-the-scheduler-process) | Shard management runs as a background loop in the scheduler process |
| [ADR-003](#adr-003--the-controller-declares-floors-the-engine-selects-eviction-victims) | Controller declares floors; engine selects victims |
| [ADR-004](#adr-004--adapter-loading-executes-lazily-in-the-engine-via-the-lora-resolver) | Loading executes lazily in the engine via the resolver |
| [ADR-005](#adr-005--extend-llminferenceservice-loraspec-do-not-add-an-adapterplacement-crd) | Extend `LoRASpec`; no `AdapterPlacement` CRD |
| [ADR-006](#adr-006--placement-intent-is-read-from-a-schemad-api-not-a-configmap) | Placement intent from a schema'd API, not a ConfigMap |
| [ADR-007](#adr-007--weight-distribution-is-a-precondition-not-owned-by-this-feature) | Weight distribution is a precondition (LocalModelCache) |
| [ADR-008](#adr-008--retention-is-the-pin-api-keepalive-traffic-is-interim-only) | Retention is the pin API; keepalive is interim |
| [ADR-009](#adr-009--split-by-loop-shard-manager-in-llm-d-router-declaration-in-kserve) | Split by loop: shard manager in llm-d-router, declaration in KServe |
| [ADR-010](#adr-010--sharding-first-declarative-targets-layered-on-top) | Sharding first; declarative targets layered on top |
| [ADR-011](#adr-011--eviction-visibility-comes-from-the-engine-notification-channel-not-only-the-gauge) | Eviction visibility via the engine notification channel |
| [ADR-012](#adr-012--in-flight-eviction-behaviour-refcount-invariant-admission-time-fail-fast-no-base-fallback) | In-flight: refcount invariant, admission fail-fast, no base fallback |
| [ADR-013](#adr-013--frequency-weighted-eviction-cpu-tier-only-last-phase) | Frequency-weighted eviction: CPU tier only, last phase |
| [ADR-014](#adr-014--adapter-aware-dispatch-is-a-hard-prerequisite) | Adapter-aware dispatch is a hard prerequisite |

---

## 13. References

### vLLM

| Ref | What |
|---|---|
| [vllm#12174](https://github.com/vllm-project/vllm/issues/12174) | RFC — LoRA adapter lifecycle; names `VLLM_ALLOW_RUNTIME_LORA_UPDATING` as development-mode |
| [vllm#14497](https://github.com/vllm-project/vllm/issues/14497) | Eviction of an adapter still in use by a live batch |
| [vllm#14634](https://github.com/vllm-project/vllm/pull/14634) | LoRA resolver plugin implementation |
| [vllm#45325](https://github.com/vllm-project/vllm/issues/45325) | Feature request — expose adapter cache residency as metrics |
| [vllm#45411](https://github.com/vllm-project/vllm/pull/45411) | LoRA events umbrella |
| [vllm#45820](https://github.com/vllm-project/vllm/pull/45820) | Residency metrics implementation — stalled, needs-rebase |
| [vllm#51433](https://github.com/vllm-project/vllm/pull/51433) | Engine notification channel — first split of #45411 |
| [LoRA feature docs (stable)](https://docs.vllm.ai/en/stable/features/lora/) | Current LoRA docs incl. dynamic serving |
| [LoRA docs v0.7.2](https://docs.vllm.ai/en/v0.7.2/features/lora.html) | Historic page carrying the explicit production-risk note |
| [LoRA resolver plugin design](https://docs.vllm.ai/en/stable/design/lora_resolver_plugins/) | Resolver architecture |
| [filesystem_resolver API](https://docs.vllm.ai/en/latest/api/vllm/plugins/lora_resolvers/filesystem_resolver/) | Module reference |

### llm-d-router

| Ref | What |
|---|---|
| [llm-d-router#709](https://github.com/llm-d/llm-d-router/issues/709) | Dynamic LoRA placement / bounded-subset routing — accepted, assigned |
| [llm-d-router#720](https://github.com/llm-d/llm-d-router/pull/720) | Shuffle-sharding scorer — stale-closed; branch `dmitripikus:loras-shuffle-sharding` |

### Gateway API Inference Extension

| Ref | What |
|---|---|
| [GIE v1.3.0 release](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/tag/v1.3.0) | Syncer image deprecated, code removal announced |
| [dynamic-lora-sidecar](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/main/tools/dynamic-lora-sidecar) | The deprecated syncer (may 404 on `main`; browse a tag <= v1.3.0) |
| [Adapter rollout guide](https://gateway-api-inference-extension.sigs.k8s.io/guides/adapter-rollout/) | Worked `vLLMLoRAConfig` / `ensureExist` / `ensureNotExist` example |

### KServe

| Ref | What |
|---|---|
| [kserve#4126](https://github.com/kserve/kserve/issues/4126) | Multi-nodegroup LocalModelCache; node-group annotation requirement |
| [kserve#5318](https://github.com/kserve/kserve/pull/5318) | LocalModelCache support for LLMInferenceService — merged |
| [kserve#5675](https://github.com/kserve/kserve/pull/5675) | LoRA affinity scorer injection into llmisvc default config |
| [LocalModelCache docs](https://kserve.github.io/website/docs/model-serving/generative-inference/modelcache/localmodel) | CRDs, node agent DaemonSet, enablement |
| [Install overview](https://kserve.github.io/website/docs/install/overview) | States LocalModel supports InferenceService only — conflicts with #5318 |
| [LLMInferenceService overview](https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/llmisvc-overview) | P/D separation, multi-node, LoRA adapters |
