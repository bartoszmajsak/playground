# LoRA Fleet Lifecycle Management — Design Notes and ADRs

**Language:** This document uses ASD-STE100 Simplified Technical English.
Sentences are short. The voice is active. Each approved word has one meaning.

**Technical names used in this document:** Kubernetes, CRD, controller,
reconciler, webhook, InferencePool, endpoint, pod, node, node group, DaemonSet,
PVC, RWX, OCI, LWS (LeaderWorkerSet), TP (tensor parallel), PP (pipeline
parallel), EP (expert parallel), MoE, P/D (prefill and decode), EPP (endpoint
picker), GIE (Gateway API Inference Extension), KServe, LLMInferenceService
(llmisvc), LoRASpec, LocalModelCache, vLLM, LoRA, adapter, `max_loras`,
`max_cpu_loras`, `max_lora_rank`, LRU, TTFT, Prometheus.

**Technical verbs used in this document:** to load, to unload, to pin, to unpin,
to evict, to resolve, to reconcile, to scrape, to shard, to route, to dispatch.

**Definitions:**

| Term | Definition |
|---|---|
| **Endpoint** | A network target that the scheduler routes to and scores. |
| **Serving instance** | One vLLM engine process. It has one adapter cache and one `max_loras` budget. It can be one pod, one LWS/TP/PP group, or one side of a P/D pair. |
| **Warm** | The adapter is resident in the cache of a serving instance. |
| **Shard** | The set of serving instances that hold one adapter. |
| **Floor** | The minimum number of serving instances that must keep an adapter warm. |

**Verification status:** Statements with **[verify]** come from architecture
analysis or from secondary sources. Nobody confirmed them against the current
source code. Verify them before you make a decision that depends on them.

All external references have links in [Section 13](#13-references).

---

## 0. Summary

- The requirements use the word "pod" for two different things. Divide the word
  into *endpoint* and *serving instance*. This change makes the MoE requirement
  more general. It also shows a missing P/D requirement. See ADR-001.
- There are three control loops. The dispatch loop and the declaration loop have
  a location. The shard management loop has no location. Both previous attempts
  failed because they put the middle loop into one of the other two loops. See
  ADR-002.
- You cannot guarantee `minWarmReplicas` today. Only the *achieve* function is
  available. The *retain*, *detect*, *restore*, and *verify* functions need
  upstream work. The correct claim today is "usually warm". See Section 4 and
  ADR-008.
- The pin API is a necessary requirement. Nobody filed it upstream. **[verify]**
- The engine loads adapters. The controller does not push them. The resolver
  makes adapter placement a result of request routing. See ADR-004.
- Phase 0 has no upstream dependency. Consistent-hash shard assignment needs only
  endpoint enumeration and adapter-aware dispatch. It gives the largest benefit,
  because it makes each working set smaller than `max_loras`. See ADR-010.
- The vLLM primitives are portable. The controller is not. Every router needs
  residency metrics, the pin API, and eviction events. No router can build fleet
  management without them. The placement algorithm is specific to each router.
- Issue llm-d-router#709 is accepted and assigned. Speak to the assignees before
  you write more. If you do not, you build a competing design.

---

## 1. Objective

The system must give declarative adapter lifecycle management across a fleet.

A Platform Operator declares two things:

- Which adapters must stay warm.
- On how many serving instances each adapter must stay warm.

The system then keeps these targets. It keeps them during demand changes, scale
events, and cache pressure.

---

## 2. Current landscape

### 2.1 vLLM (one serving instance)

| Capability | State |
|---|---|
| Two-tier LRU cache (`max_loras` GPU, `max_cpu_loras` CPU) | Available. The policy is fixed in the code. Evictions move from GPU to CPU, then out. |
| Pin function | Available inside the cache manager. It is not available over HTTP. **[verify]** |
| Static declaration (`--lora-modules`) | Available. It fills the CPU tier at start. It does **not** guarantee residency. You cannot unload these adapters without a restart. |
| Load API | Available. The `VLLM_ALLOW_RUNTIME_LORA_UPDATING` variable controls it. |
| Unload API | Available behind the same variable. It is **the only method to remove an adapter on demand**. |
| LoRA resolvers | Available. See `vllm/plugins/lora_resolvers/{filesystem,hf_hub}_resolver.py`. The base class and registry are in `vllm/lora/resolver.py`. |
| Residency metrics | [vllm#45820](https://github.com/vllm-project/vllm/pull/45820). Stopped. It has the `needs-rebase` label and no approval. |
| Lifecycle events | [vllm#45411](https://github.com/vllm-project/vllm/pull/45411) is the parent issue. [vllm#51433](https://github.com/vllm-project/vllm/pull/51433) is the first part. It is active and has assigned code owners. The LoRA events are a subsequent PR. |
| Configurable eviction policy | Not available. |
| In-flight request count | The cache could evict an adapter that a live batch used. See [vllm#14497](https://github.com/vllm-project/vllm/issues/14497). **[verify on your version]** |

**Production status of the runtime update path.**
[RFC vllm#12174](https://github.com/vllm-project/vllm/issues/12174) calls this
path a development-mode method. The RFC says the path is not correct for
production, because it does not load the adapter on all replicas. The
[v0.7.2 documentation](https://docs.vllm.ai/en/v0.7.2/features/lora.html) says
that this variable is a risk in production, because users can then control
adapter management.

**[verify]:** Read the
[current stable documentation](https://docs.vllm.ai/en/stable/features/lora/).
The page structure changed. It now has an "In-Place LoRA Reloading" section. If
the caution is no longer present, the argument to promote this path to a
production API becomes weaker.

**Metrics defect.** The note in vllm#45820 says that the GPU-tier hit counters
stay at zero. The `activate_adapter()` function uses `__contains__` and
`.touch()`. These calls do not go through the hit counter. You can only infer an
eviction from the change of the metric labels. Correct this defect before you
evaluate a frequency-weighted policy. You cannot weight by a frequency that you
do not measure.

### 2.2 The resolver

The resolver is not a component. It is a plugin class in the vLLM process. You
install nothing. See the
[API reference](https://docs.vllm.ai/en/latest/api/vllm/plugins/lora_resolvers/filesystem_resolver/)
and the
[design document](https://docs.vllm.ai/en/stable/design/lora_resolver_plugins/).
The resolver comes from
[RFC vllm#12174](https://github.com/vllm-project/vllm/issues/12174) through
[vllm#14634](https://github.com/vllm-project/vllm/pull/14634).

To enable the resolver, set two environment variables on the vLLM container:

- Set `VLLM_PLUGINS` to a value that includes `lora_filesystem_resolver`.
- Set `VLLM_LORA_RESOLVER_CACHE_DIR` to a directory path.

The resolver is disabled until you do this. A related plugin,
`lora_hf_hub_resolver`, reads repositories from `VLLM_LORA_RESOLVER_HF_REPO_LIST`.

The resolver operates on a cache miss:

1. A request names the adapter `foo`.
2. If the registry has `foo`, the server serves the request.
3. If the registry does not have `foo`, the server calls each resolver. The
   filesystem resolver looks for a directory `foo` in the cache directory.
4. If the directory exists, the server loads the adapter, registers it, and
   serves the request. If the directory does not exist, the request fails.

The resolver inverts the previous model. The
[sidecar](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/main/tools/dynamic-lora-sidecar)
pushed adapters. It reconciled a ConfigMap into load and unload calls on each
pod. The resolver pulls adapters. This is why GIE could remove the sidecar. The
control plane becomes the process that fills the volume.

Limits of the resolver:

- **No pre-load.** The resolver acts on the cache miss. It cannot act before it.
- **No pin function.** LRU and request demand control residency.
- **No removal path.** If you delete the directory, the cache keeps the adapter.
- **Late model discovery.** An adapter is visible in `/v1/models` only after the
  first request that uses it.

The extension point is important. The `LoRAResolver` class and the
`LoRAResolverRegistry` let you write a resolver for an internal registry, an OCI
artifact, or a LocalModelCache layout. This is a better integration point than a
new sidecar.

### 2.3 Routing (llm-d-router and GIE)

| Capability | State |
|---|---|
| `LoRAAffinityScorer` | Available. It routes to endpoints that serve the requested adapter, from `lora-info-metric`. But it reads `running_lora_adapters`, which is request state, not residency. Change the extractor to `gpu_cached_adapters` and `cpu_cached_adapters`. This is a small PR. It **depends on vllm#45820**. |
| Dynamic LoRA placement | [llm-d-router#709](https://github.com/llm-d/llm-d-router/issues/709). Open, `triage/accepted`, assigned. nilig opened it in March 2026. dmitripikus has the assignment. |
| Shuffle shard assignment | [llm-d-router#720](https://github.com/llm-d/llm-d-router/pull/720). The stale bot closed it in July 2026. The branch `dmitripikus:loras-shuffle-sharding` has the implementation. |
| ConfigMap sidecar syncer | Deprecated in [GIE v1.3.0](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/tag/v1.3.0). The team removes the code. The release note says that equivalent function moves to a different location, but it does not name that location. The [adapter rollout guide](https://gateway-api-inference-extension.sigs.k8s.io/guides/adapter-rollout/) shows the previous usage. |
| Automated adapter rollout pipeline | GIE lists this as future work. |

**Issue llm-d-router#709 states the same problem as the requirements.** It asks
for these functions:

- Route each adapter to a limited subset of pods (k replicas).
- Reshuffle the subset when conditions change.
- Increase k when the pods in the subset become too busy.
- Obey the maximum number of loaded adapters per pod, to prevent many evictions.

The issue lists three failure modes:

- The prefer-loaded policy puts a busy adapter on the pods that already have it.
  Those pods become too busy. Other pods stay idle.
- If you add a traffic score, the adapter goes to more pods. On pods at maximum
  capacity, this removes other adapters. Evictions and reloads then occur across
  the pool.
- The system evicts cold adapters again and again. This causes load delays, high
  tail latency, and short periods of starvation.

**Pull request llm-d-router#720 is the attempt. Its failure mode is
informative.** The author put the logic in a scorer at
`pkg/plugins/scorer/lora_aware.go`. The author deferred two items to a subsequent
PR:

- Rebalance after an endpoint restart or a scale event.
- Base model discovery.

These two items are the join and leave requirements. They do not fit in a scorer.
They need cluster state and a reconcile loop, not a per-request score function.

The PR also failed on one question. A reviewer (ahg-g) asked which validation and
which benchmark establish the algorithm, and what the baseline is. This was in
March. Nobody answered in the thread. The stale bot closed the PR in July.
**Expect the same question.**

Reuse the branch. It already contains the review corrections: one mutex for cache
invalidation, and a `getShardForAdapter` function with one allocation and one
copy. The author shuffles in place. The code is sized for hundreds of pods.

### 2.4 Control plane (KServe)

| Capability | State |
|---|---|
| LLMInferenceService `LoRASpec` | Available. It declares adapters. See the [llmisvc overview](https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/llmisvc-overview). |
| LoRA affinity scorer configuration | Available in the llmisvc default configuration. See [kserve#5675](https://github.com/kserve/kserve/pull/5675). |
| LocalModelCache with llmisvc | [kserve#5318](https://github.com/kserve/kserve/pull/5318) is merged. But the [install documentation](https://kserve.github.io/website/docs/install/overview) says that llmisvc is not supported. **[verify]** |
| LocalModelCache with many node groups | [kserve#4126](https://github.com/kserve/kserve/issues/4126). See the [model cache documentation](https://kserve.github.io/website/docs/model-serving/generative-inference/modelcache/localmodel). |
| Placement and warm targets | Not available. |

### 2.5 Related work

**AIBrix** has a `ModelAdapter` CRD. The CRD has lifecycle phases and a transition
history. The shape is different: one CR for each adapter, with a Service
abstraction. Read it before you design your API. The AIBrix team also concluded
that the control plane alone cannot solve high-density LoRA. **[verify]** — read
their current documentation. Do not rely on this summary.

**TRT-LLM** sets the host cache budget and the device cache budget in bytes. It
does not use a count of adapters. The cache can then hold many small adapters or
a few large adapters. vLLM counts slots. Therefore you must set `max_loras` for
the largest possible rank.

---

## 3. The primary problem: three loops

| Loop | Time scale | Decision | Location |
|---|---|---|---|
| Dispatch | Microseconds, for each request | Which endpoint, from the endpoints that hold the adapter | Scheduler scorer. Available. |
| **Shard management** | **Seconds, when the endpoint set changes** | **Which serving instances hold which adapters** | **No location** |
| Declaration | Minutes, when the operator makes an edit | Minimums, priority, capacity validation | Kubernetes controller |

- Pull request llm-d-router#720 put the middle loop in the request path. It then
  stopped at the deferred items.
- The current requirements put the middle loop in the reconcile loop. This design
  fails because of old data. The LRU cache makes a decision in milliseconds. A
  controller uses a metric scrape that is seconds old. The controller thus selects
  a victim from old data. **A shorter reconcile interval does not correct this.**

---

## 4. Analysis of "ensure minWarmReplicas"

| Function | Requirement | Available today |
|---|---|---|
| **Achieve** — make the adapter resident on N instances | A load call, or a synthetic request through the resolver | Yes |
| **Retain** — keep the adapter against the local LRU cache | The pin API | No |
| **Detect** — find that the count is less than N | Residency metrics or events | No |
| **Restore** — load the adapter again after a loss | Detect and achieve | No |
| **Verify** — report that the target is met | Detect | No |

Only the achieve function is available. All functions that make the target a
guarantee need upstream work.

### 4.1 The failure occurs at the worst time

The example scenario in the requirements shows the problem. Traffic to adapter X
decreases. Traffic to adapter Y increases. At this moment, X is the
least-recently-used adapter on each instance that holds it. The load of Y then
evicts X.

The traffic of an adapter keeps that adapter warm in the steady state. But the
traffic stops at the same moment that the guarantee becomes necessary.

Without the pin function, the sequence is:

1. The controller loads X on instance 7.
2. Requests for other adapters arrive.
3. The LRU cache evicts X.
4. The controller finds this at the next reconcile.
5. The controller loads X again. This evicts a different adapter.
6. Go to step 2.

The period of this cycle is the reconcile interval. The size of the effect
increases with the size of the fleet. The effect is worst near full capacity.

### 4.2 Capacity limits (absent from the requirements)

The pin function uses the same budget that it protects. The scheduler limits the
number of different adapters in one batch to `max_loras`. If you pin all slots,
the instance becomes a dedicated instance. The scheduler can then never put an
unpinned adapter in a batch on that instance.

Apply two limits:

- **For each instance:** `pinned <= max_loras - reserve`. Set `reserve >= 1`. Make
  the value configurable.
- **For the fleet:** `SUM(minWarmReplicas) <= SUM(max_loras - reserve)` across all
  instances.

Enforce these limits with a validating webhook on create and update. Add a
degraded status condition for the case where a scale-down makes a valid
declaration invalid. Also define a priority order. The system uses this order to
select which declarations to obey when the declarations exceed capacity.

Without these limits, silent partial enforcement occurs. Example: an operator
declares 5 adapters at 4 replicas each. The fleet has 12 instances with
`max_loras=2`. The system cannot obey the declaration, but it does not report
this.

### 4.3 Pin inside the shard

Do not select instances at random. Pin the adapter on instances inside the shard
of that adapter. Residency and routing must agree. If they do not agree, the
scorer sends adapter X to the shard members, but the pins are on instances that
never receive traffic for X.

This is the reason to put the shard manager and the pin enforcement in the same
loop. Two components with independent decisions cause this error.

### 4.4 Departure of an instance

- **Controlled departure** (scale-down, drain, cordon): Act on **terminating**
  endpoints. Do not wait for removed endpoints. Load the adapter on the
  replacement instance before the old endpoint leaves. If you act after the
  removal, two problems occur: the count is less than the minimum for a period,
  and a cold start occurs on the instance that receives the traffic.
- **Uncontrolled departure** (crash, node loss): Detect the endpoint removal.
  Restore the adapter on the remaining instances. Apply the cooldown, or a rolling
  restart causes many reloads across the fleet.

### 4.5 The status must show the observed count

Calculate the warm count from scraped residency data. Show the age of that data
with the count.

Do not report the count that the controller intended to place. If you do this, the
resource always reports success. This is worse than no status, because the
operator uses this status for alerts.

---

## 5. Architecture decisions

Each ADR gives the decision, the reason, the results, and the cost. Rejected
alternatives are in [Section 6](#6-rejected-options).

---

### ADR-001 — The serving instance is the unit of adapter residency

**Status:** proposed

**Context.** The `max_loras` and `max_cpu_loras` values apply to one engine
process. In a multi-node deployment (LWS, TP, PP), one leader and its workers are
one vLLM instance. This instance has one adapter cache and one metrics endpoint on
the leader. Eight pods have one set of slots. The requirements use the word "pod"
for the routing target and for the cache owner.

**Decision.** Use two different terms:

| Term | Definition | Applies to |
|---|---|---|
| **Endpoint** | The target that the scheduler routes to and scores | Routing, scores, pool membership |
| **Serving instance** | One vLLM engine process, with one adapter cache and one `max_loras` budget | Warmth, capacity, load, eviction |

Change the name `minWarmPods` to `minWarmReplicas`. Define it against the serving
instance.

**Results.**

1. **The MoE requirement becomes more general.** The requirement "lifecycle
   operations are atomic across the expert parallel group" is one case of a general
   rule. The serving instance is the atomic unit for **all** multi-pod topologies.
   Write the requirement in this general form. Do not write a special case for MoE.
2. **P/D needs a requirement.** An adapter changes the model weights. Therefore the
   prefill instance needs the adapter to calculate the KV data of the prompt. The
   decode instance also needs the adapter for each output token. Both instances need
   it, for the same request. Placement is thus per role, with a pair constraint. If
   you calculate the two shards independently, the intersection can be small or
   empty. Issue llm-d-router#709 and PR #720 do not include this. Both use a flat
   set of equivalent endpoints.
3. **The shard size cannot be a constant.** Prefill instances and decode instances
   often have different resources. Therefore they have different `max_loras`
   budgets. Calculate the shard size from the available slots for each role. If you
   do not, you exceed the capacity of the smaller side. This causes the eviction
   problem that llm-d-router#709 must prevent.
4. Add a new acceptance criterion. A warm target is met only when a request can use
   the adapter from end to end. A per-role count is not sufficient.

**Cost.** Examine each instance of the word "pod" in the requirements. Do not
correct only the three examples above.

---

### ADR-002 — The shard manager is a background loop in the scheduler process

**Status:** proposed

**Context.** See Section 3. The middle loop needs endpoint changes in seconds. It
also needs residency data that is new enough for a decision. A Kubernetes
controller does not have this data. A per-request scorer cannot hold state after
the request ends.

**Decision.** Calculate the shards in a background goroutine in the scheduler (EPP)
process. Recalculate when the endpoint set changes and when new metrics arrive. The
scorer reads the current map. The scorer does not calculate the map.

**Reasons.**

- The scheduler monitors the InferencePool endpoints. Therefore it receives join
  and leave events immediately, not at the next reconcile.
- The scheduler scrapes the metrics of each instance. Therefore residency data has
  no additional cost.
- Dispatch and shard management then use one view of the system. If you divide them
  across two processes, the views become different. The controller can hold that
  adapter X is on instance 7, but the scorer routes with different data.

This is also the smallest change to llm-d-router#720 that removes the blockage on
its deferred items. The review comments moved toward this design. A shard cache
with a mutex in a request handler has the shape of a background loop.

**Results.** The loop needs three items that a scorer does not need:

- **Leader election**, if the scheduler has more than one replica. If you do not
  have it, two replicas send conflicting directives.
- **Desired state from a CR**, not from memory. A restart must not lose the
  placement intent.
- **A cooldown period and a minimum dwell time.** The loop must not react to each
  change in the metrics. The current requirements do not prevent this. Add an
  acceptance criterion.

**Cost and risk.** GIE states that the function of the EPP is to make scheduling
decisions from metrics and capabilities. A goroutine that sends `load_lora_adapter`
calls is outside this function. The calls are also specific to vLLM. Expect
opposition upstream.

There is a precedent for vLLM-specific behavior behind a capability check. Triton
and SGLang set an empty `lora-info-metric`. This disables LoRA affinity for them.

---

### ADR-003 — The controller declares floors. The engine selects the victims.

**Status:** proposed

**Context.** The requirement says that the controller coordinates eviction and
obeys the declared minimums. This implies that the controller selects the victim.
The controller cannot do this correctly. It uses old data. It loses each race
against an LRU cache that decides in milliseconds.

**Decision.** The controller declares **floors**. A floor states which adapters
must stay resident, and where. The engine policy selects the victim from the
**unpinned** adapters. The controller never names a victim.

**Results.**

- The requirement "fleet-wide eviction decisions respect local pod state" becomes
  true by design. It is no longer a distributed consistency problem.
- The engine control that you need is the **pin** function, not an **evict**
  function. This is the reason that the pin API is a P0 dependency. See ADR-008.
- Old data no longer affects correctness. It only affects the delay before a new
  floor becomes effective.

**Cost.** This decision needs the pin API. Nobody filed the pin API upstream. Until
the API exists, floors are best-effort. See ADR-008.

---

### ADR-004 — The engine loads adapters on the resolver miss path

**Status:** proposed

**Context.** Three different functions have the name "load". The previous sidecar
model made all three a push from the control plane.

**Decision.** Divide the three functions:

| Function | Owner |
|---|---|
| Decide **that** an adapter must be warm | The controller, from the declaration |
| Decide **which** instances hold it | The shard manager. See ADR-002. |
| **Execute** the load | **The engine, on the resolver miss path** |

The controller and the shard manager send **routing intent**. They do not send load
commands. To load an adapter on an instance, route a request to that instance.

**Reasons.** The weights are already on the node. The resolver is enabled.
Therefore:

- The common path does not need `VLLM_ALLOW_RUNTIME_LORA_UPDATING`.
- There is no reconciler on each pod, and thus no difference between the desired
  state and the actual state.
- The control plane does not need network access to each pod.
- The load occurs at the time and the location where the request needs it.

Placement becomes a result of dispatch. It is not a separate command.

**Results.** Three cases need more than routing. The shard manager starts all three,
because all three must name one instance and know its state:

1. **Pre-load at scale-up.** A new instance must receive adapters before traffic,
   not at the first miss.
2. **Retirement.** The unload call is the only method to remove an adapter on
   demand.
3. **Pin.** The pin function sets the floor. Routing pressure stops when an adapter
   becomes cold.

**Dependency risk.** Two of these three cases need the pin API and a
production-ready unload API. These are the upstream gaps. The lazy load path is
available today. The three exception paths are not. This is another reason to make
Phase 0 shard assignment only. See ADR-010.

**Note on warm-up requests.** A warm-up request is a true inference request. It uses
a batch slot and one forward pass. Set `max_tokens` to 1 and use a short prompt.

Under P/D, a warm-up request follows the normal route. It therefore warms the
prefill instance and the decode instance that the router selected. To warm one
specific instance, send the request to the pod directly and bypass the router. The
shard manager thus needs network access to the pods, not only to the gateway.
Compare this with your network policy.

---

### ADR-005 — Extend `LoRASpec`. Do not add an `AdapterPlacement` CRD.

**Status:** proposed. One verification is open.

**Decision.** Add `minWarmReplicas` and `priority` as new fields on the existing
`LoRASpec`. Do not add a CRD.

**Reasons.** These values are attributes of one adapter. A new CRD has these costs:
two objects to keep synchronized, two sets of RBAC rules, a divided status, and a
second reconcile relation. It gives no benefit at the current scale. The llmisvc
controller already owns the pods and the pool. The placement status must describe
these objects.

**The verification that decides this.** Does an edit of `LoRASpec` cause a pod roll
today?

If the controller writes the adapters into the container arguments
(`--lora-modules ...`), or into any other part of the pod template, each placement
edit changes the pod template hash. Kubernetes then starts a rolling update. This
breaks the runtime-change requirement. It also evicts each warm adapter in the
fleet. **[verify] this in the llmisvc reconciler before you make the decision.**

If the edit does cause a pod roll, do not add a CRD. Use one of these two methods:

1. **Divide the field, not the resource.** Keep the declaration where it changes the
   pod specification. Move the placement targets to a path that the workload
   reconciler ignores.
2. **Better method: remove adapters from the pod template.** With the resolver, you
   do not need `--lora-modules`. The pod specification then has no adapter data.
   This agrees with the new GIE direction. It can be a prerequisite in any case.

**Results.**

- Add an acceptance criterion: **an edit of a placement target must not change the
  pod template**.
- **Keep the reconcile loops separate.** Use one controller-manager, but two
  controllers on the same object. The workload reconcile is slow and idempotent. The
  placement reconcile uses metrics and needs its own rate limiter and cooldown. If
  you combine them, a fast placement loop prevents workload reconciles.

---

### ADR-006 — Read the placement intent from an API with a schema, not from a ConfigMap

**Status:** proposed

**Context.** The deprecated GIE syncer read its desired state from a ConfigMap.
Therefore a ConfigMap that llmisvc fills is an established pattern.

**Decision.** The scheduler reads the placement intent from the InferencePool or
from a CR that it owns. The llmisvc controller fills this object. It already fills
the pool in the same way.

**Reasons to reject the ConfigMap.**

- A ConfigMap has no schema, no status subresource, and no conditions. The
  requirement "the operator can see whether each adapter meets its target" needs a
  location for the observed state. With a ConfigMap, you write the status into the
  same ConfigMap or into annotations.
- A ConfigMap has no validating webhook. The capacity check in Section 4.2 then has
  no location. Invalid declarations fail without a report.
- A ConfigMap connects the scheduler to KServe. The EPP then operates only when
  llmisvc fills the ConfigMap. This moves the dependency. It does not remove it.

**Results.** KServe users use `LoRASpec`. Users of plain llm-d and GIE write the CR
directly. The scheduler has one input in both cases, with a schema and a status.

---

### ADR-007 — Weight distribution is a prerequisite. This feature does not own it.

**Status:** proposed

**Context.** The requirements exclude node-level distribution. But no component does
this for adapters today. Therefore you must name the prerequisite and its owner.

**Decision.** An existing mechanism makes the adapter weights available on the local
disk of the node. Use **LocalModelCache** where it is available. This feature
validates availability. It does not create availability.

**Reasons to use LocalModelCache.** It pulls artifacts to the node with an agent on
each node. It is not a shared RWX volume, and it is not a push.

It has four CRDs:

- `LocalModelCache` — which model to cache from persistent storage to the local
  storage of the node.
- `LocalModelNodeGroup` — which nodes.
- `LocalModelNode` — the cache status for one node.
- `LocalModelNamespaceCache` — a namespace-scoped variant for multi-tenancy.

To use it, declare `sourceModelUri`, `modelSize`, and the target `nodeGroups`.
KServe then starts a download job. It also creates an agent DaemonSet on the
matching nodes. Model caching is disabled by default. Enable `localModel` in the
`inferenceservice-config` ConfigMap. Many node groups are supported, with one
download job for each group. See
[kserve#4126](https://github.com/kserve/kserve/issues/4126).

Three functions are then available without additional work:

- **Runtime addition without a restart.** A new LocalModelCache starts a download
  job. No pod restarts. This meets the runtime-add requirement at the distribution
  layer.
- **A fleet-wide availability view.** The `LocalModelNode` object holds the cache
  status of each node. This is the input that the availability check needs.
- **Deletion.** The team added the delete verb to the localmodel PV and PVC RBAC
  rules.

**Three problems that are specific to adapters.**

1. **Node group affinity breaks the flat fleet model.** To use the cache, you must
   put a node group annotation on the workload. Kubernetes then schedules the
   workload onto the matching nodes. The `sourceModelUri` value and the `nodeGroup`
   value must agree.

   Shard assignment assumes that each instance can serve each adapter. If adapter A
   is on the H100 group, and the shard of A includes an instance on an A100 node,
   the resolver fails at request time.

   You have two options. Cache each adapter to each node group in the pool. This
   increases the number of jobs and the disk usage. Or **make the shard manager
   aware of node groups**. It then calculates the shard only from instances whose
   nodes hold the weights. This is a true constraint on the placement algorithm. Put
   it in the requirements. *No person in the upstream threads has stated this
   problem.*
2. **Granularity.** LocalModelCache is for a small number of large base models. It
   has one `modelSize` value for each CR, and one download job for each CR and node
   group. 15 to 50 adapters across 3 node groups gives many CRs and many jobs, for
   artifacts of tens of megabytes. Examine whether a group function exists, or
   whether you need one.
3. **Path layout contract.** The filesystem resolver looks for a directory with the
   same name as the requested adapter, in `VLLM_LORA_RESOLVER_CACHE_DIR`.
   LocalModelCache writes its own layout. Correct this in one of two ways. Set the
   resolver cache directory to the mount point and control the names. Or write a
   `LoRAResolver` plugin that reads the LocalModelCache layout. The registry
   extension point exists for this purpose.

**Results.** Validate availability with an `AdapterNotAvailable` status condition.
The resolver fails with a request error at load time. The operator cannot see this
error until a user reports a problem.

**Write the layout contract in the documentation:** the directory name, the adapter
name, the model name in the request, and the key in `LoRASpec` are the same string.
If you change one name and not the others, the request fails with a 404 error and no
other indication.

**Alternatives if LocalModelCache cannot hold adapters:**

| | Init container | RWX PVC and a writer | Object store or OCI mount |
|---|---|---|---|
| Runtime add without restart | **No** | Yes | Yes |
| Infrastructure to operate | None | Sync job and garbage collection | None |
| Correct for adapter size (tens to hundreds of MB) | — | — | Yes. It gives registry semantics, immutable digests, and existing RBAC. |
| Blocks the runtime-add requirement | Yes | No | No |

Mount the store directly. Use an object store CSI driver or an OCI artifact volume.
With this option, you build nothing.

---

### ADR-008 — The pin API gives retention. Keepalive traffic is temporary.

**Status:** proposed. The pin API does not exist upstream.

**Decision.** Enforce `minWarmReplicas` with the pin function, inside the shard of
the adapter. Until the pin API exists, enforcement is best-effort. State this in the
documentation.

**Reasons to reject keepalive traffic as the permanent mechanism.** Keepalive
traffic operates, and it is the only method available today. But adapter X stays
resident only if the system touches X more frequently than it touches `max_loras`
other adapters.

Example: `max_loras` is 4 and 20 adapters are in rotation. The necessary synthetic
request rate is then a large fraction of the true traffic.

Keepalive traffic also uses batch slots and GPU time. It changes the request counts,
the TTFT values, and the cold-start metric. The cold-start metric then counts your
own synthetic traffic as warm-served.

If you ship keepalive traffic as a temporary measure, mark the synthetic requests.
Use a header or a reserved request-ID prefix. The metrics layer can then remove
them. Mark the mechanism as temporary in the documentation. The pin API replaces it.

**Requirements for the pin API.** Add `pin_lora_adapter` and `unpin_lora_adapter`
endpoints. Put them with the existing load and unload endpoints, in
`vllm/entrypoints/serve/lora/api_router.py` and `protocol.py`. Connect them through
the frontend, `AsyncLLM`, the engine core, and `LRUCacheWorkerLoRAManager`, to the
pin path of the cache manager.

Also do these items:

- Reject a pin request that uses the last free slot.
- Report the pinned state in the residency metrics. The controller can then verify
  the state.
- Apply the pin on **all ranks** of a multi-rank group.
- Pins are process state. A restart removes them. Therefore the controller must
  reconcile pins continuously. It must not send the pin request one time only.

**Cost.** The engine work is about one week, or a few hundred lines. The upstream
cost is larger. This is a new public API on a surface with security consequences.
The `VLLM_ALLOW_RUNTIME_LORA_UPDATING` variable protects this same surface for that
reason.

Expect design discussion on these questions: Is it an admin API? Does it need its
own control variable? How does it interact with the resolver lazy-load path?

The calendar time is weeks to some months. This is true even if you write the code
quickly. Therefore file the RFC first and depend on the API last.

**An unpin operation is not an unload operation.** An unpin operation returns the
adapter to the normal LRU candidate set. The cache can then evict it later, under
pressure. To remove an adapter immediately, for a rollback or a tenant departure,
you need the unload call.

Therefore the pin function replaces the unload call in the **rebalance** path. It
does not replace it in the **retirement** path. If you use only the resolver, two
statements become different: "the configuration no longer has the adapter" and "no
instance can serve the adapter". The time between them has no limit.

---

### ADR-009 — Divide by loop: the shard manager in llm-d-router, the declaration in KServe

**Status:** proposed

| | KServe llmisvc | llm-d-router | GIE | Standalone |
|---|---|---|---|---|
| Owns the workload | Yes | No | No | No |
| Owns the pool endpoints | Through the pool | Yes | Yes | Monitors them |
| Has an accepted issue | No | **Yes (#709)** | No | — |
| Must be model-server agnostic | No | Less strict | **Strict** | — |
| Available to non-KServe users | No | Yes | Yes | Yes |

**Decision.**

- Put the **shard manager** in llm-d-router. Issue #709 is accepted and assigned
  there. Write it as a **GIE scheduler plugin**, not as router-specific code. This
  gives the function to the interface, not to one router.
- Put the **CRD and the reconciler** in KServe, as the declarative surface.
- Put the shard manager behind a **contract that monitors an InferencePool**. Users
  of plain llm-d and GIE then also have the function.

**Reasons.** The customer impact statement in the requirements says "any llm-d
deployment". A KServe-only delivery does not meet this statement.

The feature also needs a scheduler. See ADR-014. Therefore llm-d-router is the
primary location, and KServe is the convenient surface. This is a structural reason,
not a political reason.

---

### ADR-010 — Shard assignment first. Declarative targets are a layer above it.

**Status:** proposed

**Decision.** Implicit placement with consistent-hash shard assignment is the base
layer. Declared minimums are a layer above it. They are not a replacement.

**Comparison.**

| | Implicit (shard assignment) | Explicit (declared targets) |
|---|---|---|
| Mechanism | Consistent hash from adapter to k instances. Routing keeps them warm through the LRU cache. | The controller declares floors. The pin function enforces them. |
| Upstream dependencies | **None** | Metrics, pin, events |
| Guarantee | Statistical. The working set is limited. Evictions are rare. | A declared floor and priority levels. |
| Can state priority or tenancy | No | Yes |
| Related work | The #720 branch. Ready to reuse. | None |
| Failure mode | A busy adapter can still overload its shard. | Repeated eviction cycles, if the pin API does not exist. |

Shard assignment makes the working set of each instance smaller than `max_loras`.
Evictions then become rare. The absence of the pin API then has a small effect.

Declared minimums give the functions that shard assignment cannot give: priority,
guaranteed warmth for one tenant, and controlled behavior at scale events.

**Result: the benchmark obligation.** Compare the declarative controller against
**shard assignment**. Do not compare it against the naive prefer-loaded policy. Pull
request llm-d-router#720 failed on this question.

Show that eviction cycles continue with sharded routing, before you build a control
plane. Measure p99 TTFT and the number of reloads. Use a Zipf distribution of
adapter requests.

---

### ADR-011 — Use the engine notification channel for eviction visibility

**Status:** proposed. **[verify]** the delivery behavior.

| | [vllm#45820](https://github.com/vllm-project/vllm/pull/45820) (Prometheus gauge) | [vllm#45411](https://github.com/vllm-project/vllm/pull/45411) and [vllm#51433](https://github.com/vllm-project/vllm/pull/51433) (engine notifications) |
|---|---|---|
| Status | Stopped. Needs rebase. No reviewer. | Active. Ready for review. Code owners assigned. |
| Delivery | A scrape. It loses evict and reload pairs between scrapes. | The state change starts it, for in-tree producers. **[verify]** |
| Per-rank visibility | No | **Yes.** It keeps the data of each rank. |
| Agreement between API servers | — | It broadcasts, thus all `/metrics` endpoints agree. |
| Gives the reason for the action | No | Yes, as planned. The LoRA events are a subsequent PR. |

**Decision.** Use the notification channel as the primary source of lifecycle
events. Use the gauge for point-in-time residency. Do not make the design depend
only on the gauge.

**Reason.** A Prometheus gauge cannot meet the requirement "each lifecycle event is
visible with the reason". Between two scrapes, you lose each evict and reload pair.
These pairs are the events that matter.

**Details of vllm#51433.** The file `vllm/v1/notifications.py` defines a tagged
msgspec union. It includes `CustomNotification(key, payload)` and a worker buffer
that is local to the process. The `WorkerBase.take_notifications()` function empties
the buffer. The `EngineCore.gather_worker_notifications()` function collects the
data through `collective_rpc("take_notifications")`. The results leave the engine in
`EngineCoreOutputs.engine_notifications`.

Two properties are important:

- **The events of each rank stay available.** The previous method wrote into
  `ModelRunnerOutput`. This method reached only the output rank of the executor.
  Producers on other ranks lost their data. Paths that returned early also never
  emptied the buffer. One example is a non-last PP rank with
  `with_kv_conn_output_only`.

  The new method keeps each rank. This is the transport-layer answer to the MoE
  atomicity requirement. It makes detection of a **partial** load or unload across an
  EP group possible. Without it, you receive data only from rank 0. You then cannot
  distinguish "loaded on all ranks" from "loaded on the rank that answered".
- **All API servers agree.** The `EngineCoreProc` object broadcasts to each API
  server. All `/metrics` endpoints then agree. This removes a class of controller
  error, where two scrapes of one instance give different data.

**[verify] these three items:**

- Is the consumer a stream that you can subscribe to? Or does the data terminate in
  `/metrics`? The PR names a separate Rust frontend consumer and mentions `/metrics`.
  This answer sets the maximum data age for the requirement "local evictions are
  visible to the controller".
- Does a state change start the delivery? Or does a poll interval control it? The
  `VLLM_WORKER_NOTIFICATION_POLL_INTERVAL` variable is off by default. A LoRA manager
  is in-tree. Therefore it must start a gather operation at the state change.
- Does the `mrv2` label mean that this is for Model Runner V2 only?

The author works at Red Hat. If this is your organization, this is an internal
discussion. It is the fastest method to make the LoRA eviction events correct for
your controller. The schema design is not complete.

---

### ADR-012 — In-flight behavior: a reference count, admission-time rejection, no base fallback

**Status:** proposed

**Context.** The requirement puts three configurable behaviors in one line:
queue-and-reload, fail-fast, and fallback-to-base. Their feasibility is very
different.

**Decision.**

1. **Do not evict an adapter that has in-flight requests.** Implement this as a
   correctness rule, not as a policy. Use a reference count and pin the adapter while
   the count is more than zero. This is the true subject of
   [vllm#14497](https://github.com/vllm-project/vllm/issues/14497).

   One limit applies: the number of different in-flight adapters cannot exceed
   `max_loras`, or a deadlock occurs. Therefore apply the reference count to the
   **running batch** only. Do not apply it to the full queue. **Implement this item.**
2. **Queue-and-reload is the current behavior.** The GPU tier evicts the adapter, but
   the CPU tier keeps it. The engine then loads it again without a visible effect. The
   true requirement is to make this behavior explicit and to give it a **limit**. Set
   a maximum wait time and define the action after that time. There is little to
   configure.
3. **Support fail-fast at admission only.** Do not support it during token
   generation. Do not stop a partially streamed response because of a cache decision.

   At admission, return 503 with `Retry-After`. Do this when the adapter is cold and
   the cache has many evictions. This is load shedding. It operates correctly with
   gateway retries.
4. **Remove fallback-to-base.** A base model response to a request for a fine-tuned
   model is incorrect, not degraded. The adapter can change SQL output, tool-call
   format, tenant behavior, and safety behavior.

   This function needs per-request consent and a response field that reports the
   substitution. Upstream will probably not accept it as engine-level configuration.

**Reason for the general approach.** The statement "this instance does not have the
adapter warm" is a routing decision. If you put all three behaviors in vLLM, you
duplicate the function of the gateway. The gateway has the residency signal.

---

### ADR-013 — Frequency-weighted eviction: CPU tier only, in the last phase

**Status:** proposed. Deferred.

**Decision.** If you build this function: apply it to the **CPU tier**
(`_registered_adapters`), use a scheme that reduces old counts, and do the work
last.

**Reason for the CPU tier only.** A CPU-tier eviction costs a reload from disk or
object storage. This takes hundreds of milliseconds to seconds. A GPU-tier eviction
costs a host-to-device copy. This takes single-digit milliseconds. The difference is
two orders of magnitude.

GPU membership is also not a free choice. The scheduler limits the number of
different adapters in a batch to `max_loras`. The worker must therefore hold the
adapters that the batch uses. The only free decision is which idle adapter keeps a
free slot.

**Reason to reduce old counts.** Simple LFU keeps obsolete data. The adapter that
was busy yesterday then stays resident permanently. Use W-TinyLFU. It has a
count-min sketch and an admission window. This is the Caffeine design. Or use a
score with exponential decay.

Add a size term. The reload cost increases with the rank and the number of target
modules. Use a GDSF-type function: `freq / bytes + clock`.

**Prerequisite.** Correct the hit accounting first. The GPU-tier counters do not
operate, because `activate_adapter()` does not use the counter.

**Files to change** (a few hundred lines):

- `vllm/utils/cache.py` — Make `LoRALRUCache` accept a policy for victim selection.
  Replace the recency `popitem()` call. Keep the code that skips pinned adapters.
- `vllm/lora/model_manager.py` — Make `remove_oldest_adapter()` a call to the policy.
  Record hits on the activate path.
- `vllm/lora/worker_manager.py` — Make the same change at the worker layer.
- `vllm/config/lora.py` and `EngineArgs` — Add `--lora-eviction-policy` and the decay
  half-life value.
- `tests/lora/` — Add tests and a Zipf-distribution benchmark.

**Reason to do this last.** The code is not the difficult part. Maintainers ask for
p99 TTFT and reload counts against LRU, with a skewed distribution. You cannot make
that chart before the metrics exist.

If ADR-010 operates correctly, the working set fits in the cache and evictions are
rare. A better policy then gives a small benefit. Sequence: vllm#45820, then the
accounting correction, then the policy.

---

### ADR-014 — Adapter-aware dispatch is a mandatory prerequisite

**Status:** proposed

**Context.** The feature does not depend on the EPP. It depends on four capabilities:

| Capability | Function |
|---|---|
| 1. Enumerate instances and detect changes | Shard assignment, rebalance at join and leave |
| 2. Observe residency for each instance | Detect, restore, verify, status |
| 3. Dispatch to a selected instance | Warm serving. This converts placement into cache hits. |
| 4. Send calls to a specific instance | Explicit load, unload, and pin |

| Topology | Capabilities | Result |
|---|---|---|
| llm-d-router EPP | 1, 2, 3, 4 | The full feature |
| A GIE-conformant endpoint picker | 1 and 3 directly. 2 through the metrics scrape that GIE already does. | The full feature, **if the algorithm is a GIE scheduler plugin** |
| Other routers (Dynamo, production-stack, AIBrix) | Their own equivalents of 1 to 3 | They implement the algorithm again. They cannot implement the engine part again. |
| A plain Kubernetes Service with kube-proxy | None of 1 to 3 | Uniform residency only |

**Decision.** Add this scope statement to the requirements: *Fleet lifecycle
management needs adapter-aware dispatch. Without it, the only supported
configuration is uniform residency on all instances.*

**Reason.** The kube-proxy component balances traffic at layer 4. It has no adapter
data. Therefore you cannot send adapter A to the instances that hold adapter A.
Shard assignment is then not possible.

The pin function still operates. A controller with network access to the pods can
pin an adapter in any topology. But the pin does not become warm serving. If you pin
an adapter on 4 of 12 instances, 8 of 12 requests go to an instance without the
adapter.

Only one configuration operates: set `minWarmReplicas` to the instance count. This
means that you set `max_loras` to hold the full adapter set. For a small adapter set
without a router, this is the correct instruction.

**Result.** This statement prevents a later bug report that says "the feature does
not operate with a plain Service". It also tells that operator what to do.

**Related conclusion: the vLLM primitives are portable. The controller is not.**
Residency metrics, the pin API, eviction events, and a configurable eviction policy:
each router needs these, and no router can build fleet management without them. The
placement algorithm is specific to each router.

Use this argument to file the pin RFC. It is stronger than "this removes a blockage
on our P0". It is also a better argument upstream.

---

## 6. Rejected options

This section keeps the reasons. Do not discuss these options again from the start.

### 6.1 A dedicated `AdapterPlacement` CRD

**Rejected. Use an extension of `LoRASpec` instead.** See ADR-005.

The `minWarmReplicas` and `priority` values are attributes of one adapter. They are
new fields on an existing alpha API.

A separate resource has these costs: two objects to keep synchronized, two sets of
RBAC rules, a divided status, and a second reconcile relation. It gives no benefit at
the current scale. The llmisvc controller already owns the pods and the pool. The
placement status must describe these objects.

*Examine this option again if:* an edit of `LoRASpec` causes a pod roll, **and** you
cannot divide the fields, **and** you cannot remove adapters from the pod template.

### 6.2 The EPP owns placement in the request path (the llm-d-router#720 design)

**Rejected. Use a background loop in the same process instead.** See ADR-002.

- A placement decision takes seconds, because it loads weights. A routing decision
  takes microseconds. If you combine them, you must block the request path or start
  asynchronous work from a per-request scorer. The second option causes repeated
  eviction cycles.
- Scorer state is temporary. You can rebuild it from a scrape. Placement state is
  desired state. It must survive a restart, and a loop must reconcile it. If the
  scorer owns it, you must add leader election, persistence, and a reconcile loop. You
  then have a controller inside a data-plane component.
- The failure behavior is different. If the scheduler stops, the system must fall back
  to simple load balancing. If the placement authority stops, the desired state must
  freeze. The pods must not change.

Pull request #720 gives the evidence. Its two deferred items, rebalance at endpoint
changes and base model discovery, are the two items that do not fit in a scorer. The
author did not return to them.

### 6.3 A dedicated fleet control plane that selects eviction victims

**Rejected. Use floors and engine-local victim selection instead.** See ADR-003.

A reconcile loop operates in seconds. The vLLM cache decides in milliseconds. Each
victim that the controller names comes from old data. The controller loses this race
each time. A shorter interval does not correct this. It only increases the number of
API calls.

AIBrix made a similar conclusion independently. The control plane alone cannot solve
high-density LoRA.

### 6.4 The EPP reads placement from a ConfigMap that llmisvc fills

**Rejected. Use an API with a schema instead.** See ADR-006 for the full reasons: no
schema, no status subresource, no validating webhook, and a new dependency on KServe.

Note that this was the mechanism of the deprecated syncer. The pattern is
established. But an established pattern can still be obsolete.

### 6.5 A new version of the GIE dynamic-lora-sidecar

**Rejected.** GIE deprecated it in v1.3.0 and removes the code.

The sidecar also needs `VLLM_ALLOW_RUNTIME_LORA_UPDATING` on each pod. It is a
reconciler on each pod, with the state differences that this design causes.

The resolver gives the same function with a pull design, no control variable, and no
sidecar. See ADR-004. If you need a different source, write a `LoRAResolver` plugin.
Do not write a sidecar.

### 6.6 Keepalive traffic as the permanent retention mechanism

**Rejected as permanent. Accepted as temporary.** See ADR-008.

The necessary synthetic request rate increases with `max_loras` and with the number
of adapters in rotation. The traffic uses batch slots and GPU time. It also corrupts
the cold-start metric that the requirements need.

Use it as a temporary measure only. Mark it as temporary. Mark the synthetic requests
so that the metrics layer can remove them.

### 6.7 Fallback to the base model when the adapter is evicted

**Rejected.** See ADR-012.

A base model response to a request for a fine-tuned model is incorrect, not degraded.
SQL adapters, tool-call formats, tenant behavior, and safety behavior all change
meaning.

This function needs per-request consent and a response field that reports the
substitution. Upstream will probably not accept it as engine-level configuration.

### 6.8 Fail-fast during token generation

**Rejected.** See ADR-012. Do not stop a partially streamed response because of a
cache decision. Use fail-fast at admission. There it is load shedding, and it operates
correctly with gateway retries.

### 6.9 "Static" and "dynamic" adapters as operator-visible modes

**Rejected.** An operator reads "static" as "guaranteed warm". This is not correct.

The `--lora-modules` flag fills the CPU tier at start. The LRU cache still controls
GPU residency. If the declared adapters exceed `max_cpu_loras`, the cache also evicts
them from the CPU tier. After an adapter becomes resident, a statically declared
adapter and a dynamically loaded adapter are **identical in the cache**.

Give one declaration surface. The controller then selects the mechanism.

| | `--lora-modules` | Load and unload API | Resolver |
|---|---|---|---|
| Add at runtime | No. Needs a restart. | Yes | Yes. Lazy, at the cache miss. |
| Remove at runtime | **No** | **Yes. The only mechanism.** | No |
| Changes the pod specification | Yes. Edits cause a pod roll. | No | No |
| Ready for production | Yes | No. Behind a control variable. | Yes |
| In `/v1/models` at start | Yes | At load time | Only after the first request |

Keep `--lora-modules` for two cases only:

- A single-instance deployment with no scheduler.
- Model discovery at start, if a component enumerates models before traffic. Examples
  are client SDKs and model-name validation at the gateway.

Two results follow:

- **You cannot unload a statically declared adapter.** The controller must know which
  adapters these are, and must show this in the status. If it does not, rebalance
  fails without a report. This occurs on the instances where the operator wanted more
  safety.
- **The `max_lora_rank` value is fixed at start.** vLLM assigns slots for the largest
  rank. It rejects an adapter with a larger rank at load time. Add a validation rule
  to the declaration. This is not a reason to keep static declaration.

### 6.10 A weight sync controller that reads `LoRASpec`

**Rejected.** See ADR-007.

Weights are immutable and shared. You publish them one time and delete them later.
Declarations change frequently. If you connect them, each placement edit becomes a
storage operation.

Also, if you remove an adapter from one CR, you must count references across all CRs.
Only then do you know whether you can delete the file. This is the "adapter storage,
versioning, and registry" scope that the requirements exclude. If you build it, you
accept the scope that you removed.

*If you want automated distribution later:* write a separate optional controller with
its own CR. The CR holds a source (URI, registry reference, secret) and counts
references across consumers. This is a different feature with a different scope. If
you keep it separate, the placement work can ship.

### 6.11 An init container as the only distribution mechanism

**Rejected as the only mechanism.**

An init container fills a volume before the server starts. To add an adapter after
that, you must restart the pod. This evicts each warm adapter in the fleet. It also
breaks the runtime-change requirement.

An init container is correct as a start-up mechanism for a known adapter set. It
cannot be the only path.

### 6.12 Frequency-weighted eviction on the GPU tier

**Rejected. Use the CPU tier only.** See ADR-013.

GPU membership is mostly not a choice. The scheduler limits the number of different
adapters in a batch to `max_loras`. The worker must hold the adapters that the batch
uses. The only free decision is which idle adapter keeps a free slot. The cost
difference also puts the value on the CPU tier: single-digit milliseconds for a
host-to-device copy, against seconds for a reload.

### 6.13 A byte-budget cache (the TRT-LLM model)

**Not selected now.**

TRT-LLM sets the host cache budget and the device cache budget in bytes. It does not
count adapters. The cache can then hold many small adapters or a few large adapters.

This model is possibly better. vLLM counts slots, thus you must set `max_loras` for
the largest possible rank. But this change to the vLLM allocator is large, and it is
not on the critical path. Record it as a long-term direction.

---

## 7. Work to implement

### 7.1 Upstream vLLM

| Item | Size | Status |
|---|---|---|
| Residency metrics | Small | [vllm#45820](https://github.com/vllm-project/vllm/pull/45820) exists. Support it, or take ownership of it. |
| **Pin and unpin over HTTP** | A few hundred lines in the engine. **The RFC and the review cycle have the longest lead time.** | **Not filed. File the RFC now.** |
| LoRA events on the notification channel | A subsequent PR to [vllm#51433](https://github.com/vllm-project/vllm/pull/51433) | Active upstream. Give input on the schema now. |
| In-flight reference count | Small | A correctness rule. Apply it to the running batch. |
| Configurable eviction policy | Medium | Not started. Needs the accounting correction first. |

### 7.2 Routing

- Change the affinity scorer extractor to residency (`gpu_cached_adapters`). This is
  small. It depends on vllm#45820.
- Reuse the shuffle shard assignment code from llm-d-router#720. Move the shard
  calculation out of `Score()` into a background loop. Add rebalance at endpoint
  changes and base model discovery. These are the two deferred items.
- Calculate the shard size from the available slots **for each role**. Do not use one
  constant.
- Make the shard calculation **aware of node groups**. See ADR-007, problem 1.
- Apply the P/D pair rule. Pair only endpoints where the adapter is warm on both
  sides. Or accept a defined cold-start cost on one side.
- Write the code as a **GIE scheduler plugin**, not as router-specific code.

### 7.3 Control plane

- Extend `LoRASpec` with `minWarmReplicas` and `priority`.
- Add a validating webhook. It checks capacity feasibility, adapter path availability,
  and the rank limit.
- Add status data: the observed warm count with its age, one condition for each
  adapter, and lifecycle events with the reason.
- Make sure that a placement edit does not change the pod template.
- Use separate reconcile loops for placement and workload, with separate rate
  limiters.

---

## 8. Sequence of work

**Phase 0. No upstream dependency.** Reuse the shard assignment code. A consistent
hash needs only endpoint enumeration and adapter-aware dispatch. It does not need
metrics, the pin API, or events.

Make the working set of each instance smaller than `max_loras`. Then measure the
result against the naive prefer-loaded policy. Use a Zipf distribution of adapter
requests. Measure p99 TTFT and the number of reloads.

This phase answers the question that stopped llm-d-router#720. It also gives the
baseline for all later measurements.

**Phase 1. Declare and observe.** Extend `LoRASpec`. Build the controller, the
capacity validation, and the status. This phase needs eviction visibility. Use the
notification channel. Do not wait for the gauge.

**Phase 2. Guarantee.** The pin function changes "usually warm" into a floor. It also
lets you remove the keepalive mechanism. File the RFC in Phase 0. Its calendar time is
the longest.

**Phase 3. Tune.** Add frequency-weighted eviction. This work is independent. It gives
the smallest benefit if Phase 0 operates correctly. It is also the easiest item to
defer.

**Do not make all three upstream items mandatory.** Set the P0 scope to the functions
that shard assignment gives. The pin API and the events then improve the guarantee.
They do not block the release.

Note the corrected dependency order. **The events are more advanced than the
metrics.** Pull request vllm#45820 has no reviewer. Pull request vllm#51433 is active
with assigned code owners. Examine whether eviction visibility can come from the
notification channel.

---

## 9. Changes to the requirements

| Current requirement | Change |
|---|---|
| "minimum warm pod count" | Change to `minWarmReplicas`. Define the serving instance. See ADR-001. |
| MoE expert-parallel atomicity | Make it general for all multi-pod serving units. See ADR-001. |
| — | **New.** P/D: a warm target is met only when a request can use the adapter from end to end. See ADR-001. |
| "the controller coordinates eviction" | Change to: the controller declares floors, the engine selects victims. See ADR-003. |
| — | **New.** Capacity feasibility validation, a degraded condition, and a priority order when declarations exceed capacity. See Section 4.2. |
| — | **New.** A cooldown period and a minimum dwell time before rebalance. See ADR-002. |
| — | **New.** A placement edit must not change the pod template. See ADR-005. |
| — | **New.** An adapter availability prerequisite and an `AdapterNotAvailable` condition. See ADR-007. |
| — | **New.** Node-group-aware placement, where LocalModelCache node groups are in use. See ADR-007. |
| "in-flight behavior configurable (3 modes)" | Change to: a reference count rule and admission-time fail-fast. Remove fallback-to-base. See ADR-012. |
| AdapterPlacement CRD | Change to fields on `LoRASpec`. See ADR-005. |
| — | **New scope statement.** The feature needs adapter-aware dispatch. See ADR-014. |
| Status "meets the declared warm target" | The count must be observed, with its age. See Section 4.5. |

---

## 10. Items to verify

1. **Does an edit of `LoRASpec` cause a pod roll in the llmisvc reconciler?** This
   decides ADR-005. It is one afternoon of code reading. Do this item first.
2. Does `filesystem_resolver` read the cache directory at start, or at each cache
   miss? If it reads at start, adapters that you add later need a restart. This breaks
   the runtime-add requirement, through a path that the controller does not control.
3. Is the pin function present in the current cache manager? Is it truly not available
   over HTTP? ADR-003 and ADR-008 depend on this answer.
4. Does the current stable vLLM documentation still have the production caution for
   `VLLM_ALLOW_RUNTIME_LORA_UPDATING`?
5. Does `LocalModelCache` support adapters? Examine the size validation, the layout,
   and the per-node assumptions for base-model behavior. Does it now support llmisvc?
   Pull request kserve#5318 is merged, but the install documentation does not agree.
   Read `pkg/controller/v1alpha1/localmodelcache/`.
6. Do prefill and decode use one InferencePool with a role label, or two pools? This
   decides whether the P/D pair rule is a filter in one scorer, or coordination across
   two pools.
7. Is the vllm#51433 notification channel a stream that you can subscribe to? Or does
   it terminate in `/metrics`? Does a state change start the delivery, or a poll
   interval? Is it for `mrv2` only?
8. Is LoRA load and unload already atomic across an EP group, after a partial failure?
   Treat this as an investigation, not as an estimate.
9. Can the shard manager reach the pods directly, for a targeted warm-up or pin? Or
   only through the gateway? This has network policy consequences.

---

## 11. Persons to contact first

- **dmitripikus and nilig** — Issue llm-d-router#709 is accepted and assigned. Pull
  request #720 is their branch. If you work in parallel, you build two competing
  designs for one result. **Contact them first.**
- **wseaton (Red Hat)** — The engine notification channel, vllm#51433. If this is your
  organization, this is an internal discussion. It is the fastest method to make the
  LoRA eviction events correct for the controller, because the schema is not complete.
- **VedantMahabaleshwarkar** — LocalModelCache with llmisvc, kserve#5318. Ask whether
  adapters are in scope for that mechanism.
- **ahg-g and kfswain** — The GIE reviewers. They ask the benchmark question.

---

## 12. ADR index

| ADR | Decision |
|---|---|
| [ADR-001](#adr-001--the-serving-instance-is-the-unit-of-adapter-residency) | The serving instance is the unit of adapter residency |
| [ADR-002](#adr-002--the-shard-manager-is-a-background-loop-in-the-scheduler-process) | The shard manager is a background loop in the scheduler process |
| [ADR-003](#adr-003--the-controller-declares-floors-the-engine-selects-the-victims) | The controller declares floors. The engine selects the victims. |
| [ADR-004](#adr-004--the-engine-loads-adapters-on-the-resolver-miss-path) | The engine loads adapters on the resolver miss path |
| [ADR-005](#adr-005--extend-loraspec-do-not-add-an-adapterplacement-crd) | Extend `LoRASpec`. Do not add an `AdapterPlacement` CRD. |
| [ADR-006](#adr-006--read-the-placement-intent-from-an-api-with-a-schema-not-from-a-configmap) | Read the placement intent from an API with a schema |
| [ADR-007](#adr-007--weight-distribution-is-a-prerequisite-this-feature-does-not-own-it) | Weight distribution is a prerequisite |
| [ADR-008](#adr-008--the-pin-api-gives-retention-keepalive-traffic-is-temporary) | The pin API gives retention. Keepalive traffic is temporary. |
| [ADR-009](#adr-009--divide-by-loop-the-shard-manager-in-llm-d-router-the-declaration-in-kserve) | Divide by loop: shard manager in llm-d-router, declaration in KServe |
| [ADR-010](#adr-010--shard-assignment-first-declarative-targets-are-a-layer-above-it) | Shard assignment first. Declarative targets are a layer above it. |
| [ADR-011](#adr-011--use-the-engine-notification-channel-for-eviction-visibility) | Use the engine notification channel for eviction visibility |
| [ADR-012](#adr-012--in-flight-behavior-a-reference-count-admission-time-rejection-no-base-fallback) | In-flight: reference count, admission-time rejection, no base fallback |
| [ADR-013](#adr-013--frequency-weighted-eviction-cpu-tier-only-in-the-last-phase) | Frequency-weighted eviction: CPU tier only, in the last phase |
| [ADR-014](#adr-014--adapter-aware-dispatch-is-a-mandatory-prerequisite) | Adapter-aware dispatch is a mandatory prerequisite |

---

## 13. References

### vLLM

| Reference | Subject |
|---|---|
| [vllm#12174](https://github.com/vllm-project/vllm/issues/12174) | RFC on the LoRA adapter lifecycle. It names `VLLM_ALLOW_RUNTIME_LORA_UPDATING` as a development-mode method. |
| [vllm#14497](https://github.com/vllm-project/vllm/issues/14497) | Eviction of an adapter that a live batch uses |
| [vllm#14634](https://github.com/vllm-project/vllm/pull/14634) | The LoRA resolver plugin implementation |
| [vllm#45325](https://github.com/vllm-project/vllm/issues/45325) | Feature request to expose adapter cache residency as metrics |
| [vllm#45411](https://github.com/vllm-project/vllm/pull/45411) | The LoRA events parent issue |
| [vllm#45820](https://github.com/vllm-project/vllm/pull/45820) | The residency metrics implementation. Stopped. Needs rebase. |
| [vllm#51433](https://github.com/vllm-project/vllm/pull/51433) | The engine notification channel. The first part of #45411. |
| [LoRA documentation (stable)](https://docs.vllm.ai/en/stable/features/lora/) | The current LoRA documentation, with dynamic serving |
| [LoRA documentation v0.7.2](https://docs.vllm.ai/en/v0.7.2/features/lora.html) | The previous page, with the explicit production caution |
| [LoRA resolver plugin design](https://docs.vllm.ai/en/stable/design/lora_resolver_plugins/) | The resolver architecture |
| [filesystem_resolver API](https://docs.vllm.ai/en/latest/api/vllm/plugins/lora_resolvers/filesystem_resolver/) | The module reference |

### llm-d-router

| Reference | Subject |
|---|---|
| [llm-d-router#709](https://github.com/llm-d/llm-d-router/issues/709) | Dynamic LoRA placement and bounded-subset routing. Accepted and assigned. |
| [llm-d-router#720](https://github.com/llm-d/llm-d-router/pull/720) | The shuffle shard assignment scorer. Closed by the stale bot. Branch: `dmitripikus:loras-shuffle-sharding`. |

### Gateway API Inference Extension

| Reference | Subject |
|---|---|
| [GIE v1.3.0 release](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/tag/v1.3.0) | The syncer image is deprecated. The team announced the code removal. |
| [dynamic-lora-sidecar](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/main/tools/dynamic-lora-sidecar) | The deprecated syncer. The `main` branch can give a 404 error. Use a tag at v1.3.0 or earlier. |
| [Adapter rollout guide](https://gateway-api-inference-extension.sigs.k8s.io/guides/adapter-rollout/) | A full `vLLMLoRAConfig`, `ensureExist`, and `ensureNotExist` example |

### KServe

| Reference | Subject |
|---|---|
| [kserve#4126](https://github.com/kserve/kserve/issues/4126) | LocalModelCache with many node groups. The node group annotation requirement. |
| [kserve#5318](https://github.com/kserve/kserve/pull/5318) | LocalModelCache support for LLMInferenceService. Merged. |
| [kserve#5675](https://github.com/kserve/kserve/pull/5675) | The LoRA affinity scorer in the llmisvc default configuration |
| [LocalModelCache documentation](https://kserve.github.io/website/docs/model-serving/generative-inference/modelcache/localmodel) | The CRDs, the node agent DaemonSet, and how to enable them |
| [Install overview](https://kserve.github.io/website/docs/install/overview) | It says that LocalModel supports InferenceService only. This does not agree with kserve#5318. |
| [LLMInferenceService overview](https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/llmisvc-overview) | P/D separation, multi-node serving, and LoRA adapters |
