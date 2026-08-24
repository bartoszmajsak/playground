# LoRA HTTPRoute budget spike

Put eight LoRA adapters on one `LLMInferenceService` and the generated
HTTPRoute stops applying. Not with a validation error, not with a condition -
with a raw CEL rejection from the apiserver, late in reconcile, phrased in
terms of `spec.rules[4].matches`. It works in dev with three adapters and
breaks in production with eight.

> **Three documents, three jobs.** [REPORT.md](REPORT.md) is the decision - the
> options, what each measured, and what to do. [DEV.md](DEV.md) is the runbook -
> how to stand the cluster up and re-run every number. [FINDINGS.md](FINDINGS.md)
> is the evidence, section by section. This README is the design of the harness
> and why it is shaped the way it is.

The arithmetic, straight off `config-llm-router-route.yaml` and
`expandLoRAAdapterMatches`:

```
v1-model-routing matches           = 8 x (1 + A)     <- binding
v1-catch-all-model-routing matches = 1 x (1 + A)
route total                        = 9A + 19
```

Gateway API allows 16 rules, **64 matches per rule**, 128 matches per route.
At `A=7` that middle rule sits at exactly 64. At `A=8` it wants 72 and the
apiserver says no. Seven adapters, and nothing anywhere counts them.

Fixing it means changing the route shape, and the route shape is load-bearing
in ways that are not obvious from reading it - `odh-model-controller` derives
per-model authorization from the URL path, Kuadrant policies attach to rule
names, and the header-only catch-all captures traffic nobody addressed to a
model. So before changing anything: pin down what it does today.

That is what this spike is. Not a fix - a net.

## What is under test

Two tiers to start with, because they answer different questions and need
different things. A third was added later -- see "Three tiers, not two".

**Tier 1 - shape.** What HTTPRoute does the controller emit, and what is the
budget arithmetic behind it. Needs kserve. Produces `golden/route-*.yaml`,
which is both a golden file in its own right and tier 2's input.

**Tier 2 - behaviour.** Where does a given request actually land.
`(path x header) -> (status, backend, received path)`, frozen in
`golden/*.tsv`. Needs a gateway and nothing else.

The trick that makes tier 2 cheap: a real route sends traffic to an
InferencePool or to the workload Service, and **both end at the same pods**,
so "which backend" is not observable. `swap-backends.sh` rewrites the captured
route's `backendRefs` to two distinct echo Deployments and leaves every rule
name, match and filter byte-for-byte alone. That drops the EPP, vLLM, LoRA
mounts and metrics scraping out of the loop, makes every probe unambiguous,
and lets the same 72 probes run against a hand-written candidate shape with no
controller anywhere.

It also leaves a deliberate gap. The harness will tell you `/health` moved
from `echo-service` to `echo-pool`. It will not tell you what a real EPP does
when handed `/health`. That is a separate probe set, and the collapse is what
makes it matter.

## Running it

```bash
# tier 2 only - kind + MetalLB + Gateway API + Istio + Gateway + echo backends
./setup.sh

# tier 1 as well - adds GIE CRDs and the kserve llmisvc controller
./setup.sh --with-kserve
```

Capture the shape and measure the real ceiling:

```bash
./capture-routes.sh --sweep 0,3,6,7,8,12,13
```

That applies the fixtures, walks svc-a's adapter count, and prints
matches-per-rule and route totals at each step alongside whatever the
controller says. The limits it judges against are read off the **installed**
HTTPRoute CRD, not off a constant - older Gateway API CRDs cap matches at 8
per rule, and a check against vendored numbers passes at 40 while the
apiserver still refuses.

Then freeze the behaviour:

```bash
./swap-backends.sh golden/route-current.yaml | kubectl apply -f -
./characterize.sh --update          # writes golden/current.tsv
```

From then on `./characterize.sh` re-runs the matrix and diffs. A shape change
shows up as a line-by-line diff of where traffic moved.

To characterize a candidate shape, hand-write the route, apply it, and record
it under a different name:

```bash
kubectl apply -f manifests/route-collapse.yaml
./characterize.sh --shape collapse --update
./characterize.sh --diff current collapse
```

## The probes that matter

`probes.tsv` has 72 across seven families. The ones worth knowing about:

| probe | what it pins |
|---|---|
| `header POST /v1/embeddings` | goes to the workload Service today. Collapsing the header rule moves it to the pool. The single most important line in the file. |
| `header GET /v1/models`, `/health`, `/metrics` | same class - runtime endpoints that would end up behind a scheduler |
| `header GET /` | `v1-catch-all-model-routing` has no path match, so a model header captures the root **today** |
| `header POST /anything/at/all` | how far that reaches |
| `cross GET /docs` + model header | does path precedence protect a neighbour tenant (longer prefix wins) |
| `cross GET /` + model header | it does not when the neighbour is at `/` - ties on path, loses on header count |
| `name-path POST /v1/completions-extra` | PathPrefix is segment-based, so this must fall to the catch-all |
| `header POST /v1/messages/count_tokens` | header family is Exact, path family is Prefix. Same request, different answer depending on how it was addressed. |
| `adapter POST` with bare `adapter-a1` | vLLM serves that name, the route does not match it |
| `adapter POST` with a nested name | today's flat scheme rejects it, so a nesting change is visible the moment it lands |
| `disabled` family | `stripModelBasedRoutingRules` - header rules gone entirely, adapter count irrelevant |
| `nested` family | prefix anchoring: `.../model-a(/.*)?` must not capture `model-a-instruct`, and the same probes pin `alternation`'s exact-name matching |

Nothing in there asserts an expectation. The root capture at `/` is almost
certainly not intended, but it goes into the baseline as-is. Then it gets
fixed deliberately, with the diff as the record of what moved.

## Layout

```
FINDINGS.md             what this turned up -- read this first
probes.tsv              the matrix - 72 probes, 7 families
characterize.sh         tier 2: replay, record, diff
capture-routes.sh       tier 1: shape + budget + adapter sweep
make-shape.py           derive a candidate shape from the captured baseline
probe-ceiling.sh        tier 1b: real adapter ceiling per shape (dry-run apply)
probe-epp.sh            tier 3: outcomes with a real EPP in the path
rebaseline.sh           re-record every shape when the probe set changes
swap-backends.sh        pure transform, backendRefs -> observable echoes
setup.sh                kind + Istio (+ kserve with --with-kserve)
hack/gen-tiny-lora.py   generates the tiny LoRA adapters the fixtures use
manifests/backends.yaml echo-pool, echo-service, echo-neighbour, neighbour route
manifests/fixtures.yaml svc-a (real vLLM, 2 adapters), svc-b, svc-c, svc-ai
golden/                 frozen shapes, behaviour tables, EPP outcome tables
```

## Three tiers, not two

The design section below describes tiers 1 and 2. A third was added once the
first EPP result turned out to be measuring nothing:

**Tier 3 - outcome.** `probe-epp.sh` keeps the routes' **real** backendRefs, so
a request goes gateway -> InferencePool -> EPP -> runtime, and records status
codes rather than destinations. Tier 2 deliberately swaps the EPP out; tier 3
exists because "which backend" and "what actually happens" turned out to be very
different questions. The collapse moves 20 destinations and changes 2 outcomes.

## What is real and what is a replica

Worth knowing before quoting a number out of this repo.

The **baseline route** and the **7-adapter ceiling** come from the real kserve
controller reconciling the real `LLMInferenceService` CRs in
`manifests/fixtures.yaml` - `capture-routes.sh --sweep` patches
`spec.model.lora.adapters` and waits for the controller, it does not hand-write a
route. Tier 2 replays probes against that captured route with backends swapped so
the destination is observable; tier 3 puts a real InferencePool, EPP and vLLM back
in the path.

The **candidate ceilings** (`split`, `alternation`, `nested`, ...) are synthesised
by `probe-ceiling.sh`, because kserve does not implement those shapes and there is
nothing to ask it for. The synthesis is checked against controller output at four
adapter counts and reproduces its arithmetic exactly - see FINDINGS section 20 -
but it is still a skeleton, and a real implementation could add matches it does not
model.

Everything in `probe-latency.sh`, `probe-regex-cost.sh` and `probe-dataplane.sh`
is hand-built against echo backends on purpose: those measure Envoy, not kserve.

## Scripts

| script | answers |
|---|---|
| `characterize.sh` | where do 72 real requests land under this shape? |
| `probe-ceiling.sh` | how many adapters before the apiserver refuses? |
| `probe-epp.sh` | with a real endpoint picker in the path, what actually changes? |
| `probe-latency.sh` | throughput per shape. **Too noisy to conclude from** - kept because the failure is instructive |
| `probe-regex-cost.sh` | what does ONE header-regex evaluation cost? (answer: under 0.145 us, i.e. nothing) |
| `hack/diff-shapes.py` | what does adding ONE adapter look like to a reviewer? (no cluster needed) |
| `probe-dataplane.sh` | do the regex findings hold on kgateway and Envoy AI Gateway as well as Istio? (semantics: yes, 11/11 all three. ceiling: no, kgateway alone) |
| `hack/render-adapter-paths.py` | if adapters ever got a publisher path, does the PATH axis hit a ceiling too? |
| `hack/render-scale-route.py` | full-size alternation per data plane and naming profile (`realistic`, `longns`) |

The short version is in FINDINGS section 23: the **body** tells vLLM which adapter
to apply, the **header** tells the gateway which vLLM, and on the shared
`/v1/...` endpoint the header is the only routing key there is. The per-adapter
matches are an index from model name to InferencePool, which is why the ceiling
exists and why `nested` - where the name already identifies the owning pool - is
the only shape that does not need one.


`probe-dataplane.sh install` needs `v1alpha2` served on the TLSRoute CRD, which
Gateway API v1.5.1's standard channel disables; the script's notes cover it.
Installing a controller that brings new CRD groups also leaves already-running
controllers with stale informers - after adding Envoy Gateway, kgateway and then
istiod both silently stopped attaching routes until restarted. And istiod 1.30.3
crash-loops when merging InferencePool and plain HTTPRoutes on one gateway - root
cause and a standalone reproducer in `hack/istio-merge-race/`, written up in
FINDINGS 27, filed as
[#285](https://github.com/bartoszmajsak/work-items/issues/285). InferencePool on Envoy Gateway needs the **Envoy AI Gateway addon** -
plain Envoy Gateway rejects the backendRef kind outright.

## The shapes

`make-shape.py <shape>` derives each candidate from the captured baseline, so the
only thing differing between two tables is the transformation under test:

| shape | maxA | probes moved | what it does |
|---|---|---|---|
| `split` | 12 | 0 | reverts kserve#5826 - same matches, four rules |
| `prefix` | 15 | 8 | `Exact` -> `PathPrefix`, dropping the trailing-slash twins |
| `split-noslash` | 22 | 1 | both of the above |
| `split-prefix` | 22 | 8 | both, with PathPrefix |
| `alternation` | **188** istio / **2** stock Envoy | **0** | one regex over the existing names. Ceiling is name-length driven and the 320 quoted elsewhere assumes the fixture's short names: see FINDINGS 25 |
| `nested` | unbounded | 7 | adapters served beneath the base; one prefix regex |
| `collapse` | 58 | 20 | header-only rule, no path match |
| `collapse-dedup` | 63 | 20 | collapse, plus deleting the catch-all it makes dead |

Add `--real` to keep the original backendRefs (InferencePool / workload Service)
instead of swapping in the echo Deployments - needed for tier 3.

## Requirements worth knowing before you run it

- **Istio >= 1.29.** 1.28.x installs the ext_proc filter as a placeholder and
  never attaches the per-route override, so the endpoint picker is deployed,
  healthy, resolved and silently never invoked -- traffic round-robins instead
  of being scheduled, and nothing reports a problem. `setup.sh` pins 1.30.3.
  (FINDINGS.md 6)
- **One LLMISVC at a time for EPP work.** Istio keys its inference-pool ext_proc
  map by bare rule name and kserve names every service's rules identically, so
  with 2+ services on a gateway the EPP overrides cross-wire and requests are
  scheduled by another service's picker. (FINDINGS.md 7)
- **Scale the controller to 0 before tier 2**, or it recreates the originals and
  they compete with the `-characterize` copies. `rebaseline.sh` does this, and
  also deletes the originals -- scaling alone is not enough.
- **Wait on a request, not a sleep.** Swapping between shapes that do and do not
  reference an InferencePool makes Istio rebuild the listener filter chain; until
  that lands, POSTs hit a stale ext_proc cluster and 500. Two full runs were
  silently corrupted by this before `rebaseline.sh` grew a canary wait.

## What the first run found

Cluster: kind + Istio 1.28.1, Gateway API CRD **v1.5.1** (16 rules / 64 matches per
rule / 128 per route, read off the installed CRD), kserve `master`.

**The ceiling is exactly 7, and the arithmetic in the docs is right.**

| A | max matches/rule | route total | result |
|---|---|---|---|
| 0 (svc-b, no `lora` at all) | 8 | 19 | applied |
| 3 | 32 | 46 | applied |
| 6 | 56 | 73 | applied |
| 7 | **64** | 82 | applied, at the cap |
| 8 | - | - | **rejected** |

Verbatim, from `HTTPRoutesReady`:

```
spec.rules[4].matches: Too many: 72: must have at most 64 items
```

`stripModelBasedRoutingRules` also checks out: svc-c with model-based routing off
generates 10 rules / 10 matches and no header rules at all, so adapter count is
irrelevant in that mode. The per-service `spec.annotations` value does override the
preset's `"true"` - that was an open question when the fixtures were written.

**The failure is a silent no-op, not an outage.** The rejection happens inside a
*dry-run defaulting* call, before the real apply, so the previously applied route
keeps serving. Existing adapters keep working, the new one is simply invisible, and
the only signal is a condition on the CR. A service can sit like that indefinitely.

**New bug: removing adapters never shrinks the route.** Clear `spec.model.lora`
entirely and the HTTPRoute keeps **18 matches naming adapters that no longer exist**,
with `HTTPRoutesReady=True` and `observedGeneration` caught up. Adding works fine
(A=4 regenerates to exactly 40), so it is remove-only. Two consequences: the gateway
keeps routing for adapters the runtime no longer serves, and **the match budget is
sticky** - a service that once had 7 adapters carries that cost after dropping to 3.

**The unscoped header capture is real, and wider than `/`.** `v1-catch-all-model-routing`
has no path match, so *any* path carrying a valid model header reaches that service's
workload Service. Observed against a neighbour tenant on the same gateway:

| request | header | lands on |
|---|---|---|
| `GET /docs` | `publishers/…/model-a` | neighbour (longer prefix wins) |
| `GET /` | `publishers/…/model-b` | **svc-b's workload Service** |
| `GET /some/neighbour/page` | `publishers/…/model-a` | **svc-a's workload Service** |
| `POST /anything/at/all` | `publishers/…/model-a` | **svc-a's workload Service** |

Path precedence only protects a neighbour whose prefix is longer than `/`. This is
today's shipped behaviour, not something the collapse introduces - but the collapse
moves the destination from the workload Service to the InferencePool, which is the
part worth arguing about.

**Everything else behaved as the docs predicted.** Exact-vs-Prefix asymmetry
(`/v1/messages/count_tokens` reaches the pool path-addressed, the Service
header-addressed); PathPrefix is segment-based so `/v1/completions-extra` and
`svc-abc` both fall through correctly; header values are case-sensitive; bare
adapter names and nested names match nothing.

Baselines are in `golden/current.tsv` (behaviour) and `golden/route-current.yaml`
(shape).

> **Running tier 2:** scale the llmisvc controller to 0 first
> (`kubectl scale deploy/llmisvc-controller-manager -n kserve --replicas=0`).
> Otherwise it recreates the original routes and they compete with the
> `-characterize` copies for the same matches.

## Candidate shapes, measured

`make-shape.py` derives each candidate from the captured baseline, so the only
thing differing between them is the one transformation under test.
`probe-ceiling.sh` then finds each shape's real adapter ceiling by synthesising
the route at rising adapter counts and asking the apiserver to validate it with
`--dry-run=server` - the same CEL and `maxItems` checks the controller trips
over, minus the controller, the workload and any traffic.

| shape | maxA | binding limit | probes moved | what it changes |
|---|---|---|---|---|
| `current` | **7** | `rules[4].matches: Too many: 72 > 64` | - | - |
| `split` | **12** | route-wide 128 | **0** | revert #5826 |
| `prefix` | **15** | per-rule 64 | 8 | `Exact` -> `PathPrefix` |
| `split-noslash` | **22** | route-wide 128 | **1** | revert #5826 + drop the twins |
| `split-prefix` | **22** | route-wide 128 | 8 | revert #5826 + `PathPrefix` |
| `collapse` | **58** | route-wide 128 | 20 | header-only rule |
| `collapse-dedup` | **63** | per-rule 64 | 20 | + drop the dead catch-all |
| **`alternation`** | **297** | 4096-byte header value | **0** | one regex lists the existing names |
| `nested` | **unbounded** | nothing in the route | 7 | adapters served beneath the base |

Predictions were written down before each run. Every one held on the probe set
that existed at the time - which turned out to be the important caveat, see
"the probe set moved the answer" below.

**`split` is free.** Break `v1-model-routing` into one rule per endpoint, keeping
the trailing-slash variants together. Matches are OR'd and every slice shares one
backendRef with no filters, so it is semantically inert - and the behaviour table
is byte-identical across all 72 probes. 7 → 12 adapters, zero behaviour change,
no new destination for any request. Costs 3 rules (12 → 15 of 16).

**`split-noslash` moves exactly one probe:** header-addressed `/v1/completions/`
stops reaching the pool and falls through to the workload Service. 7 → 22.

**`collapse` moves 13**, all in the same direction - from the workload Service to
the InferencePool:

```
header  /v1/messages/count_tokens     header  /score
header  /v1/responses/{id}            header  /v2/rerank
header  /v1/embeddings                header  /
header  /v1/models                    header  /anything/at/all
header  /health                       adapter /v1/embeddings
header  /metrics                      cross   /  and  /some/neighbour/page
```

That list is the price of the collapse, and it is worth reading as URLs rather
than as a paragraph: `/health` and `/metrics` start going through a scheduler.

**`collapse-dedup` is identical to `collapse` in behaviour** - verified, empty
diff. Once `v1-model-routing` is header-only its match set is identical to
`v1-catch-all-model-routing`'s, and it sits earlier, so the catch-all is dead
code. Deleting it is free and buys 58 → 63.

### Why the trailing-slash twins exist

Only because the header rules use `Exact`. `PathPrefix /v1/completions` already
matches `/v1/completions`, `/v1/completions/` and everything below it; `Exact`
matches one literal string, so it needs a twin. The path family has used
`PathPrefix` since the start and never needed one.

Nothing documents the choice - #5521's body doesn't mention it and the template
comment only justifies the absence of a *rewrite* ("the path is already the
target path"), which is a separate point.

Two ways to remove the twins, and they are not equivalent:

- **drop them, keep `Exact`** (`split-noslash`) - 1 probe moves: header-addressed
  `/v1/completions/` stops reaching the pool.
- **switch to `PathPrefix`** (`split-prefix`) - 8 probes move, because
  `PathPrefix` also picks up everything *below* each endpoint.

Both land on the same ceiling of 22.

### The probe set moved the answer

The first probe set had one Responses sub-resource probe. On it, `prefix` moved
2 probes and looked like the better trade - it fixed an addressing asymmetry
(`/v1/messages/count_tokens` reaches the pool path-addressed and the Service
header-addressed) at a cost of one extra moved probe over `split-noslash`.

Adding probes for `/v1/responses/{id}/cancel`, `/input_items`,
`/v1/messages/batches{,/id}` and arbitrary depth under a pool endpoint took
`prefix` from 2 moved to **8**, and only one of the eight is desirable:

| moved to pool under `PathPrefix` | carries a model? |
|---|---|
| `POST /v1/messages/count_tokens` | **yes** - the asymmetry fix |
| `GET /v1/responses/{id}` | no |
| `POST /v1/responses/{id}/cancel` | no |
| `GET /v1/responses/{id}/input_items` | no |
| `POST /v1/messages/batches` | nested only, no top-level `model` |
| `GET /v1/messages/batches/{id}` | no |
| `POST /v1/completions/anything` | nothing serves this |
| `POST /v1/chat/completions/deep/path` | nothing serves this |

Five of those are model-less stateful sub-resources. They only reach the pool if
a client sets the routing header by hand - a bodyless request gives any producer
nothing to read - but when they do, the EPP answers **400 `model not found in
request body`** (`director.go:246`, which has no bodyless guard). Today they
reach the workload Service and work.

**So `split-noslash` dominates `split-prefix`**: identical ceiling of 22, one
moved probe instead of eight. `PathPrefix` only earns its extra seven if closing
the `count_tokens` asymmetry is worth breaking header-addressed Responses - and
that is a product decision, not a budget one.

The segment boundary does hold under `PathPrefix`: `/v1/completions-extra` stays
on the Service, with and without a header.

This is the main argument for the harness. The reasoning that produced the wrong
recommendation was sound; it was working from an incomplete probe set, and only
adding probes exposed it.

### `split` is a revert of #5826

The rationale for both catch-all rules is on record - in the PR bodies, not the
commit messages, which are bare sign-offs.

**#5087** (Feb 2026), which created the split between pool and Service:

> This ensures only completion endpoints are routed through the InferencePool
> for intelligent load balancing, while other traffic (health checks, model
> info, etc.) goes directly to the Service.

So `/health` and `/v1/models` reaching the Service is a deliberate design
decision, not an accident of the template. That is exactly what the collapse
undoes.

**#5826** (Jul 2026) then consolidated the four per-endpoint model-routing rules
into one:

> All four shared identical backendRefs, timeouts, and carried no filters,
> making them semantically equivalent to a single rule with ORed matches. This
> consolidation frees three rule slots under Gateway API's `MaxItems=16` ceiling.

The reasoning is sound and the change is behaviour-neutral - the same argument
this spike ran backwards to justify `split`. But it traded the wrong resource.
Rule slots were not scarce (12 of 16 used, and 15 before); *matches* were. The
pre-#5826 template is 15 rules with 4 model-routing rules of 2 matches each,
19 total at A=0 - structurally identical to the `split` shape measured above:

| | rules | model-routing layout | maxA |
|---|---|---|---|
| pre-#5826 (== `split`) | 15 | 4 rules x 2 matches | **12** |
| post-#5826 (`current`) | 12 | 1 rule x 8 matches | **7** |

**#5826 lowered the LoRA adapter ceiling from 12 to 7** to free three rule slots
that were not under pressure. Reverting it is a known-good prior state, and this
spike measured it as behaviour-identical across all 72 probes.

### Correction to the design docs

`llmisvc-httproute-budget.md` §5 and the phased plan both put the header-only
collapse at **~122 adapters**. Measured, it is **63**, and the binding limit is
the per-rule 64 cap, not the route-wide 128 - the table conflated the two. The
`1 + A` formula is right; the ceiling drawn from it is not.

Getting past 63 needs the Phase 3 T1 mitigation (split `H`'s matches across
`H-0`, `H-1`, …) on top of the collapse, at which point the route-wide 128 binds
at roughly 117. So "collapse gets you past 100" is only true with the
match-splitter the plan defers to a trigger.

## Notes from reading the code

Three things worth carrying, verified against `kserve/main` @ `2f2afd58`:

**Model-based routing is on by default.** `kserve-config-llm-template` is a
well-known preset auto-attached in `combineBaseRefsConfig`, and it sets
`serving.kserve.io/model-based-routing-enabled: "true"`. So the expansion runs
on any standard service, and the ceiling is live rather than opt-in. Turn it
off and `stripModelBasedRoutingRules` drops both header rules - 10 rules, 10
matches, adapter count irrelevant.

**Nothing ships a producer for the header the rules match on.** No BBR in
kserve, no mention of `X-Gateway-Model-Name` anywhere in
`odh-model-controller`. So we generate 9 matches per adapter, and wall at 7,
for a header something else has to bring.

**`MaxAdapters` documents a default it does not have.** The godoc on
`LoRASpec.MaxAdapters` says "Defaults to the number of configured adapters",
but nothing defaults it and `addLoRAVLLMArgs` only emits `--max-loras` when
the field is explicitly set. vLLM's own default applies instead. Same for
`MaxCpuAdapters`. Unrelated to the route, worth its own ticket.

Analysis, options and the phased plan live in the four `llmisvc-httproute-*.md`
docs next to this file.
