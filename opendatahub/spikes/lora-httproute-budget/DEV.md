# How this was tested

Everything in [REPORT.md](REPORT.md) and [FINDINGS.md](FINDINGS.md) came out of
this harness. This file is the runbook: what to install, what to run, in what
order, and the six or seven ways it will silently lie to you if you skip a step.

The design rule the whole thing rests on: **nothing here encodes an
expectation.** Whatever today does *is* the baseline, including the parts we
think are wrong. Those get fixed deliberately, with the diff as the record of
what moved.

---

## Prerequisites

- `kind`, `kubectl`, `helm`, `curl`, `python3` with `pyyaml`
- `node` (for the request simulator)
- `go` (only for `hack/istio-merge-race/`)
- Docker or Podman with enough headroom for kind + Istio + vLLM on CPU

Nothing touches `~/.kube/config`. `setup.sh` writes a scoped `.kubeconfig` next
to the scripts and every other script picks it up:

```bash
export KUBECONFIG="$PWD/.kubeconfig"
```

### Running kind on rootless podman

If there is no Docker daemon, kind works with podman, but rootless podman needs
`cpu` delegated to the cgroup kind runs in - and a terminal's transient scope
usually only gets `memory pids`, even when `user@$UID.service` itself has
`Delegate=yes`:

```bash
cat "/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/cgroup.controllers"
# memory pids          <- kind refuses: "requires setting systemd property Delegate=yes"
```

The message points at `user@.service`, which is a red herring when that is
already set. Run inside a scope with full delegation instead - no root, nothing
persistent:

```bash
KIND_EXPERIMENTAL_PROVIDER=podman \
  systemd-run --user --scope -p Delegate=yes ./setup.sh --with-kserve
```

Rootless podman then also needs a working `/dev/net/tun` for pasta. The device
node existing is not enough - if `open()` returns `ENODEV` ("No such device")
the driver is not actually loaded:

```bash
modinfo tun          # "Module tun not found" while zgrep CONFIG_TUN /proc/config.gz says =m
                     # -> the running kernel's modules are not installed; reboot or modprobe tun
```

---

## Cluster setup

Two modes, because the tiers need different things.

```bash
./setup.sh                 # kind + MetalLB + Gateway API + Istio + Gateway
./setup.sh --with-kserve   # the above + GIE CRDs + the kserve llmisvc controller
```

The Gateway is named `kserve/kserve-ingress-gateway` in **both** modes, so a
route captured with kserve installed still attaches on a cluster without it.
That is what lets candidate shapes be characterized by hand.

Versions come from kserve's own `kserve-deps.env` rather than being hardcoded,
because the spike's entire subject is what the installed HTTPRoute CRD allows -
testing against a Gateway API version kserve does not use would measure the
wrong thing.

| env var | default | notes |
|---|---|---|
| `CLUSTER_NAME` | `lora-budget-spike` | |
| `NS` | `lora-budget` | fixture namespace |
| `ISTIO_VERSION` | `1.30.3` | **does not** track kserve-deps.env, see below |
| `GWAPI_VERSION` | `v1.5.1` | 16 rules / 64 per rule / 128 per route |
| `GIE_VERSION` | `v1.5.0` | |
| `KSERVE_REF` | `master` | |
| `LLMISVC_IMAGE` | the ref's published image | |

**Istio must be >= 1.29.** 1.28.x installs the ext_proc filter as a placeholder
pointing at cluster `dummy` and never attaches the per-route override, so the
endpoint picker is deployed, healthy, resolved and **silently never invoked**.
Traffic round-robins instead of being scheduled and nothing reports a problem.
1.30.3 wires it correctly. (FINDINGS 6, filed as #283.)

**Kuadrant is not scripted.** The policy-detach rehearsal (FINDINGS 12) used
Kuadrant 1.5.2 installed by hand on the same kind cluster, with a hand-written
`AuthPolicy` carrying `targetRef.sectionName: v1-model-routing`. That policy is
*not* one odh-model-controller ships - both of theirs target whole objects.

### Fixtures

`manifests/fixtures.yaml`:

| | model name | notes |
|---|---|---|
| `svc-a` | `model-a` | real vLLM, adapters `adapter-a1` `adapter-a2` |
| `svc-b` | `model-b` | no adapters |
| `svc-c` | `model-c` | model-based routing **disabled** |
| `svc-ai` | | nested-name fixture |
| neighbour | | plain HTTPRoute on the same gateway, `PathPrefix /docs` and `/` |

`manifests/backends.yaml` holds the echo Deployments (`echo-pool`,
`echo-service`, `echo-neighbour`) tier 2 swaps in.

`hack/gen-tiny-lora.py` generates the tiny LoRA adapters the fixtures mount -
`tiny-random-LlamaForCausalLM` shaped, so vLLM loads them on CPU in seconds.

---

## The three tiers

They answer different questions and need different things. Run them in order the
first time; after that they are independent.

| tier | question | needs |
|---|---|---|
| 1 - shape | what HTTPRoute does the controller emit, and what is the budget arithmetic | kserve |
| 2 - behaviour | where does a given request actually land | a gateway, nothing else |
| 3 - outcome | with a real endpoint picker in the path, what actually happens | the full stack |

The trick that makes tier 2 cheap: a real route sends traffic to an
InferencePool or to the workload Service, and **both end at the same pods**, so
"which backend" is not observable. `swap-backends.sh` rewrites the captured
route's `backendRefs` to two distinct echo Deployments and leaves every rule
name, match and filter byte-for-byte alone. That drops the EPP, vLLM, LoRA
mounts and metrics scraping out of the loop and makes every probe unambiguous.

It also leaves a deliberate gap: the harness will tell you `/health` moved from
`echo-service` to `echo-pool`. It will not tell you what a real EPP does when
handed `/health`. That is tier 3, and it is why tier 3 exists.

---

## Tier 1 - shape and budget

```bash
./capture-routes.sh                             # apply fixtures, capture, report
./capture-routes.sh --shape current             # name the golden file
./capture-routes.sh --sweep 0,3,6,7,8,12,13     # find the real ceiling
```

Two jobs:

1. Freeze the generated route as `golden/route-<shape>.yaml`. That file is tier
   2's input, and a golden in its own right - a rule rename or a match-count
   change shows up here before any traffic is sent.
2. Report rules / matches-per-rule / total matches, and sweep the adapter count
   to find where the apiserver actually refuses.

`--sweep` patches `spec.model.lora.adapters` on the real CR and waits for the
controller. It does not hand-write a route. The measured ceiling is 7:

```
spec.rules[4].matches: Too many: 72: must have at most 64 items
```

### Candidate ceilings, without a controller

```bash
./probe-ceiling.sh                  # all shapes
./probe-ceiling.sh collapse         # one shape
```

Synthesises the route at rising adapter counts and asks the apiserver to
validate with `--dry-run=server` - the same CEL and `maxItems` checks the
controller trips over, minus the controller, the workload and any traffic. A
full sweep costs seconds and the answer comes from the cluster's actual CRD
rather than from arithmetic in a document.

**This is a replica, not the controller.** kserve does not implement `split`,
`alternation`, `nested` and friends, so there is nothing to ask it for. The
synthesis is checked against controller output at four adapter counts and
reproduces its arithmetic exactly (FINDINGS 20), but a real implementation could
add matches it does not model.

---

## Tier 2 - behaviour

```bash
./characterize.sh                          # run, diff against golden/current.tsv
./characterize.sh --update                 # (re)write the golden file
./characterize.sh --shape collapse         # use golden/collapse.tsv
./characterize.sh --diff current collapse  # compare two recorded shapes
```

Replays `probes.tsv` and records, per request, which backend served it and what
path that backend saw. 72 probes across 7 families:

| family | what it exercises |
|---|---|
| `header` | model routing header on every kind of path |
| `adapter` | adapter names, casing, bare vs qualified |
| `name-path` | service-scoped `/{ns}/{name}/...` |
| `pub-path` | publisher-scoped `/publishers/{ns}/models/{model}/...` |
| `nested` | nested served names and near-miss anchoring |
| `cross` | neighbour tenant on the same gateway |
| `disabled` | the service with model-based routing off |

### Deriving a candidate shape

```bash
./make-shape.py split-noslash > manifests/route-split-noslash.yaml
kubectl apply -f manifests/route-split-noslash.yaml
./characterize.sh --shape split-noslash --update
```

Every shape is derived from `golden/route-current.yaml` rather than
hand-written, so the only thing differing between two tables is the
transformation under test. Backends are swapped the same way `swap-backends.sh`
does it, so the output applies directly.

Shapes: `baseline` (no-op), `split`, `split-noslash`, `prefix`, `split-prefix`,
`alternation`, `nested`, `collapse`, `collapse-dedup`. Add `--real` to keep the
original backendRefs (needed for tier 3).

### Re-recording everything

```bash
./rebaseline.sh                    # every shape
./rebaseline.sh prefix collapse    # just these
```

Adding a probe invalidates every golden file at once - the tables are only
comparable if every shape answered the same questions. This applies each shape's
route in turn and re-records the set together.

**Adding probes is how this harness earns its keep.** The first run had 57
probes and `prefix` looked like the better trade at 2 moved. Six more probes for
`/v1/responses/{id}/cancel`, `/input_items`, `/v1/messages/batches{,/id}` and
arbitrary depth took it to 8 moved and reversed the recommendation. The
reasoning behind the wrong call was sound; it ran on an incomplete probe set.
**Treat the probe set as the deliverable, not any individual verdict.**

---

## Tier 3 - outcome, with a real EPP

```bash
./probe-epp.sh current      # today's shape: these paths reach the Service
./probe-epp.sh collapse     # after the collapse: they reach the pool
./probe-epp.sh --diff       # compare the two recorded runs
```

Keeps the routes' **real** backendRefs, so a request goes
gateway -> InferencePool -> EPP -> runtime, and records status codes rather than
destinations. 13 probes: the set the collapse moves, plus controls.

The collapse moves 20 destinations and changes **2 outcomes**, both of which
were already 404. That is the number that makes "moved" a signal to look rather
than a cost.

### What the runtime says it is serving

```bash
./probe-model-list.sh              # part A: what /v1/models actually lists
./probe-model-list.sh --churn      # + add/remove via spec.model.lora
./probe-model-list.sh --runtime    # + vLLM /v1/load_lora_adapter
./probe-model-list.sh --all
```

The route and the vLLM runtime are two independent registries of the same
adapter set, and nothing reconciles them. Part A records both and compares them;
parts B and C move each one independently to see what the other does.

Two things to know before reading the output:

- **kserve registers every adapter twice** (`workload_lora.go:166-167`) - the
  bare name and the fully qualified one - so `/v1/models` reports `2N + 1`
  entries for N adapters. Corroborated by `golden/authz-split.tsv`, where both
  `adapter-a2` and `publishers/lora-budget/models/adapter-a2` are accepted as
  `body.model` and each is echoed back verbatim. The base model is not
  symmetric: the qualified form is an alias that reports back as `model-a`.
- **Part C needs `VLLM_ALLOW_RUNTIME_LORA_UPDATING=1`,** which the fixture
  deliberately does not set. vLLM only registers `/v1/load_lora_adapter` and
  `/v1/unload_lora_adapter` when it is, so turning it on adds two operations to
  `/openapi.json` - the inventory `golden/endpoint-budget.tsv` is derived from.
  The script detects their absence and prints the `kubectl set env` line rather
  than reporting a 404 as a finding.

### The authorization split

```bash
./probe-authz-split.sh      # -> golden/authz-split.tsv
```

12 probes measuring what the gateway *authorizes* against what vLLM *serves*.
The AuthPolicy derives its SubjectAccessReview name from `request.path`; vLLM
applies the adapter from `body.model`; nothing compares them.

Needs the real backends. It detects fall-through to the echo neighbour
explicitly and aborts rather than reporting a bogus result, because a route that
does not exist looks exactly like a route that matched everything.

---

## Data plane portability

```bash
./probe-dataplane.sh install   # kgateway + Envoy Gateway beside Istio
./probe-dataplane.sh probe     # replay the anchoring probes on all three
./probe-dataplane.sh both      # default
```

Installs separate GatewayClasses and Gateways in the same cluster and checks, in
order of how much it would hurt to be wrong:

1. header regex anchoring - full match or partial?
2. alternation ceiling - does 4096 bytes still apply, does it program?
3. nested prefix anchoring - does `model-a(/.*)?` capture `model-a-instruct`?
4. RE2 program size - is 32768 an Istio setting or an Envoy one?

Semantics agree 11/11 on all three. The ceiling does not: kgateway leaves
`re2.max_program_size.error_level` at Envoy's default of 100.

Two install-time gotchas, both hard-won:

- **`v1alpha2` on the TLSRoute CRD.** Gateway API v1.5.1's standard channel
  disables it and `probe-dataplane.sh install` needs it. The script's notes
  cover the workaround.
- **Stale informers.** Installing a controller that brings new CRD groups
  (Envoy Gateway adds `gateway.networking.x-k8s.io`) leaves already-running
  controllers with stale informers. kgateway silently stops attaching routes -
  `status.parents` goes empty with nothing logged - and istiod did the same.
  Restart the others after adding one:
  `kubectl -n kgateway-system rollout restart deploy/kgateway`

InferencePool on Envoy Gateway needs the **Envoy AI Gateway addon**; plain Envoy
Gateway rejects the backendRef kind outright.

---

## Latency, and why it is here anyway

```bash
./probe-latency.sh [reps] [duration]      # default 3 10s
./probe-regex-cost.sh [reps] [duration]   # default 5 8s
```

`probe-latency.sh` is **too noisy to conclude from** and is kept because the
failure is instructive. It measures configurations round-robin rather than one
after another, so a laptop thermal-throttling halfway through shows up as noise
in every column instead of a trend in one - and it still cannot resolve the
effect.

`probe-regex-cost.sh` amplifies instead. `hack/render-regex-cost.py` renders a
route that forces a *known* number of header evaluations before reaching the
terminal rule, so the only difference between two columns is the work in
between. Two de-noising choices:

- each rep **rotates** the configuration order by one. A fixed order looks like
  interleaving but is not - warm-up and thermal drift alias straight onto
  configuration position. With as many reps as configurations, every one
  occupies every position exactly once.
- take the **minimum** p50 across reps, not the median. Interference can only
  add time, so the fastest observation is closest to the real cost. A median
  reports how busy the laptop was.

Answer: one header-regex evaluation costs under 0.145 us. That is enough to rule
the regex out as a request-time concern and is not a throughput model for a real
cluster.

---

## Offline calculators

No cluster needed. These are arithmetic on the pattern string or the budget, and
each is cross-checked against something measured.

| script | answers |
|---|---|
| `hack/alternation-ceiling.py` | how many adapters fit in one alternation, by name length and escaping form |
| `hack/endpoint-budget.py` | how the ceiling moves when you add API endpoints; also `shard_capacity()` |
| `hack/regex-forms.py` | what each way of writing the pattern buys, checked against the measured 297 |
| `hack/diff-shapes.py` | what adding ONE adapter looks like to a reviewer |
| `hack/render-scale-route.py` | full-size alternation per data plane and naming profile (`realistic`, `longns`) |
| `hack/render-adapter-paths.py` | if adapters ever got a publisher path, does the PATH axis hit a ceiling too? |
| `hack/render-anchoring-route.py` | one route, two data planes, identical patterns |
| `hack/render-latency-route.py` | latency-probe route for one (shape, adapters) pair |

`diff-shapes.py` is the one that answers a question no ceiling table does: an
HTTPRoute is a thing people review in a pull request, `kubectl diff` before
applying, and grep when routing does not work.

---

## The request simulator

```bash
python3 hack/request-sim/extract.py     # writes routes.json
node hack/request-sim/validate.js       # 360/360 plus the live invariants
node hack/request-sim/smoke.js          # preset x shape table
```

The report's *Try a request* section **computes** Gateway API matching in the
browser rather than replaying a lookup table, so it can answer an arbitrary path
and header.

- `extract.py` pulls each shape's rules out of `make-shape.py` - the same
  synthesis every golden file came from - so the simulator cannot drift. It
  includes the neighbour route, because "falls through" is one of the outcomes.
- `matcher.js` implements the precedence: path type
  (`Exact` > `RegularExpression` > `PathPrefix`), then characters in the
  matching path, then header match count, then route key, rule order, match
  order. Same file in node and in the page.
- `validate.js` replays all 72 probes on all 5 shapes - **360 of 360** match
  `golden/*.tsv`, first pass, no tuning - plus three invariants measured
  separately on the live cluster by `probe-authz-split.sh`.

The claim is only that it reproduces the recorded set. It models one gateway
with five routes, no hostname / method / query-param matching beyond what those
routes use, and no creation-timestamp tie-break.

---

## The istiod reproducer

```bash
cd hack/istio-merge-race
go test -run TestAliasingEscapes ./...        # deterministic, no -race needed
go test -race -run TestConcurrentMerge ./...  # reports the data race
```

Standalone reduction of `route_collections.go:825-880` at istio 1.30.3. The
first test fails without concurrency at all - the merged result shares a map
with its input. The second reports `WARNING: DATA RACE` on the line
corresponding to `route_collections.go:868`.

Hit live during this spike when istiod crash-looped merging InferencePool and
plain HTTPRoutes on one gateway. Normal LoRA adapter management does *not*
trigger it: one route write per add or remove, zero at rest. FINDINGS 27, filed
as #285.

---

## Gotchas that cost real time

Every one of these silently produced wrong numbers before it was understood.

- **Scale the llmisvc controller to 0 before tier 2.**
  `kubectl scale deploy/llmisvc-controller-manager -n kserve --replicas=0`.
  Otherwise it recreates the originals and they compete with the
  `-characterize` copies for the same matches. `rebaseline.sh` does this, and
  also **deletes** the originals - scaling alone is not enough.
- **Wait on a request, not a sleep.** Swapping between shapes that do and do not
  reference an InferencePool makes Istio rebuild the listener filter chain;
  until that lands, POSTs hit a stale ext_proc cluster and 500. Two full runs
  were silently corrupted before `rebaseline.sh` grew a canary wait.
- **One LLMISVC at a time for EPP work.** Istio keys its inference-pool ext_proc
  map by bare rule name and kserve names every service's rules identically, so
  with 2+ services on a gateway the EPP overrides cross-wire and requests are
  scheduled by another service's picker. 17 of 26 routes affected in the
  fixture. (FINDINGS 7, filed as #282.)
- **The endpoint picker needs a DestinationRule**, or everything 500s while
  looking healthy. (FINDINGS 13.)
- **Do not read numbers off a degraded control plane.** kgateway once sat there
  spamming watch errors, not writing route status, LB `<pending>`; a restart
  produced a 0/1 pod. The right move was to roll back and re-measure, not to
  record what the broken cluster said.

---

## What is real and what is a replica

Worth knowing before quoting a number out of this repo.

**Real, from the controller:** the baseline route and the 7-adapter ceiling.
`capture-routes.sh --sweep` patches the CR and waits for kserve.

**Real, from the gateway:** every tier 2 table (captured route, backends
swapped), every tier 3 outcome (real InferencePool, EPP and vLLM), the shard
probe, the `/v1`-consolidation probe, the anchoring probes on three data planes.

**Synthesised:** the candidate ceilings (`split`, `alternation`, `nested`, ...),
because kserve does not implement those shapes. Checked against controller
output at four adapter counts, reproduces its arithmetic exactly, still a
skeleton.

**Hand-built on purpose:** everything in `probe-latency.sh`,
`probe-regex-cost.sh` and `probe-dataplane.sh`. Those measure Envoy, not kserve.

**Read, not run:** the ODH authorization analysis and the MaaS policy survey.
Source-reading, stated as such in REPORT.md.

---

## Golden files

| file | produced by |
|---|---|
| `route-current.yaml` | `capture-routes.sh` |
| `current.tsv`, `split*.tsv`, `prefix.tsv`, `nested.tsv`, `collapse*.tsv`, `alternation.tsv` | `characterize.sh` / `rebaseline.sh` (one per recorded shape) |
| `epp-current.tsv`, `epp-collapse.tsv`, `epp-alternation.tsv` | `probe-epp.sh` |
| `epp-dataplane.tsv` | kserve's route copied onto the Envoy Gateway, parentRef only, real InferencePool |
| `authz-split.tsv` | `probe-authz-split.sh` |
| `dataplane.tsv` | `probe-dataplane.sh` (anchoring semantics, 3 planes) |
| `dataplane-ceiling.tsv`, `realistic-names.tsv` | `probe-ceiling.sh` + `hack/alternation-ceiling.py` |
| `latency.tsv`, `regex-cost.tsv` | `probe-latency.sh`, `probe-regex-cost.sh` |
| `endpoint-budget.tsv` | live vLLM `/openapi.json` + `hack/endpoint-budget.py` |
| `shard.tsv` | `manifests/shard-probe.yaml` + envoy `config_dump` |
| `adapter-paths.tsv`, `addressing.tsv`, `model-rewrite.tsv`, `route-churn.tsv`, `routing-disabled.tsv` | the corresponding `hack/render-*.py` |

Most carry a header comment explaining what they measure and what supersedes
what. `realistic-names.tsv` in particular supersedes an earlier version that
quoted 188 with no derivation.

---

## Report

`report.html` is generated. Its fragment sources and `assemble.py` live outside
the repo (session scratchpad); what *is* committed is `hack/request-sim/`, which
`assemble.py` runs - `extract.py` then `validate.js` - before writing the page,
so a matcher that disagrees with a golden file fails the build rather than
shipping. The published version also validates section ids, table column counts,
anchors and the absence of em-dashes.

If you need to regenerate it from scratch, the markdown source of truth is
[REPORT.md](REPORT.md) plus [FINDINGS.md](FINDINGS.md).
