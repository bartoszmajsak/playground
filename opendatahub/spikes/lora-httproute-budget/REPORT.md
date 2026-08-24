# The options

Eight LoRA adapters on one `LLMInferenceService` and the generated HTTPRoute
stops applying. Not a validation error, not a condition - a raw CEL rejection
from the apiserver, late in reconcile, phrased in terms of `spec.rules[4].matches`.
Seven adapters is the ceiling, and nothing anywhere counts them.

This file is the decision content: what the options are, what each one measured,
and what to do. The evidence lives in [FINDINGS.md](FINDINGS.md) and `golden/`,
the reproduction steps in [DEV.md](DEV.md), and the illustrated version in
`report.html`.

Every ceiling below was measured by asking the apiserver to validate a
synthesised route at rising adapter counts. Every "moved" figure is a diff of
where 72 real requests actually landed, before and after. Nine shapes were
measured; four are still in contention.

---

## Where the ceiling comes from

```
v1-model-routing matches           = 8 x (1 + A)     <- binding
v1-catch-all-model-routing matches = 1 x (1 + A)
route total                        = 9A + 19
```

Gateway API allows 16 rules, **64 matches per rule**, 128 matches per route. At
`A=7` the middle rule sits at exactly 64. At `A=8` it wants 72 and the apiserver
says no.

Two things make that worse than it reads:

- **The failure is a silent no-op.** The rejection happens inside a dry-run
  defaulting call, before the real apply, so the previously applied route keeps
  serving. Existing adapters keep working, the new one is invisible, and the
  only signal is a condition on the CR.
- **The budget is sticky.** Clearing `spec.model.lora` leaves the route carrying
  adapter matches that no longer exist, reporting ready. A service that once had
  7 adapters carries that cost after dropping to 3. Filed as
  [#279](https://github.com/bartoszmajsak/work-items/issues/279).

### What the ceiling buys

The two rules that cause it are an **index from model name to InferencePool**,
and they are what lets a single shared `/v1/chat/completions` serve many models.
Without the header that endpoint does not resolve at all - measured.
Service-scoped paths never needed it and are unaffected either way.

So `serving.kserve.io/model-based-routing-enabled: "false"` is a real option but
not a free one: it takes the route to 10 rules and 10 matches and removes the
shared endpoint with it. Reasonable where nobody can use that endpoint - on ODH
the authorization policy denies it today - and the wrong call the moment a
body-based router ships. Everything below assumes you are keeping it.

---

## The four still in contention

| shape | max adapters | moved | binding limit | renames rules | portable |
|---|---|---|---|---|---|
| `current` | 7 | - | 64 / rule | - | - |
| `split` | 12 | 0 | 128 / route | yes, 1 -> 4 | yes |
| **`split-noslash`** | **22** | **1** | 128 / route | yes, 1 -> 4 | yes |
| `alternation` | 175-240 | 0 | RE2 program size | no | not on kgateway |

**Read the moved column carefully.** It counts requests whose *destination*
changed, which is not the same as requests that *broke*. Put a real endpoint
picker in the path and `collapse`'s 20 moved destinations change only 2
outcomes, and both were already returning 404. Moved is a signal to look, not a
cost.

### `split-noslash` - 7 to 22 - recommended

Split the routing rule per endpoint, and drop the trailing-slash duplicates.

- Triples the ceiling for exactly one moved probe.
- **No regex at all**, so no data plane can refuse it and no program-size limit
  applies. The only option here immune to the kgateway problem.
- Nothing a client sends changes: same paths, same model names.
- The twins it drops only compensate for an undocumented `Exact` match choice.
- Renames a rule 1 -> 4, which detaches any hand-written `sectionName` policy
  and cannot be safely aliased. ODH's own AuthPolicy targets the whole route, so
  it is unaffected.
- Header-addressed `/v1/completions/` stops reaching the pool.
- 22 is still a ceiling. It buys room, not an answer.

### `alternation` - 7 to 175-240 - data-plane dependent

List the names that already exist in one regex. Change nothing else.

- Zero behaviour change: byte-identical across all 72 probes and all 13
  endpoint-picker outcomes.
- No renamed rule, no renamed model, nothing a client sees.
- Anchored exactly on both data planes: `adapter-a1` matches, `adapter-a1x`
  does not.
- **Reaches 1 to 2 adapters where the RE2 limit is left at Envoy's stock 100**,
  which is fewer than anyone runs. Istio sets 32768, Envoy Gateway disables the
  check, kgateway leaves the default. Matching Istio there needs the limit
  raised to about 3550, and kgateway does not expose it.
- Pattern is rewritten whenever the adapter set changes, so route churn stays.

### `split` - 7 to 12

Revert [kserve#5826](https://github.com/kserve/kserve/pull/5826). Four rules
again, one per endpoint.

- Provably zero behaviour change across all 72 probes.
- Returns to a state that shipped for months.
- Renames a rule 1 -> 4, and that rename cannot be safely aliased.
- Spends 3 of the 4 remaining rule slots for a 5-adapter gain.

#5826 consolidated four rules into one to free three rule slots, trading match
budget - the binding constraint - for rule budget, which was not scarce. 12 of
16 rule slots were in use. **It lowered the adapter ceiling from 12 to 7.**

---

## Trade-offs, exactly

| | `current` | `split` | `split-noslash` | `alternation` |
|---|---|---|---|---|
| max adapters | 7 | 12 | 22 | 175-240 istio / 1-2 kgw |
| what binds it | 64/rule | 128/route | 128/route | RE2 program size |
| rule slots used (of 16) | 12 | 15 | 15 | 12 |
| requests that move (of 72) | - | 0 | 1 | 0 |
| outcomes that change (real EPP) | - | 0 | 1 | 0 |
| renames rules | - | yes, 1 -> 4 | yes, 1 -> 4 | no |
| policy migration | - | unaliasable | unaliasable | none |
| client-visible strings change | - | no | no | no |
| route rewritten per adapter | yes | yes | yes | yes |
| uses a header regex | no | no | no | yes |
| works on kgateway | yes | yes | yes | 2 adapters |
| added request latency | - | none | none | below noise |
| reversible | - | yes | yes | yes |

**Read three rows together.** *Renames rules* and *works on kgateway* decide
this. `split-noslash` pays once in policy migration and is then immune to any
data plane, because it contains no regex to refuse. `alternation` pays nothing
at all until you move it off Istio, at which point it pays everything.

*Route rewritten per adapter* is `yes` in every remaining column, and that is
not an oversight. The only shape that answered `no` did it by putting the base
model's name inside the adapter's, which is the shape this report rejects on
naming grounds. Nothing that keeps flat adapter names can avoid rewriting the
route when the adapter set changes.

### Why "unaliasable" is the sharp word

Renaming a rule detaches any Kuadrant policy pinned to it by `sectionName`.
Recoverable when the rename is one-to-one: put the old name back and enforcement
returns. But `split` turns one rule into four, so a single alias covers one of
them. Tested: the policy came back reporting `Accepted=True`, `Enforced=True`
while actually covering **a quarter** of its former traffic. A green policy with
a 75% hole is worse than the clean break, which at least reports
`TargetNotFound`.

This only affects policies someone wrote themselves against our rule names.
odh-model-controller's own policies target whole objects and are unaffected -
and so do Models-as-a-Service's. Zero occurrences of `sectionName` in either
repo; both discriminate with `when` predicates on `request.path` instead. Two
teams, no shared code, same convention.

---

## Also evaluated, and dropped

Five more shapes were measured to the same standard - same synthesised routes,
same 72 replayed requests, same golden files. Here rather than deleted so nobody
measures them again.

| shape | max adapters | moved | binding limit | why it lost |
|---|---|---|---|---|
| `nested` | unbounded | 7 | nothing in the route | Names an adapter after its base model. See below |
| `prefix` | 15 | 8 | 64 / rule | `split-noslash` reaches 22 for one moved request |
| `split-prefix` | 22 | 8 | 128 / route | Strictly dominated: same 22, 8x the blast radius, same rename |
| `collapse` | 58 | 20 | 128 / route | Drops path scope, reversing a deliberate decision in kserve#5087 |
| `collapse-dedup` | 63 | 20 | 64 / rule | 5 more adapters, bought with a rename and everything `collapse` gives up |

**Three lost on the numbers.** `prefix`, `split-prefix` and `collapse-dedup` are
each beaten on every axis that matters by a shape still in the table, so there
is no configuration of requirements under which one of them is right.

### `nested` lost on product semantics, not on any measurement

It was the recommendation for most of this spike, and on the numbers it still
wins everything: unbounded on both axes, constant pattern, identical on three
control planes, no rule rename, no measurable latency, and the only shape that
stops the route being rewritten every time an adapter changes. None of that is
retracted.

What it costs is that `publishers/{ns}/models/{base}/adapters/{adapter}` puts an
implementation detail in a public identifier. **A LoRA adapter is a model people
ship.** It has its own card, its own evals, its own consumers, and those
consumers do not care that it happens to be implemented as low-rank weights over
a base. Two concrete consequences:

1. **It names things by how they were trained.** A full fine-tune of the same
   base, served as its own LLMInferenceService, gets a flat name. A LoRA serving
   the same purpose to the same callers gets a nested one. The training method
   becomes visible in the API for no reason the caller can act on.
2. **It breaks on re-basing.** Retrain the adapter against `granite-3-2` and its
   identifier has to change, because the identifier encodes the base. That is a
   breaking change to every client, forced by something they should not be able
   to observe.

The argument for nesting is real but it is all operational - an adapter cannot
be served without its base, shares its instance, tokenizer, context window and
hardware. All true, and all of it belongs in metadata rather than in the name.

Earlier revisions priced the rename as a one-time migration cost and recommended
paying it. That under-priced it: it is not a migration, it is a modelling error
that keeps costing.

### `collapse` did not lose on the numbers

It is the only dropped shape that answers a question none of the survivors do:
how do you get past about twenty adapters without a regex and without changing a
name clients send. 58 is a real number and its measured cost is much smaller
than 20 moved requests suggests - all 20 are the same shape, a model routing
header on a path that is not an inference endpoint, and the picker passes
bodyless paths straight through with a 200.

It is dropped because **giving up path scope is not ours to give up** - it
undoes an upstream decision made on purpose in
[kserve#5087](https://github.com/kserve/kserve/pull/5087), sending `/health` and
`/metrics` through a scheduler. If the adapter count lands between 22 and 58 and
both `alternation` and `nested` are refused, this is the shape to reopen.

---

## What adding an endpoint costs

Every ceiling above assumes **four** API endpoints, because that is what kserve
templates today. The budget is paths times models, so that assumption is
load-bearing and nobody had priced it. Read from the live vLLM's
`/openapi.json`, not from memory - 23 operations:

| class | count | can the gateway route on it? | examples |
|---|---|---|---|
| model in the body | 11 | yes - the only class the routing rule can serve | `/v1/chat/completions`, `/v1/messages`, `/tokenize` |
| stateful id in the path | 2 | no - names a prior response, not a model | `/v1/responses/{id}`, `.../{id}/cancel` |
| no model at all | 10 | n/a - needs no per-model match | `/v1/models`, `/health`, `/metrics` |

**The route covers four of the eleven.** Model-bearing and not routed today:
`/v1/messages/count_tokens`, `/v1/chat/completions/batch`,
`/v1/chat/completions/render`, `/v1/completions/render`, `/tokenize`,
`/detokenize`, `/inference/v1/generate`. Two of those are not under `/v1/` at
all. And the set is task dependent - an embedding or reranker model adds
`/v1/embeddings`, `/pooling`, `/score`, `/rerank`, `/classify`. The union across
model types is comfortably past ten.

Adapter ceiling by endpoint count (`hack/endpoint-budget.py`):

| shape | 4 (today) | 5 | 6 | 8 | 11 |
|---|---|---|---|---|---|
| `current` | 7 | 5 | 4 | none | none |
| `split` | 12 | none | none | none | none |
| `split-noslash` | 22 | none | none | none | none |
| `collapse` (dropped) | 58 | 57 | 56 | none | none |

**The recommendation is one endpoint from impossible.** `split-noslash` spends
15 of 16 rule slots at four endpoints. A fifth needs 18. It does not degrade, it
stops being expressible. None of this is about adapters: the rule budget is
exhausted by endpoints before the match budget is exhausted by models.

### Why the rules multiply, and the one-line fix

Each path rule carries its own `URLRewrite` back to that endpoint's path, and
Gateway API filters are per **rule**, not per match. Four matches in one rule
cannot have four different rewrites, which is why there is a rule per endpoint
per path family - eight of the twelve rules, before any model routing.

Match `PathPrefix /{ns}/{name}/v1` once and rewrite to `/v1` instead.
`ReplacePrefixMatch` replaces the matched prefix and leaves the rest alone.
Measured on the real gateway:

| request | status | rewritten to |
|---|---|---|
| `/epbudget/svc-a/v1/chat/completions` | 200 | `/v1/chat/completions` |
| `/epbudget/svc-a/v1/models` | 200 | `/v1/models` |
| `/epbudget/svc-a/v1/messages/count_tokens` | 200 | `/v1/messages/count_tokens` (not in the route today) |
| `/epbudget/svc-a/health` | 200 | `/health` (via the catch-all) |

What consolidation buys:

| shape | 4 | 5 | 6 | 8 | 11 |
|---|---|---|---|---|---|
| `current` | 7 | 5 | 4 | 3 | 1 |
| `split` | 12 | 10 | 8 | 6 | 4 |
| `split-noslash` | 23 | 19 | 16 | 12 | 9 |
| `collapse` (dropped) | 61 | 61 | 61 | 61 | 61 |

So the structural answer is on the path axis, not the header one. It is the
difference between `split-noslash` dying at five endpoints and reaching eleven.
It costs one thing: non-inference `/v1/` paths like `/v1/models` go through the
endpoint picker rather than direct to the Service - already measured for the
collapse, 200, answers normally.

It is also the only change here **free of the naming argument**. It touches no
model identifier, no header value, nothing a client sends - and no policy
granularity, because the AuthPolicy decides on request attributes rather than on
which rule matched.

### The two endpoints no shape can route

`GET /v1/responses/{id}` and `POST /v1/responses/{id}/cancel` carry no model
anywhere - not in the path, not in the body. On a service-scoped path that is
fine, the URL names the service. On the shared endpoint there is nothing to
route on, and the endpoint picker answers `400 model not found in request body`.
Any stateful API added later has the same shape. Solving it needs the id to
encode its pool, or session affinity - neither is a routing-budget question.

---

## Sharding: the budget is per route, and routes are free

Every cap here - 16 rules, 64 matches per rule, 128 matches per route - is
scoped to **one HTTPRoute**. Nothing in Gateway API caps how many routes attach
to a Gateway. So the ceiling is only a ceiling if all the matches have to live in
one object, and they do not.

Measured on the real gateway: three HTTPRoutes, one model-routing rule each, all
pointing at `svc-a`'s InferencePool, rule name deliberately identical in all
three.

| shard | header | served |
|---|---|---|
| shard-1 | `.../model-a` | `model-a` |
| shard-2 | `.../adapter-a1` | `adapter-a1` |
| shard-3 | `.../adapter-a2` | `adapter-a2` |

| state | envoy routes | with per-route ext_proc |
|---|---|---|
| before | 99 | 80 |
| after 3 shards | 102 | 83 |

**+3 routes, +3 with ext_proc, nothing lost.** That was the test that mattered.
Several routes merging on one gateway is exactly the shape of
[istio#58392](https://github.com/istio/istio/issues/58392), where every
InferencePool but the first lost its picker config. This cluster runs 1.30.3,
which carries the fix. On 1.28.1 through 1.28.4 this is the shape that breaks.

Models per shard (`hack/endpoint-budget.py`):

| shard shape | 4 endpoints | 6 | 8 | 11 | binds on |
|---|---|---|---|---|---|
| one rule per shard | 16 | 10 | 8 | 5 | 64 / rule |
| one rule per endpoint per shard | 32 | 21 | 16 | 11 | 128 / route |

**32 adapters per shard at today's four endpoints, and shards are unbounded.**
It is the only structure here that lifts the ceiling arbitrarily *while keeping
flat adapter names* - which is what makes it the answer `nested` could not be.
It needs no controller change to try: `spec.router.route.http.refs` accepts
user-supplied routes today, and `getHTTPRouteNames` iterates **every** ref, so
each shard gets its own AuthPolicy automatically. That is the opposite of what
happens with controller-generated extra routes, which would get none.

Three things it inherits:

1. **Rule names must be unique per shard.** All three shards here carried the
   name `v1-model-routing` and produced one identical ext_proc config - benign,
   because all three target the same pool. Shards spanning different pools is
   precisely [#282](https://github.com/bartoszmajsak/work-items/issues/282).
2. **It maximises exposure to the merge path.** More routes on one gateway is
   more of the code [#285](https://github.com/bartoszmajsak/work-items/issues/285)
   is still open against on `origin/master`. Sharding makes the buggiest function
   in the stack the hottest one.
3. **Someone has to own the sharding.** By hand through `refs` it is a
   maintenance burden that grows with adapters; in the controller it is new
   logic, including which shard an adapter lands in and what happens when it
   moves.

---

## Recommendation

Two of these buy room, one removes the ceiling outright, and the last is the
only thing that removes the *enumeration*. None requires renaming a model.

### 1. Fix the pruning bug and add a pre-flight check

Unchanged by everything below, and needed under every shape. Clearing
`spec.model.lora` leaves the route carrying an adapter that no longer exists,
while reporting ready. And nothing counts the budget before applying, which is
why exceeding it arrives as a raw CEL string rather than a condition.

If a regex shape is adopted, the check has to count **RE2 program size** too,
not just matches and bytes, because that is the limit the data plane enforces
and it enforces it silently.

### 2. Consolidate the path families first, or the rest is moot

Eight of the twelve rules are one-per-endpoint-per-family, each carrying its own
`URLRewrite`. Match `PathPrefix /{ns}/{name}/v1` once and rewrite to `/v1`
instead. Two rules per family become one, and endpoint count stops consuming
rule slots.

This is not an optimisation, it is a precondition. At four endpoints
`split-noslash` spends 15 of 16 rule slots; a fifth endpoint needs 18 and the
shape stops being expressible. Consolidated it reaches eleven.

### 3. Take `split-noslash`, everywhere

7 to **22** for exactly one moved probe, and the moved one is a trailing-slash
path no OpenAI client emits. It contains **no regex**, so no data plane can
refuse it. Nothing a client sends changes. The cost is a rule rename 1 -> 4 that
detaches hand-written `sectionName` policies and cannot be safely aliased;
odh-model-controller's own AuthPolicy targets the whole HTTPRoute, so it is
unaffected.

Be honest about what this is: **headroom, not an answer**. 22 is still a
ceiling, still linear in adapter count, and it assumes today's four endpoints.
With the consolidation above it is 23 at four endpoints and 9 at eleven.

### 4. If 22 is not enough, shard the routes rather than reach for a regex

32 adapters per shard at today's endpoint count, shards unbounded, measured on
the real gateway with nothing losing its endpoint-picker config. The only
structure that lifts the ceiling arbitrarily while keeping flat adapter names.
Needs a version floor of Istio **1.28.5 / 1.29.0**, unique rule names per shard,
and eventually someone to own shard assignment in the controller rather than by
hand.

### 5. Consider `alternation` only where you own the data plane

On Istio and Envoy Gateway it reaches roughly 175 to 240 adapters, set by
adapter name length rather than by any headline number, with zero behaviour
change and no rename. OpenShift AI ships Istio, so it is available there.

**The gate is the specification, not kgateway being behind.** Gateway API rates
`RegularExpression` header matching *Implementation-specific*, its weakest
support level, against *Core* for `Exact` - and says outright that
implementations "can support POSIX, PCRE or any other dialects". So neither the
size a pattern may reach, nor its dialect, nor how it anchors is guaranteed by
anything. Build the adapter index on it and the ceiling is whatever the weakest
data plane you support allows, now and in every future version. kgateway raising
its limit tomorrow would not create the guarantee.

Concretely today: wherever the RE2 program-size limit is left at Envoy's stock
100 it fails at one or two adapters, and matching Istio needs about 3550. Gate
it on a program-size pre-flight check rather than a byte count, and never ship
it as an upstream default.

Separately worth filing regardless of the limit: the route reports `Accepted`
while the proxy NACKs the whole RouteConfiguration with `RE2 program size of 117
> max program size of 100`. A restrictive limit is a constraint; an invisible
one is a trap.

### 6. Then get the index out of the HTTPRoute

Sharding removes the *ceiling*. It does not remove the *enumeration*: the route
set is still rewritten every time an adapter changes, the model name still has
to appear once per adapter somewhere, and none of it authorizes anything. If
adapters keep flat names - and they should - the map from model name to
InferencePool has no structure to exploit, so every in-route answer is linear in
something.

The map belongs where the body is already being read: a body-based router plus a
pool-level model index. GIE's `InferenceModelRewrite` cannot do it today because
it is scoped by `poolRef`, so it only applies once you have already reached a
pool - it answers "which model", never "which pool". That is a gap in the
current API rather than a law, and closing it is a cross-repo dependency, not a
kserve-local choice. **It is also the same work that would close the
path-versus-body authorization gap**, since both need the name that vLLM will
actually act on to be the name something authoritative reads.

---

## The authorization gap

Worth stating separately because it is not a routing-budget question and it
survives every option above.

The ODH AuthPolicy derives its SubjectAccessReview resource name from
`request.path`. vLLM applies the adapter from `body.model`. Nothing compares
them. Measured: authorized on `model-a`, served by `adapter-a2`, 200.

Bounded, and worth being precise about the bounds. It stays inside one
InferencePool - `model-b` and `shared-adapter` both 404 from svc-a - and a
header cannot hijack a publisher path, because the longer prefix wins (measured
both ways). But **an adapter can be reached but never authorized as itself**: it
has no publisher path. Not in the template's "Known limitations", and no e2e
test sends a disagreeing body.

---

## Corrections to the design docs

Three numbers do not survive measurement. A fourth claim does, against my own
earlier reading of it.

- **#5826 lowered the ceiling from 12 to 7.** It consolidated four rules into
  one to free three rule slots, trading match budget - the binding constraint -
  for rule budget, which was not scarce.
- **The collapse reaches 63 adapters**, not the roughly 122 estimated. The
  figure conflated the per-rule cap of 64 with the route-wide 128. Getting past
  63 needs a match-splitter on top of the collapse.
- **The RE2 limit is not one number.** The docs assume Envoy's default of 100.
  Istio sets 32768, Envoy Gateway disables the check, kgateway leaves the
  default. The objection is right about the risk and wrong about the prevalence,
  and neither doc says which data plane it is talking about.
- **The rejection of the alternation stands, on the risk if not the odds.** This
  is a retraction of my own correction. On the strength of the Istio measurement
  I recorded the alternation as an option the docs had wrongly dismissed; on
  kgateway with realistic names it reaches six adapters, fewer than we have
  today. Two of three implementations are in fact fine with it, so "Istio-only"
  was too strong - but an upstream default cannot depend on a setting one
  shipping implementation gets wrong, which is what the docs were arguing.

---

## Filed

| id | title | pri |
|---|---|---|
| [#282](https://github.com/bartoszmajsak/work-items/issues/282) | Identical rule names cross-wire endpoint pickers between services | p1 |
| [#279](https://github.com/bartoszmajsak/work-items/issues/279) | Clearing `spec.model.lora` leaves stale adapter matches in the route | p2 |
| [#283](https://github.com/bartoszmajsak/work-items/issues/283) | Istio below 1.29 never invokes the endpoint picker | p2 |
| [#285](https://github.com/bartoszmajsak/work-items/issues/285) | istiod crashes merging InferencePool and plain HTTPRoutes on one gateway | p2 |
| [#280](https://github.com/bartoszmajsak/work-items/issues/280) | `MaxAdapters` default is reported but never applied | p3 |
| [#284](https://github.com/bartoszmajsak/work-items/issues/284) | Collision warning names the base model instead of the colliding adapter | p3 |

---

## What this does not prove

Stated plainly, because the numbers above are otherwise easy to over-read.

- **Two endpoint-picker findings are still Istio-only.** The EPP bypass below
  1.29 and the rule-name cross-wire were not retested elsewhere. The EPP's
  *request* behaviour now has a second implementation - 12 of 12 outcomes agree
  on Envoy AI Gateway - but those two findings are about version behaviour and
  route naming and remain unrepeated. Given that adding an implementation is
  what reversed the regex recommendation twice, assume they are Istio-specific
  until someone checks.
- **Three control planes is not "portable".** Istio, kgateway and Envoy Gateway
  all configure Envoy. Nothing here says anything about a non-Envoy
  implementation, and the full-match header semantics all three rely on are
  unspecified by Gateway API rather than guaranteed by it.
- **The ODH authorization analysis is read, not run.** Its policy denies
  header-addressed traffic outright, which would make the header family dead
  weight there, but that is source-reading rather than observation.
- **The latency figures come from one laptop.** They bound the per-evaluation
  cost below what the rig can resolve, which is enough to rule the regex out as
  a request-time concern, but they are not a throughput model for a real
  cluster.
- **The adapter target is still unset.** Every ceiling here is measured against
  a requirement nobody has fixed. If the answer is "under 20", `split-noslash`
  is the whole fix and the rest of this document is background.

---

Measured on kind: Gateway API v1.5.1, GIE v1.5.0, Istio 1.30.3, kgateway v2.1.1,
Envoy Gateway 1.9.0 with the Envoy AI Gateway addon, Kuadrant 1.5.2, kserve
`master`, real vLLM with two LoRA adapters. Reproduction steps in
[DEV.md](DEV.md); full evidence and probe matrices in [FINDINGS.md](FINDINGS.md)
and `golden/`.
