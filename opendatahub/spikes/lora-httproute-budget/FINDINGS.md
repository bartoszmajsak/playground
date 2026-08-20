# Findings

Everything below was measured on a kind cluster, not derived from reading code - except where explicitly marked **unverified**. Reproduction steps are in
`README.md`; the raw evidence is in `golden/`.

**Environment.** kind, Gateway API CRD **v1.5.1** (16 rules / 64 matches per rule
/ 128 per route, read off the installed CRD), GIE **v1.5.0**, kserve `master`
@ `2f2afd58`, Istio **1.28.1 then 1.30.3**. Workload for svc-a is real vLLM
(`vllm/vllm-openai-cpu:v0.19.0`) serving `hmellor/tiny-random-LlamaForCausalLM`
with two generated LoRA adapters; svc-b/svc-c run `llm-d-inference-sim`.

---

## 1. The adapter ceiling is 7, and the arithmetic in the design docs is right

| A (adapters) | max matches/rule | route total | result |
|---|---|---|---|
| 0 | 8 | 19 | applied |
| 3 | 32 | 46 | applied |
| 6 | 56 | 73 | applied |
| 7 | **64** | 82 | applied, at the cap |
| 8 | - | - | **rejected** |

```
spec.rules[4].matches: Too many: 72: must have at most 64 items
```

`stripModelBasedRoutingRules` checks out too: svc-c with model-based routing off
generates 10 rules / 10 matches, no header rules, adapter count irrelevant. The
per-service `spec.annotations` value *does* override the preset's `"true"`.

**The failure is a silent no-op, not an outage.** The rejection happens inside a
*dry-run defaulting* call before the real apply, so the previously applied route
keeps serving. Existing adapters keep working, the new one is invisible, and the
only signal is a condition on the CR.

## 2. Measured ceilings per candidate shape

`probe-ceiling.sh` synthesises each shape at rising adapter counts and asks the
apiserver to validate with `--dry-run=server` - the same CEL and `maxItems`
checks the controller trips over, without the controller or any traffic.

| shape | maxA | binding limit | probes moved | change |
|---|---|---|---|---|
| `current` | **7** | per-rule 64 | - | - |
| `split` | **12** | route-wide 128 | **0** | revert #5826 |
| `prefix` | **15** | per-rule 64 | 8 | `Exact` → `PathPrefix` |
| `split-noslash` | **22** | route-wide 128 | **1** | revert #5826 + drop twins |
| `split-prefix` | **22** | route-wide 128 | 8 | revert #5826 + `PathPrefix` |
| `collapse` | **58** | route-wide 128 | 20 | header-only rule |
| `collapse-dedup` | **63** | per-rule 64 | 20 | + drop the dead catch-all |
| `alternation` | **320** istio / **6** kgw | RE2 program size | **0** | one regex lists the existing names |
| `nested` | **unbounded** | nothing in the route | 7 | adapters served under the base |

`alternation` and `nested` are the two constant-size shapes - 12 rules, 19
matches, unchanged at any adapter count. See sections 9 and 14.

**Correction to the design docs.** `llmisvc-httproute-budget.md` §5 and the
phased plan both put the header-only collapse at ~122 adapters. Measured it is
**63**, and the binding limit is the per-rule 64 cap, not the route-wide 128 - the table conflated the two. Getting past 63 needs the Phase 3 T1
match-splitter *on top of* the collapse, landing near 117.

**`collapse-dedup` is behaviourally identical to `collapse`** (empty diff).
Once `v1-model-routing` is header-only its match set is identical to
`v1-catch-all-model-routing`'s and sits earlier, so the catch-all is dead code.

## 3. #5826 lowered the adapter ceiling from 12 to 7

The rationale for both catch-all rules is on record in the PR bodies (the commit
messages are bare sign-offs).

**#5087** (Feb 2026), which created the pool/Service split:

> This ensures only completion endpoints are routed through the InferencePool
> for intelligent load balancing, while other traffic (health checks, model
> info, etc.) goes directly to the Service.

So `/health` and `/v1/models` reaching the Service is a deliberate decision. The
collapse reverses it.

**#5826** (Jul 2026) then consolidated four per-endpoint model-routing rules
into one, "to free three rule slots under Gateway API's `MaxItems=16` ceiling".
The reasoning is sound and behaviour-neutral - but it traded the wrong resource.

| | rules | model-routing layout | maxA |
|---|---|---|---|
| pre-#5826 (structurally == `split`) | 15 | 4 rules × 2 matches | **12** |
| post-#5826 (`current`) | 12 | 1 rule × 8 matches | **7** |

Matches multiply per adapter, so concentrating them into one rule multiplies the
growth rate against a cap that is **per rule**. The route total is the same
expression either way (`9A + 19`); only the binding constraint moved. Rule slots
were not scarce (12 of 16 used); matches were.

LoRA expansion landed 2026-05-21 (#5521), #5826 landed 2026-07-15 - the
multiplication was live for two months, so this is a regression rather than an
unlucky ordering.

At A=0 both versions are byte-identical at 19 matches. The damage is entirely in
the derivative, which nothing measures - and #5826's own test used 2 adapters,
where 24 is comfortably under 64.

## 4. Why the trailing-slash twins exist

Only because the header rules use `Exact`. `PathPrefix /v1/completions` already
matches `/v1/completions`, `/v1/completions/` and everything below; `Exact`
matches one literal string, so it needs a twin. The path family has used
`PathPrefix` since the start and never needed one. Nothing documents the choice.

Two ways to remove them, not equivalent:

- **drop them, keep `Exact`** (`split-noslash`) - 1 probe moves
- **switch to `PathPrefix`** (`split-prefix`) - 8 probes move, because
  `PathPrefix` also picks up everything below each endpoint

Both land on 22, so **`split-noslash` dominates `split-prefix`**: same ceiling,
one moved probe instead of eight. Of the 8, only `POST /v1/messages/count_tokens`
is desirable (it carries a model); five are model-less stateful sub-resources
(`/v1/responses/{id}`, `/cancel`, `/input_items`, `/v1/messages/batches{,/id}`)
and two are paths nothing serves. The segment boundary does hold under
`PathPrefix`: `/v1/completions-extra` stays on the Service.

## 5. The unscoped header capture is real, and wider than `/`

`v1-catch-all-model-routing` has no path match, so *any* path carrying a valid
model header reaches that service's workload Service:

| request | header | lands on |
|---|---|---|
| `GET /docs` | `…/model-a` | neighbour (longer prefix wins) |
| `GET /` | `…/model-b` | **svc-b's workload Service** |
| `GET /some/neighbour/page` | `…/model-a` | **svc-a's workload Service** |
| `POST /anything/at/all` | `…/model-a` | **svc-a's workload Service** |

This is today's shipped behaviour, not something the collapse introduces. Path
precedence protects a neighbour only while its prefix is longer than `/`.

## 5b. The collapse costs far less than the destination count suggests

Section 2 counts probes whose *destination* changes. With a real EPP in the path
(Istio 1.30.3, svc-a alone to avoid the section-7 collision), what changes in
*outcome* is much smaller - 2 of 13, and both were already errors:

| path | today (Service) | collapse (pool -> EPP) |
|---|---|---|
| `/health` | 200 | **200** |
| `/metrics` | 200 | **200** |
| `/v1/models` | 200 | **200** |
| `/v1/messages/count_tokens` | 200 | **200** |
| `/`, `/v1/responses/{id}` | 404 | 404 |
| `/v1/embeddings` | 404 (vLLM: Not Found) | **400** (EPP: invalid embeddings request) |
| `/anything/at/all` | 404 (vLLM: Not Found) | **400** (EPP: no parser registered matching path suffix) |

The prediction that bodyless requests would 400 with `model not found in request
body` (`director.go:246`) is **wrong**. That error text -- "no parser registered
matching path suffix" -- reveals a path-based parser registry in front of the
model check in GIE v1.5.0: known inference paths are parsed, unknown ones
rejected, and bodyless GETs to non-inference paths pass through untouched.

So `/health` and `/metrics`, the traffic #5087 deliberately kept off the pool,
survive the collapse. **"Moved" is not "broken"** -- the tier-2 harness measures
destination, this measures outcome, and only the second one prices the change.

Caveats: measured against GIE v1.5.0's EPP, so a different or downstream EPP
build may not have the parser registry; and 13 paths is not exhaustive.

## 6. Istio 1.28.1 never invokes the EPP

`router.scheduler: {}` on Istio **1.28.1** produces an EPP that is deployed,
healthy and resolved - and completely bypassed.

- Envoy's ext_proc filter sits on `grpc_service.envoy_grpc.cluster_name:
  "dummy"` with `request_header_mode: SKIP`, awaiting a per-route override
- **no route carries `typed_per_filter_config`** - zero, across every listener
  and route config
- EPP `rq_total` = **0** on 9002/9003/9090/5557; the EPP's own metrics endpoint
  records no requests; its logs show control-plane activity only
- with 3 replicas, traffic distributes **18/10/9 - round-robin**, because the
  cluster's `override_host` LB reads `x-gateway-destination-endpoint` from
  `envoy.lb` metadata that nothing ever writes

Ruled out: staleness (full gateway + istiod restart), hand-applied vs
controller-generated routes, CRD group mismatch (route and pool are both
`inference.networking.k8s.io`), missing env vars (both set on the running
process), `port` on the backendRef, missing `sectionName`, missing
DestinationRule, and the `istio.io/inferencepool-extension-*` labels (all three
present and correct on the synthesised pool Service).

**Istio 1.30.3 fixes it**: 56 routes get per-route ext_proc, EPP `rq_total`
tracks requests 1:1, and with 3 replicas all traffic goes to **one EPP-chosen
endpoint** instead of round-robin. 1.29 not bisected.

Nothing reports a problem in either version - pods Ready, routes `Accepted`,
pools `ResolvedRefs=True`. With a single replica it is invisible.

## 7. Identical rule names cross-wire the EPP across services

This is the most consequential finding, and it lands squarely on this spike's
subject.

Istio keys its inference-pool ext_proc map by **bare route-rule name**:

```go
// route_collections.go:119-121
routeRuleToInferencePoolCfg := make(map[string]*inferencePoolConfig)
for _, pair := range inferencePoolCfgPairs {
    routeRuleToInferencePoolCfg[pair.name] = pair.cfg   // pair.name == istioRoute.Name
}

// route.go:514
if infPoolRouteRuleCfg, ok := opts.InferencePoolExtensionRefs[in.Name]; ok {
```

No namespace or route qualification. kserve generates **identical rule names for
every LLMInferenceService** - `v1-model-routing`, `v1-chat-completions-path`,
`v1-completions-publisher-path`, … So on a shared gateway with N services,
last-write-wins.

Measured with three services on one gateway: **17 of 26 routes wired to another
service's EPP.**

```
v1-chat-completions-path   pool=svc-a  epp=svc-c   <-- MISMATCH
v1-model-routing           pool=svc-a  epp=svc-b   <-- MISMATCH
```

The winner pattern is exactly what last-write-wins predicts: `svc-c` took every
rule it has; `svc-b` took `v1-model-routing`, the one rule svc-c lacks because
model-based routing is disabled there.

Consequence: the wrong EPP returns endpoints from a pool it does not manage, and
Envoy answers **500 with an empty body** to every request carrying a body. GETs
pass, because they never reach body processing.

Causation proven by isolation - with only svc-a's route present (and istiod
restarted, see below), all 9 rules resolve to svc-a's own EPP and `POST` returns
200 with the EPP receiving the request.

Two further properties, both bad:

- **Non-deterministic.** An earlier run had svc-a resolving correctly with all
  three services present.
- **Sticky.** Deleting the other services' routes did not fix it until istiod
  was restarted - a full gateway restart was not enough.

Nothing surfaces any of it: pods Ready, routes `Accepted=True`, pools
`ResolvedRefs=True`, kserve conditions green.

**Two-sided fix.** Istio should qualify the map key with namespace/route. kserve
should generate rule names unique per service - and if Phase 1 renames rules
anyway, making them unique costs nothing extra.

The design docs treat rule names purely as a *migration* hazard (renaming
detaches Kuadrant `sectionName` policies). They are also a **correctness**
hazard: leaving them identical silently cross-wires inference scheduling on
exactly the shared-gateway, many-models deployment this epic exists to support.

## 8. Filed separately

- **[#279]** clearing `spec.model.lora` never prunes the route. The HTTPRoute
  keeps matches naming adapters that no longer exist, with
  `HTTPRoutesReady=True`. Re-checked in section 20: *reducing* the list prunes
  correctly (8 to 3 takes the rule from 64 matches to 32), so this is narrower
  than "removing adapters never shrinks the route" - it is the clear-the-field
  case only.

- **[#280]** `LoRASpec.MaxAdapters` / `MaxCpuAdapters` document a default that is
  never applied. Confirmed live: with 2 adapters configured, vLLM reports
  `vllm:lora_requests_info{max_lora="1"}` - its own default, not the documented
  "number of configured adapters".

- **[#282]** identical rule names cross-wire the EPP between services on a
  shared gateway (section 7). Filed p1 - it is a cross-tenant correctness bug on
  exactly the deployment shape this epic targets.
- **[#283]** Istio 1.28 never invokes the EPP (section 6). Filed p2 - the fix is
  a version floor, but it needs establishing and checking against what RHOAI
  ships.
- **[#284]** the `ModelNameCollision` event names the base model even when the
  overlap is a LoRA adapter (section 15). Filed p3 - detection works, the message
  points at the wrong name.

[#279]: https://github.com/bartoszmajsak/work-items/issues/279
[#280]: https://github.com/bartoszmajsak/work-items/issues/280
[#282]: https://github.com/bartoszmajsak/work-items/issues/282
[#283]: https://github.com/bartoszmajsak/work-items/issues/283

---

## 9. H3: nested served names work, and are unbounded

> **This is the recommended shape.** Section 14 found that an alternation over
> the *existing* names reaches 320 adapters on Istio with no naming migration,
> and read the design docs' rejection of it as a mistake. Section 16 retracts
> that: on kgateway the alternation reaches six. Nesting's pattern is a constant
> 44 characters, so no program-size limit reaches it, and it is the only shape
> that both survives an arbitrary data plane and stops the route being rewritten
> per adapter.

Serving adapters as `publishers/{ns}/models/{base}/adapters/{name}` lets one
regex cover the base model and every adapter beneath it:

```
RegularExpression: publishers/lora-budget/models/model-a(/.*)?
```

Measured (`nested` shape, both header rules converted):

| property | result |
|---|---|
| ceiling | **unbounded** - 200 is the prober's cap, no rejection at any A |
| shape | 12 rules, 8 matches/rule, **19 total, constant** |
| path scope | **preserved** (unlike the collapse) |
| BBR required | **no** |
| probes moved | **7** |

**Anchoring is safe.** The risk was that `…/model-a(/.*)?` might also capture a
different service named `…/model-a-instruct`. Proven by isolation: with svc-ai's
route deleted, `publishers/lora-budget/models/model-a-instruct` and
`…/model-a-instruct/adapters/x` both fall through to the neighbour, while
`…/model-a` still reaches svc-a. Envoy full-matches header regexes.

**The 7 moved probes** split into two groups: 3 flat adapter names
(`publishers/{ns}/models/adapter-a1`) stop matching - that *is* the served-name
migration, made visible - and 4 nested names start matching. One of those,
`…/model-a/adapters/nope`, names an adapter that does not exist and still
reaches the pool; a prefix scheme cannot distinguish, so the runtime rejects it
rather than the gateway. That is a real, if minor, change in where that error
comes from.

### Correction: the RE2 program-size objection does not apply on Istio

`llmisvc-httproute-budget.md` §3 rejects regex header matching because
"Envoy checks compiled regex program size via runtime key
`re2.max_program_size.error_level`, **default 100**", capping an alternation at
"two, maybe three adapters".

Measured on this cluster:

```
re2.max_program_size.error_level  final_value: 32768
```

Istio's bootstrap sets it to **32768**, 327x the Envoy default the docs assume.
A 932-character pattern is accepted by the apiserver, routes correctly, and
leaves neighbouring routes untouched - no blast radius at any length tested
(42 / 72 / 132 / 232 / 432 / 932 chars, all 200).

The docs' caution is not wrong in general - a bare Envoy or another data plane
may well ship the 100 default - but it is wrong for Istio, and the whole regex
track was closed on that premise. Worth re-testing per data plane before
reusing the conclusion. Envoy here is 1.38.4-dev via Istio 1.30.3.

## 10. S11: on ODH, header-addressed traffic is already denied

Read from `odh-model-controller` @ `ca6a09b`:
`internal/controller/resources/template/authpolicy_llm_isvc_userdefined.yaml`
and its design note `PUBLISHER-PATH-AUTH.md`. Analytical, not observed - no ODH
cluster was involved.

The research docs describe this policy as a single SAR that parses
`request.path.split("/")[1..2]`. It is now five rules, and one of them changes
the spike's conclusions:

| path | header | rule | effect |
|---|---|---|---|
| `/publishers/{ns}/models/{m}/v1/...` | any | `model-access-path` | Model SAR |
| `/{ns}/{name}/...` | none | `inference-access` | Instance SAR |
| `/{ns}/{name}/...` | valid model header | **`deny-misrouted-model-header`** | **403** |
| `/v1/chat/completions` | valid model header | **`deny-misrouted-model-header`** | **403** |
| `/v1/chat/completions` | none | (no rule) | authn-only (no route matches anyway) |
| `/v1/models` | any | (no rule) | authn-only (discovery) |
| `/health` | valid model header | **`deny-misrouted-model-header`** | **403** |

`deny-misrouted-model-header` is an immediate local deny (Authorino
`patternMatching` with `predicate: "false"`, priority 0, no API round-trip) that
fires whenever a valid-looking model routing header appears on a path that is
not a publisher path and not `/v1/files`|`/v1/batches`.

**Three consequences for this spike.**

**1. The header family does not work on ODH today.** Every probe in the spike's
`header` family - root path plus `X-Gateway-Model-Name` - is 403'd before
routing. So `v1-model-routing`, the rule that causes the entire 7-adapter
ceiling, currently serves only traffic ODH rejects. The *budget* it consumes is
real; the *traffic* is not.

**2. `nested` does not change that.** The deny predicate tests the header against
`^publishers/[^/]+/models/.+$`. A nested name
`publishers/{ns}/models/{base}/adapters/{x}` still matches, so nested traffic on
a non-publisher path is denied identically. Nested's value on ODH is the budget
and the constant shape, not new reachability.

**3. The supported addressing on ODH is the path families** - per-participant
`/{ns}/{name}/...` and publisher `/publishers/{ns}/models/{m}/...`. Those are
exactly the families whose rule count trades against the 16-rule cap, which
makes the `m + 1` rule budget the thing worth optimising for ODH, not the header
match count.

**Finding 5 was found independently, and mitigated.** `PUBLISHER-PATH-AUTH.md`
states it in the same terms this spike measured it:

> the kserve HTTPRoute template's `v1-catch-all-model-routing` rule matches on
> the model routing header alone (no path constraint). A per-participant path
> with a valid model header would be routed by the header (tenant-B) but
> authorized by the path (tenant-A) - a cross-tenant authorization bypass.

So the hole is real and known. It is closed **at the authz layer on ODH only** - upstream kserve without odh-model-controller still has it wide open, which is
what section 5 measured.

Also already handled: the "reserved path tokens" edge case in the design docs
(a namespace called `v1` or `publishers`) is blocked by a
ValidatingAdmissionPolicy on reserved namespace names.

**BBR is the stated plan.** The doc calls out `resolvedPath` normalization - rewriting `/v1/` + header into publisher form so `model-access-path` can
authorize it - as a planned follow-up. That is the path by which header
addressing becomes supported on ODH, and it re-raises Phase 2 as a cross-repo
dependency rather than a kserve-local optimisation.

## 11. Decision brief: the nested served-name change

`nested` is the only shape that makes the adapter axis disappear without BBR
(section 9). Everything below the routing layer is a naming decision, and that
part is not a routing call. This section states the cost so it can be decided
without rerunning anything.

### What changes

`workload_lora.go:167` registers every adapter with vLLM under two names - the
bare name and `publishers/{ns}/models/{adapter}`. The route matches the second.
Base and adapter are siblings in a flat namespace, which is why the route has to
enumerate them.

```
# today
publishers/my-ns/models/llama-3-8b        <- base
publishers/my-ns/models/sql-adapter       <- adapter

# nested
publishers/my-ns/models/llama-3-8b
publishers/my-ns/models/llama-3-8b/adapters/sql-adapter
```

That string is what a client puts in the request body:

```python
# before
client.chat.completions.create(model="publishers/my-ns/models/sql-adapter", ...)
# after
client.chat.completions.create(model="publishers/my-ns/models/llama-3-8b/adapters/sql-adapter", ...)
```

### What it costs

- **Every caller.** Notebooks, saved app configs, eval harnesses, benchmark
  scripts - anything with a model name written down. No conversion webhook
  reaches a string a client hard-coded.
- **`/v1/models` output.** Anything doing discovery sees new strings.
- **A new coupling.** Adapter identity now contains base-model identity, so
  renaming `spec.model.name` renames every adapter with it. Today they are
  independent; after nesting, a base rename is a breaking change for all adapter
  clients.

Mechanically it is contained: only the `Name` field in `--lora-modules` and the
route match value move. Mount paths (`sanitizeLoRAPathSegment`) and PVC volume
names (`kmeta.ChildName`) derive from the bare name and do not change.

### The migration is additive if sequenced

kserve already registers two names per adapter. Register three:

```
sql-adapter                                              (bare, unchanged)
publishers/my-ns/models/sql-adapter                      (legacy, unchanged)
publishers/my-ns/models/llama-3-8b/adapters/sql-adapter  (nested, new)
```

vLLM treats them as aliases for one adapter file - no runtime cost. Old clients
keep working. **Nothing breaks until the route stops matching the legacy names**,
and during that overlap the route needs both the nested regex and the enumerated
legacy matches, so the budget win only arrives when legacy is dropped.

Which is why `split` (free, 7 -> 12) or `split-noslash` (1 probe, 7 -> 22) is
worth taking regardless: it buys the headroom for the legacy names to age out on
a schedule rather than a flag day.

### What it buys

Unbounded adapters, constant 19-match route, path scope preserved, no BBR, no
ConfigMap, no sync window. Measured, not projected (section 9).

### Timing

Header-addressed adapter routing has close to zero adoption today - nothing
ships a header producer (section: notes), and on ODH that traffic is 403'd
outright (section 10). The cheapest moment to change a public name is before
anyone depends on it, and that window is open now.

### The residual

`publishers/{ns}/models/{base}/adapters/{nonexistent}` matches the regex and
reaches the pool; a prefix scheme cannot tell a real adapter from a made-up one.
The runtime rejects it rather than the gateway. Minor, but it is a change in
which component answers.

## 12. S10: the rename detach is real, loud, and only affects one shape family

Rehearsed with real Kuadrant 1.5.2 on the kind cluster: an `AuthPolicy` with
`targetRef.sectionName: v1-model-routing` and a deny-everything rule, then the
`split` shape applied over it.

**This policy was hand-written for the test - it is not one odh-model-controller
ships.** odh attaches two AuthPolicies and neither uses `sectionName`: the
Gateway-level one targets `Kind: Gateway` (`gateway_controller.go:236`) and the
route-level one targets the whole `Kind: HTTPRoute`
(`kserve_authpolicy_reconciler.go:86`). Both target whole objects, so **neither
detaches on a rule rename** - as `llmisvc-httproute-phased-plan.md` Phase 1.5
already predicted.

So everything below is about **user-attached** policies pinned to kserve rule
names. That narrows the blast radius: it is not an ODH-shipped-config problem.
It is also worth noting kserve rule names are not documented API today, so
pinning to them is undocumented-but-possible rather than supported - WP1.2
proposes making them API via `status.router`, which would change that.

| step | observed |
|---|---|
| policy attached | `Accepted=True`, `Enforced=True` |
| request hitting the pinned rule | **403** |
| request hitting a different rule | 200 (section scoping works) |
| **after the rename** | **200 within 15s** - previously denied traffic now passes |
| policy status after | `Accepted=False [TargetNotFound]`, naming `<route>#v1-model-routing` |
| events emitted | **none** - condition only |

**The docs' premise is half wrong.** `llmisvc-httproute-phased-plan.md` Phase 1.5
says such a policy "silently stops applying - for auth, a security regression
with no error". The regression is real and fast, but it is **not silent**:
Kuadrant reports `TargetNotFound` and names the exact dangling section. Anything
watching AuthPolicy conditions sees it. Nothing watching *events* does.

### The alias mitigation is a trap when the rename is 1:N

Re-adding the legacy name does restore enforcement - within 15s, back to
`Accepted=True`, `Enforced=True`, request back to 403. But `split` turns one rule
into four, and a single alias can only carry one of them:

| path | after aliasing one slice |
|---|---|
| `/v1/chat/completions` (slice carrying the legacy name) | **403** |
| `/v1/completions` | **200 - gap** |
| `/v1/responses` | **200 - gap** |
| `/v1/messages` | **200 - gap** |

The policy reports `Accepted=True`/`Enforced=True` while covering **one quarter**
of the traffic it used to. That is strictly worse than the clean detach, which at
least announces itself. **Aliasing is only safe when the rename is 1:1.**

### Which shapes actually rename anything

| shape | renames | policy detach risk |
|---|---|---|
| `split`, `split-noslash`, `split-prefix` | `v1-model-routing` → 4 rules | **yes, and aliasing is unsafe (1:4)** |
| `prefix` | none | **no** |
| `nested` | none | **no** |
| `collapse` | none | **no** |
| `collapse-dedup` | deletes `v1-catch-all-model-routing` | yes (1:0) |

This inverts the earlier read. `split` is free in *routing* - zero behaviour
change across 72 probes - but it is the **only** family that triggers the
Phase 1.5 migration hazard, and its 1:4 rename is precisely the case aliasing
cannot cover. `nested`, the shape with the largest apparent cost (a served-name
change), preserves every rule name and has **no** policy-detach problem at all.

### Route replacement does NOT bypass a whole-route policy

The `sectionName` case above is about user-attached policies. odh's own policies
target whole objects, so the question for them is different: does replacing the
HTTPRoute detach the policy while traffic is flowing? (The RHOAIENG-56131 class.)

Tested with a whole-route `AuthPolicy` (no `sectionName`, deny-everything,
odh's shape), polling ~100x/sec through the change:

| scenario | 403 (denied) | 000 (connection failure) | **2xx bypass** |
|---|---|---|---|
| in-place update (SSA apply of a different shape) | 2602 | 291 | **0** |
| delete + recreate | 2346 | 217 | **0** |

**No authorization bypass in either case**, and the policy reports
`Accepted=True`/`Enforced=True` throughout. What does happen is a short
availability gap - roughly 10% of a tight polling loop fails to connect while
the route is being reprogrammed. That is a connection-level failure, not a
request being wrongly allowed.

So the two policy shapes fail in different directions, and neither the way the
docs assumed:

| policy | rule rename | route replacement |
|---|---|---|
| `sectionName`-pinned (user-attached) | **enforcement lost**, but loud (`TargetNotFound`) | not tested |
| whole-route (odh's shape) | unaffected - rule names absent from targetRef | **no bypass**; brief unavailability |

*Correction worth recording:* the first run of this test reported a leak in both
scenarios. That was a probe bug - `curl -w '%{http_code}'` emits `000` on
connection failure and the script also had a `|| echo 000` fallback, so failures
were counted as non-403 and read as bypasses. Counting only 2xx as a bypass
gives zero. Availability blips and authorization gaps look identical to a naive
status-code check.

### What this means for Phase 1.5

- A pre-upgrade check is cheap now: enumerate `AuthPolicy` (and
  `RateLimitPolicy`) with `Accepted=False`/`TargetNotFound`, no bespoke old→new
  name mapping required.
- But detection is post-hoc, and enforcement drops in under 15 seconds. For auth
  that window is the whole problem, so detection alone is not a mitigation.
- If a 1:1 rename is unavoidable, ship the alias **in the same route update** as
  the rename - the route applies atomically, so there is no window.
- For a 1:N rename there is no safe alias. Either keep the original rule name on
  a rule that retains the original coverage, or accept the loud detach and
  migrate policies deliberately.

## 13. The endpoint picker needs a DestinationRule, or everything 500s while looking healthy

Found on a clean rebuild, after the earlier cluster's churn was ruled out as
the cause.

Istio originates mTLS to workloads in the mesh. The EPP serves **plaintext gRPC**
on 9002. Without a `DestinationRule` telling Istio not to, the ext_proc stream is
reset:

```
Received gRPC error on stream: 14, message upstream connect error or
disconnect/reset before headers. reset reason: connection termination
```

and every pool-bound request returns **500** - while the HTTPRoute is
`Accepted=True`/`ResolvedRefs=True`, the InferencePool is resolved, the
per-route ext_proc override is correctly attached to the right EPP cluster, that
cluster has healthy endpoints, and the EPP pod is Running with no restarts. The
only symptom is the 500 and a warning line in the gateway's log.

The fix is the rule Istio's own inference-extension task documents:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: <epp-service>-tls
spec:
  host: <epp-service>
  trafficPolicy:
    tls:
      mode: SIMPLE
      insecureSkipVerify: true
```

**Scope it per EPP Service.** A wildcard host (`*.ns.svc.cluster.local`)
originates TLS to every service in the namespace including the plaintext
workloads, which trades the 500 for a 503 - measured.

**Why this was easy to miss.** It was applied early in the investigation, on
Istio 1.28, and appeared to change nothing - because on 1.28 ext_proc is never
attached at all (section 6), so there was no stream to reset. It only becomes
load-bearing once the version floor is met. `setup.sh` and `capture-routes.sh`
now create it per EPP Service.

### Two other reproducibility traps found on the rebuild

**The alpha InferencePool group is transient.** kserve emits
`inference.networking.x-k8s.io` first and migrates to
`inference.networking.k8s.io`. Istio 1.30 rejects the alpha group outright
(`ResolvedRefs=False [InvalidKind]`), so a route captured inside that window
references a pool Istio will not resolve - no pool Service is synthesised, no
ext_proc, and every request through it 500s. It self-corrects, but anything that
snapshots the route can capture the bad state and carry it forward. Wait for
`group == inference.networking.k8s.io` **and** `ResolvedRefs=True` before
capturing.

**Adapter files live in a PVC that a cluster rebuild destroys.** The fixtures
reference `pvc://lora-budget-models/adapter-a*`; without those files vLLM
CrashLoopBackOffs, the pool has no endpoints, and the failure surfaces as the
same 500. Regenerate with `hack/gen-tiny-lora.py` and reload after any rebuild.

All three produce an identical symptom - pool-bound requests 500 with every
status object green - which is worth knowing before diagnosing the next one.

## 14. `alternation`: 320 adapters for zero behaviour change, on Istio

> **320 is a fixture artifact.** It assumes 10-character adapter names. With
> realistic naming the same shape reaches ~188 on Istio and **2** on a stock
> Envoy. See section 25 before quoting it.

> **Read section 16 before acting on this.** Everything below was measured on
> Istio. On kgateway the same shape reaches **six** adapters, because the RE2
> program-size limit is a data-plane setting and Istio is the outlier that raises
> it. The conclusion this section draws about the design docs is retracted there.

The budget is match **count**, not pattern length. So one regex listing the model
names that already exist is *one match* however many adapters there are - the
same constant-match property `nested` has, without renaming anything:

```
publishers/{ns}/models/(model-a|adapter-a1|adapter-a2|…)
```

Measured at every tier:

| tier | result |
|---|---|
| 1 - budget | **297 adapters**, 12 rules, 19 matches, constant |
| 2 - behaviour | **0 of 72** probes move - byte-identical to today |
| 3 - EPP outcomes | **0 of 13** outcomes change |

Rejection at the ceiling is the right one - not a match cap:

```
spec.rules[4].matches[0].headers[0].value: Too long: may not be more than 4096 bytes
```

**Anchoring is exact**, probed 5× each: `model-a` and `adapter-a1` match;
`adapter-a11`, `adapter-a1x`, `adapter-a` and `xmodel-a` all fall through. Only
the listed names match, so it cannot capture a neighbouring service.

**297, not 320.** An earlier hand-built pattern reached 320, but the shipped form
must escape name characters - adapter names are user-controlled - and
`re.escape` turns each hyphen into two bytes. 297 is the number for the safe
form. Name length drives it: roughly 450 with 8-character names, ~120 with
32-character ones.

**What it does not fix.** The pattern is rewritten whenever the adapter set
changes, so per-adapter route churn remains. That, and true unboundedness, are
the only things `nested` buys over it.

### Why this was nearly missed

Both design docs propose nested naming *specifically as the alternative to* an
alternation, and reject the alternation explicitly:

> nest adapter served names under the base … and use a single fixed prefix
> regex. ~40 characters, constant size, well under the default RE2 program-size
> limit - **unlike an alternation, which is not**.
> - `llmisvc-httproute-phased-plan.md:264`

That premise is false here. `re2.max_program_size.error_level` is **32768** on
Istio (section 9), not the assumed 100, and the binding constraint turns out to
be the CRD's cap on a header match value - which lands at 297, not two.

Worth recording as a process point, not just a technical one: the RE2 figure was
measured days before `nested` was promoted from the docs' fallback to this
spike's headline option, and the rejection that `nested` rested on was never
revisited in light of it. A disproven premise invalidates the conclusions built
on it, including the ones already adopted.

## 15. Two LLMISVCs with the same adapter name shadow each other

`fullyQualifiedModelName` is `publishers/{ns}/models/{name}` with **no service
name in it** (`router_discovery_filter.go:35`), so two services in a namespace
that each define an adapter called `sql-adapter` both generate a route matching
`publishers/{ns}/models/sql-adapter`.

Measured with `svc-a` and `svc-b` both given `shared-adapter`: **every** request
carrying that header went to `svc-a`, 6/6. `svc-a`'s route was created 2 seconds
earlier, which is exactly Gateway API's documented tie-break - oldest route wins.
`svc-b`'s own adapter is unreachable by name.

**kserve does detect this.** `findModelNameCollisions`
(`router_validation.go:278`) covers adapter names, and the controller raises a
`ModelNameCollision` warning Event:

> model name "model-a" overlaps with svc-b in namespace lora-budget; shared
> publisher paths and model-routing headers cause the gateway to shadow one
> service.

*Correction to an earlier reading in this investigation:* the first pass reported
"nothing objects", which was wrong - it checked CR **conditions** and the
warning is an **Event**. Detection was added in kserve#5800 and works.

What survives is a message bug, filed as [#284]: the event always formats
`Spec.Model.Name`, but `findModelNameCollisions` returns *peer service names*
rather than the overlapping *model names*, so an adapter collision names the base
model. Here it said `"model-a"` when the actual overlap was `shared-adapter` - and `model-a` overlaps with nothing. It fires correctly and points at the wrong
thing, which is how a real signal gets dismissed as spurious.

[#284]: https://github.com/bartoszmajsak/work-items/issues/284

## 16. The second data plane: `alternation` does not survive it

> **Read section 21 before acting on this.** A third implementation (Envoy
> Gateway) raises the limit as Istio does, so kgateway is the outlier rather than
> Istio. The risk this section identifies is real; the attribution in it is not.

Sections 9 and 14 were measured on Istio only. Installing kgateway v2.1.1 beside
it - separate GatewayClass, separate Gateway, same cluster, same patterns -
produced one result that transfers and one that reverses section 14.

`probe-dataplane.sh` runs the anchoring probes against both;
`hack/render-scale-route.py` builds a full-size alternation on either.

### What transfers: full-match semantics

Gateway API does not specify whether a `RegularExpression` header match is a full
match or a partial one, and everything in sections 9 and 14 depends on it. If a
data plane matched partially, a pattern listing `adapter-a1` would also match
`evil/adapter-a1/tail`, and the shape would be a tenancy bug rather than an
optimisation.

All **11 of 11** probes agree between Istio and kgateway (`golden/dataplane.tsv`):
exact names hit; suffix (`adapter-a2x`), prefix (`xadapter-a2`), embedded
(`evil/adapter-a2/tail`) and leading (`other/publishers/.../adapter-a2`) all miss;
`model-b(/.*)?` covers `model-b` and `model-b/adapters/x` but not
`model-b-instruct` or `evil/model-b/tail`.

### What does not transfer: how far the pattern can grow

Envoy refuses to compile a regex whose **RE2 program size** exceeds a configured
limit. That limit is a data-plane setting:

| data plane | `re2.max_program_size.error_level` | what binds the alternation |
|---|---|---|
| Istio 1.30.3 | 32768 | the CRD's 4096-byte header value cap |
| kgateway 2.1.1 | unset, so Envoy's default of **100** | RE2 program size |

Measured with names that do **not** share a prefix (`golden/dataplane-ceiling.tsv`):

| adapters | pattern bytes | RE2 program size | programs on kgateway |
|---|---|---|---|
| 5 | 90 | under 100 | yes |
| 6 | 100 | under 100 | yes |
| 7 | 110 | **106** | no |
| 8 | 120 | 115 | no |
| 9 | 130 | 124 | no |

**Six adapters. Fewer than the seven we have today.** Verbatim:

```
gRPC config for RouteConfiguration rejected: RE2 program size of 106 >
max program size of 100 set for the error level threshold.
```

### The synthetic-name trap

With the generated names the rest of this spike uses - `adapter-a1`,
`adapter-a2`, ... - kgateway reaches **220**, because RE2 factors the shared
prefix at compile time and 221 alternatives collapse to nearly one branch. Real
adapter names do not rhyme. Benchmarking with generated names would have put a
number in this document that is **35 times** too high.

That also rules out "factor the alternation into a trie" as an optimisation: it
would be tuning against the benchmark's naming rather than any deployment's.

### It fails silently too, one layer lower

The HTTPRoute reports `Accepted=True` and `ResolvedRefs=True` - the apiserver is
satisfied, the pattern is well under 4096 bytes. Envoy NACKs the whole
RouteConfiguration over xDS and keeps serving the last good config, so existing
adapters keep working and the new one is invisible. Same failure shape as the CEL
rejection in section 1, one layer further down, with even less to look at. A
pre-flight check therefore has to count **program size**, not just matches and
bytes.

### Correction to section 14

Section 14 recorded the design docs' RE2 objection as a mistake on their part.
That was wrong, and this is the retraction. The objection is correct for any data
plane running Envoy's default; what section 14 measured was Istio's raised limit,
and it generalised a fact about one data plane into a claim about the option.

`nested`'s pattern is 44 characters regardless of adapter count, so no
program-size limit reaches it. It programmed and routed identically on both
implementations. That is the property the docs were arguing for.

The limit is a knob - a platform that owns its gateway can raise it, and
OpenShift AI ships Istio where it already is - so the honest conclusion is that
`alternation` is a good answer for an Istio-only product and a bad one upstream.

## 17. The regex costs nothing measurable at request time

Separate question from whether it compiles. `probe-regex-cost.sh`.

The obvious experiment fails: comparing max-throughput QPS across shapes
(`probe-latency.sh`, `golden/latency.tsv`) gave figures that are not monotonic in
pattern size - `alternation@150` looked 32% below the floor while
`alternation@297` looked 8% below. That is a laptop, not a measurement. Kept in
the repo because the failure is instructive.

The amplified version forces a known number of header evaluations that all miss,
then lands every configuration on the same terminal rule. Configurations rotate
position each rep so warm-up drift cannot alias onto config order, and the
estimator is the **minimum** p50 across 8 reps rather than the median, because
interference only ever adds time.

| matcher | pattern bytes | evaluations | p50 min (ms) | vs floor | per evaluation |
|---|---|---|---|---|---|
| regex | 4091 | 0 | 1.4834 | floor | - |
| regex | 4091 | 8 | 1.4706 | -12.8 us | - |
| regex | 4091 | 40 | 1.4759 | -7.5 us | - |
| regex | 41 | 120 | 1.4877 | +4.3 us | 0.036 us |
| regex | 682 | 120 | 1.4821 | -1.3 us | - |
| regex | 2033 | 120 | 1.4860 | +2.6 us | 0.022 us |
| regex | 4091 | 120 | 1.5008 | +17.4 us | 0.145 us |
| exact | - | 120 | 1.4800 | -3.4 us | - |

Four configurations measure *faster* than doing no evaluations at all, which is
impossible and is the point: the effect is below what this rig resolves. The
largest positive reading, **0.145 us per evaluation**, is an upper bound rather
than a cost, and the shipped shape performs **one** evaluation per request.
Exact matching at the same depth is indistinguishable from regex.

The mechanism is why this extrapolates: RE2 compiles to a DFA, so match cost is
O(length of the *input*), and the input is a 45-byte header value however many
alternatives the pattern lists. Pattern size costs compile time once and memory -
which is exactly what the program-size limit in section 16 exists to bound.

## 18. Writing the pattern: escaping, ordering, and what not to optimise

Every byte of the pattern is an adapter not served, because the binding limit is
the 4096-byte cap on a header match value. Three things are worth changing and
two are traps.

### Escape only what RE2 needs: 297 -> 320

The shipped form runs each name through Python's `re.escape`, which escapes `-`
along with the real metacharacters. RE2 does not need it: `-` is only special
inside a character class. Kubernetes object names are DNS-1123, so the alphabet
is `[a-z0-9.-]` and `.` is the only member that means anything to a regex.

```
re.escape (shipped)    297 adapters   4091 bytes    adapter\-a1
minimal escaping       320 adapters   4092 bytes    adapter-a1
```

`hack/regex-forms.py` computes both. That is 23 more adapters for one byte per
hyphen, with a strict allowlist and a fall back to full escaping for any name
outside it, so nothing user-controlled reaches the pattern unescaped.

This also settles the 297-vs-320 discrepancy earlier in this document. Both
numbers are right: 320 is the minimal-escape form, 297 is what `re.escape`
leaves. The earlier note calling 297 "the number for the safe form" was too
pessimistic - the minimal form is equally safe and was simply not tested then.

### Name length dominates everything

The ceiling is not really a number, it is a function of how long adapter names
are. Measured with minimal escaping:

| mean name length | adapters |
|---|---|
| 8 | 450 |
| 12 | 312 |
| 16 | 238 |
| 24 | 162 |
| 32 | 122 |
| 48 | 82 |

Quote 320 with the caveat, or quote "roughly 100 to 450 depending on naming".
A single headline number invites someone to design against it.

### Sorting: already done, retracted as a recommendation

An earlier draft recommended sorting the adapter names so the pattern is a
function of the *set* rather than the sequence, avoiding an Envoy reprogram when
someone merely re-orders their YAML.

**kserve already does this.** `expandLoRAAdapterMatches` sorts adapters by name
before generating matches (`config_merge.go`, added in kserve#5822). Verified
live: patching `svc-a` with the adapters listed as `a2, a1` and then `a3, a1, a2`
produced route matches in sorted order both times.

Any alternation built on that function inherits the sort, so there is nothing to
fix. Recording it because recommending work that is already merged is worse than
not recommending it.

### Chunking, which also happens to fix the kgateway ceiling

The alternation uses 19 of the route's 128 matches. Spending the spare budget on
several patterns per path instead of one raises the ceiling proportionally.
Bounded by 128 matches per route and 16 rules, `hack/regex-forms.py` computes a
maximum of **13 chunks per path**, so roughly **3861 adapters** on Istio with no
naming change at all.

It is worth noting that this is the one thing that would make `alternation`
portable, because RE2 program size is per-pattern: 13 chunks of six names each is
78 adapters on kgateway, where one pattern gets six. **Not measured** - the
arithmetic is sound but nothing in this spike ran it, and the interaction with
match ordering across chunks is exactly the kind of thing that needs a probe
rather than a calculation.

Either way, do not build it now. It costs 13 patterns to read instead of one,
with split points that carry no meaning, and both `nested` and a plain
`split-noslash` are simpler answers to the question it solves.

### Two traps

**Trie factoring.** `adapter-a1|adapter-a2|...` compresses beautifully to
`adapter-a(1|2|...)`, and the measured ceiling would jump. It is a mirage: the
synthetic names this spike uses share a prefix precisely because they are
generated, and real adapter names do not. Optimising against the benchmark's
naming would inflate the published number without helping any real deployment.

**Trying to make 4KB of regex readable.** It cannot be done. RE2 has no
free-spacing mode - tested in section 19, Envoy answers `invalid perl operator:
(?x` and drops the whole RouteConfiguration - so the pattern is one unbroken line
in `kubectl get httproute -o yaml` whatever we do. The fix
is not to prettify an artifact nobody should be reading. It is to make reading it
unnecessary: the adapter list already lives in the CR spec, and what is missing is
a pre-flight count check so that exceeding the budget produces a condition naming
the adapter that did not fit, instead of a raw CEL string about
`spec.rules[4].matches[0].headers[0].value`.

### `http.spec` cannot deliver an alternation without a code change

`spec.router.route.http.spec` lets you hand the controller a custom HTTPRoute
skeleton, and `expectedHTTPRoute` copies it verbatim and then runs
`expandLoRAAdapterMatches` over it (`router.go:249`). That is genuinely useful:
the Exact-based candidate shapes (`split`, `split-noslash`, `prefix`,
`collapse`) can be produced by the **real controller** this way, rather than
synthesised, because expansion runs on whatever skeleton it is given.

It does not work for `alternation`. `isModelBasedRoutingMatch` tests only the
header *name*, never the match *type*
(`config_merge.go`), so a `RegularExpression` model-routing match is treated as
expandable: the controller appends one copy per adapter, overwriting `Value` with
a literal while leaving `Type: RegularExpression` in place. The alternation would
be defeated by the very matches it exists to replace.

So adopting `alternation` needs a controller change - skip expansion when the
match type is `RegularExpression` - and cannot be done by configuration alone.
Worth knowing before anyone tries it as a workaround. The same code is arguably
wrong on its own terms: it produces regex-typed matches holding literal values,
which work only because a literal is a valid regex that matches itself.

## 19. Living with the route: diffs, greppability, and an inversion

Section 18 treated the pattern as a byte budget. This is the other half: an
HTTPRoute is reviewed in pull requests, `kubectl diff`ed before apply, and
grepped when routing does not work. None of those operations appear in a ceiling
table and they are what decides whether a shape is pleasant to own.

`hack/diff-shapes.py` measures adding **one** adapter to a service that already
has 100, using realistic names rather than generated ones.

| shape | lines + | lines - | bytes rewritten | longest line | new name legible in the diff? |
|---|---|---|---|---|---|
| `current` | 56 | 0 | 1,420 | 59 | yes |
| `alternation` | 8 | 8 | **23,032** | **1,445** | no, buried mid-line |
| `nested` | **0** | **0** | **0** | 58 | absent entirely |

And the question an operator actually asks - *is `sql-coder-v2` routable?* -
answered from the route object alone:

| shape | answer |
|---|---|
| `current` | yes: 8 lines, each readable |
| `alternation` | grep matches, and hands back a 1,445-byte line |
| `nested` | **no: the name never appears in the route at all** |

### The inversion

These two tables are the same axis read in opposite directions. **The more
constant the route, the less it tells you.** Route churn and route
informativeness are not independent properties to be optimised separately; they
are the same property.

- `current` churns the most and is the most legible. Adding an adapter is 56
  readable lines and the name appears eight times. This is a real cost of moving
  away from it, and no ceiling table shows it.
- `alternation` is the worst of both. It rewrites 23KB for one adapter *and*
  buries the name mid-line. It gets the churn of the flat form with the opacity
  of the regex form.
- `nested` has a perfect diff - adding an adapter does not touch the route at
  all - and pays for it by making the route opaque. The route stops being the
  place you can learn which adapters exist.

### What follows from it

Under `nested`, a status field listing routable adapters stops being a
nice-to-have and becomes **required**, because nothing else can answer the
question. The route object no longer knows. That is not an argument against
nesting; it is a line item that belongs in its cost alongside the naming change,
and it was missing from section 11's decision brief.

Sorting the names (section 18) helps stability but not this: the alternation's
line is rewritten in full either way.

### Free-spacing mode does not exist in RE2

Section 18 asserted that a long pattern cannot be broken across readable lines.
Now tested rather than asserted - Istio, verbatim:

```
rejected: invalid perl operator: (?x
```

RE2 supports `i`, `m`, `s` and `U`, not `x`. A `(?x)` pattern takes the whole
RouteConfiguration down with it, which is the same silent-failure shape as
section 16: route `Accepted=True`, proxy serving stale config.

So there is no way to make 4KB of regex readable in place, and the only real
mitigation is to make reading it unnecessary.

## 20. Provenance: what is the controller and what is a replica

A fair question about every number above: is it the real kserve controller
reconciling a real `LLMInferenceService`, or a hand-built route standing in for
one? It is both, in different places, and the distinction changes how much weight
a number carries.

| number | produced by | real controller |
|---|---|---|
| the 12-rule route shape | `capture-routes.sh`, captured live | yes |
| **the 7-adapter ceiling** | CR patched, controller reconciles, apiserver refuses | yes |
| 72 routing probes | controller-generated route, backendRefs swapped for echo | yes (route), no (backends) |
| 13 EPP outcomes | real InferencePool, real EPP, real vLLM, 2 adapters on a PVC | yes |
| rule-name cross-wire, policy detach | controller routes, 4 services, shared gateway | yes |
| **candidate ceilings** (12, 15, 22, 58, 63, 320) | `probe-ceiling.sh` synthesis, validated by the apiserver | **no** |
| latency, RE2 program size, anchoring | hand-built routes, echo backends | **no** (measuring Envoy) |

The candidate ceilings cannot come from the controller: kserve does not implement
`split`, `alternation` or `nested`, so there is nothing to ask. Synthesis is
unavoidable. What is avoidable is trusting it blind.

### The synthesis is faithful, checked at four points

`probe-ceiling.sh`'s `current` renderer, compared against what the controller
actually generated at the same adapter count:

| adapters | controller rules/matches/max | synthesised | agree |
|---|---|---|---|
| 2 | 12 / 37 / 24 | 12 / 37 / 24 | exact |
| 4 | 12 / 55 / 40 | 12 / 55 / 40 | exact |
| 6 | 12 / 73 / 56 | 12 / 73 / 56 | exact |
| 7 | 12 / 82 / 64 | 12 / 82 / 64 | exact |
| 8 | 12 / 82 / 64 **stuck** | 12 / 91 / 72 | route refused |

So the linear law the candidate ceilings extrapolate from is verified against
real controller output rather than assumed. Rule *names* differ - synthesis says
`name-v1-completions` where the controller says `v1-completions-path` - which
affects no budget, and every name-related finding (section 7, section 12) was
measured on controller-generated routes rather than these.

The row at eight adapters is section 1 reproduced live: CR carries eight
adapters, controller logs `Too many: 72: must have at most 64 items`, CR goes
`Ready=False`, and the HTTPRoute sits at seven still reporting `Accepted=True`
and serving traffic.

**What this does not make real.** No shape other than `current` has ever been
emitted by kserve. Every candidate ceiling is what the apiserver accepts for a
route of that shape, not what the controller would produce if someone wrote it. A
real implementation could add matches this synthesis does not model, and the
ceiling would drop. These are upper bounds on a faithful skeleton, not
predictions about a patch nobody has written.

### Correction to #279, and to how this document stated it

Re-running the pruning case against the controller narrows it considerably.
**Reducing** the adapter list prunes correctly: 8 adapters down to 3 takes the
rule from 64 matches to 32, and down to 1 takes it to 16, live. The bug is
specifically **clearing `spec.model.lora` entirely** - the route then keeps the
last adapter's matches, naming something that no longer exists, with
`HTTPRoutesReady=True`.

Section 8 stated this correctly ("removing *all* LoRA adapters", "it is
remove-only"). The decision report generalised it into "removing adapters never
shrinks the route" and attached a 7-to-3 measurement that does not hold. Fixed
there. Worth checking the filed issue says the narrow thing too.

The consequence for the recommendation is unchanged - the pre-flight check is
what actually matters, and it is needed either way - but "the budget is sticky"
was doing more work in the argument than the evidence supports.

## 21. Three data planes: kgateway is the outlier, not Istio

Section 16 concluded that Istio was unusual in raising the RE2 program-size limit,
and that an alternation therefore would not survive elsewhere. Adding a third
implementation shows that was still one data point short.

`re2.max_program_size.error_level`, read from each proxy:

| data plane | value | where |
|---|---|---|
| istio 1.30.3 | **32768** | runtime layer, visible at `/runtime` |
| envoy-gateway 1.6 | **4294967295** | bootstrap `layered_runtime`, i.e. the check is off; `warn_level` 1000 |
| kgateway 2.1.1 | **unset** | so Envoy's compiled-in default of 100 applies |

Measured behaviour agrees. With distinct names, Envoy Gateway programs **300
adapters** (3,532 bytes) without complaint, where kgateway refuses at 7.

So the shape of the conclusion inverts: **two of three implementations raise or
remove the limit, and kgateway alone ships the stock default.** Calling Istio the
outlier was wrong, and it was wrong for the same reason the original section-14
error was wrong - generalising from too few implementations.

What survives unchanged is the *risk*: the limit is a per-deployment setting that
Gateway API does not specify, kserve does not control, and one shipping
implementation leaves at a value the alternation cannot live with. An upstream
default still cannot rely on it. But "alternation is Istio-only" is too strong;
"alternation depends on a data-plane setting that one major implementation gets
wrong" is the accurate version.

### Anchoring transfers everywhere

All **11 of 11** probes agree across Istio, kgateway and Envoy Gateway
(`golden/dataplane.tsv`): exact names hit, and suffix, prefix, embedded and
leading variants all miss, for both the alternation and the nested prefix. Every
implementation full-matches a `RegularExpression` header match, which Gateway API
leaves unspecified. That is the assumption both regex shapes rest on, and it is
now checked three ways.

### Environmental note

Installing a controller that brings new CRD groups leaves already-running
controllers with stale informers. Adding Envoy Gateway (which installs
`gateway.networking.x-k8s.io`) silently stopped kgateway attaching routes -
`status.parents` went empty with nothing logged - until its deployment was
restarted. Worth knowing before concluding anything from a multi-controller
cluster.

### Terminology: control plane vs data plane

An earlier revision of this section used "stock Envoy" as shorthand for "a
control plane that leaves the RE2 default alone". That is misleading, because it
reads as *Envoy Gateway*, which is the opposite of the truth.

Istio, kgateway and Envoy Gateway are **control planes**. All three configure the
same data plane - Envoy. This is not three proxies, it is one proxy configured
three ways, and what differs is which runtime settings each control plane bakes
into the bootstrap. Where the limit matters, the control plane is named rather
than described.

Also worth stating: what was installed is **Envoy Gateway, not the Envoy AI
Gateway addon**. The regex questions do not need InferencePool support so its
absence did not block them, but nothing in this spike exercises GIE on Envoy
Gateway, and the anchoring and ceiling results there say nothing about whether
its inference extension behaves like Istio's or kgateway's.


## 22. The path axis, if adapters ever get one

A fair question: the header rules need a regex to stay constant, so do the path
rules need one too?

**Today, no.** Every path rule keys on the *service* name or the *base model*
name, and neither multiplies by adapter count. Ten of the twelve rules are fixed
at one match each regardless of how many adapters exist. That is exactly why the
seven-adapter ceiling is a header problem and not a path problem.

Confirmed against the captured route: an adapter has **no publisher path at all**.
`/publishers/{ns}/models/adapter-a1/v1/chat/completions` matches nothing in the
service's route and falls through to the neighbour fixture.

### Why it is still worth asking

Section 10 found that on ODH the header family is denied outright, and publisher
paths are the only authorized way to address a *model*. So an adapter has no
authorized path-based address today: it is reachable only via
`/{ns}/{name}/v1/...` with the adapter named in the body, which authorizes as the
*instance* rather than the model. Giving adapters a publisher path is a plausible
consequence of that authorization model, and it would put them on the path axis.

Measured (`hack/render-adapter-paths.py`, `golden/adapter-paths.tsv`):

| shape | max adapters | matches | pattern bytes | binding limit |
|---|---|---|---|---|
| `flat` one PathPrefix per (endpoint, adapter) | **32** | 128 | 63 | route-wide 128 matches |
| `flat-rx` one alternation regex per endpoint | **75** | 4 | 1018 | **1024-byte** path match value |
| `nested` one wildcard-segment regex per endpoint | **unbounded** | 4 | 76 | nothing |

Three things fall out of it.

**The byte cap is four times tighter on paths.** Gateway API sets
`HTTPPathMatch.Value` to MaxLength 1024 and `HTTPHeaderMatch.Value` to 4096. The
alternation trick buys 32 to 75 here, against 7 to 320 on the header axis.

**`PathPrefix` cannot express it.** A prefix match has no wildcard, so
`/publishers/{ns}/models/*/v1/completions` is not sayable. Collapsing adapter
paths *requires* `RegularExpression`, which means the path axis inherits exactly
the RE2 program-size exposure section 21 describes - on kgateway a 1,018-byte
path pattern would be refused just as the header one is.

**Nesting is constant on both axes.** `/publishers/{ns}/models/{base}(/adapters/[^/]+)?{endpoint}`
is 76 bytes whatever the adapter count, because the adapter name sits in a
wildcard segment rather than being enumerated. It is the same property that makes
the nested *header* pattern constant, and it shows up independently on the path
axis.

That last point is the strongest argument for nesting in this document, and it
was not made before: every other shape is linear on both axes, and nesting is the
only one that is constant on both.

## 23. What the model header is for, and why the ceiling is the price of the shared endpoint

Everything above treats the seven-adapter ceiling as a problem to be solved. This
section asks what the rule causing it is *for*.

### Two questions, two mechanisms

kserve registers each adapter with vLLM under two **body-level** names
(`workload_lora.go`): the bare name and the fully qualified one.

```
--lora-modules '{"name":"adapter-a1","path":"/mnt/lora/adapter-a1"}'
               '{"name":"publishers/lora-budget/models/adapter-a1","path":"/mnt/lora/adapter-a1"}'
```

vLLM never sees an HTTP header. Neither does the endpoint picker: it answers
`400 model not found in request body` when the body has no `model`, whatever the
header says. So the **body** is what selects an adapter, always.

The **header** answers a different question: which vLLM. Gateway API cannot route
on a request body, so the gateway needs the model name somewhere it can match.

Measured end to end against real vLLM, two services (`golden/addressing.tsv`):

| path | body `model` | header | served |
|---|---|---|---|
| `/{ns}/{name}/v1/chat/completions` | qualified adapter | none | adapter-a1 |
| `/{ns}/{name}/v1/chat/completions` | bare adapter name | none | adapter-a1 |
| `/publishers/{ns}/models/{base}/v1/...` | qualified adapter | none | adapter-a1 |
| `/v1/chat/completions` | model-a | model-a | model-a (svc-a) |
| `/v1/chat/completions` | model-b | model-b | model-b (svc-b) |
| `/v1/chat/completions` | adapter-a1 | adapter-a1 | adapter-a1 (svc-a) |
| `/v1/chat/completions` | model-a | **none** | **no route** |
| `/v1/chat/completions` | adapter-a1 | **none** | **no route** |
| `/v1/chat/completions` | qualified base | adapter-a1 | model-a |
| `/v1/chat/completions` | adapter-a2 | adapter-a1 | adapter-a2 |
| `/v1/chat/completions` | *absent* | adapter-a1 | 400 |

On a service-scoped path the URL already names the service, so the header is
unnecessary. On the **shared** endpoint the path names nothing and the header is
the only key there is - without it the endpoint does not resolve at all.

The disagreement rows are not a contradiction: the header still *routed* the
request and the body still *chose the adapter* once it arrived. Each did its own
job.

### The per-adapter matches are an index

On the shared endpoint the adapter name is the only thing that says which pool
owns it. Every adapter needs an entry mapping its name to a backend, and that
table is `rules[4]`. It is the lookup that makes one OpenAI-shaped endpoint able
to serve many models - which is what the Gateway API Inference Extension is for,
and what a body-based router exists to populate from the body so ordinary SDK
clients can use it.

That reframes every shape in this document as three ways of writing the same
index:

- `current`, `split`, `collapse` **enumerate** it: one entry per adapter, linear,
  hits a cap.
- `alternation` **compresses** the enumeration into one pattern: still every name,
  just packed, hits a later cap.
- `nested` **removes the need to enumerate**: because the adapter name contains
  its base model name, one prefix identifies the owning pool for every adapter
  that will ever exist.

That is the real reason `nested` is unbounded, and it is a stronger argument than
the byte counts in section 18. It makes the name self-describing about ownership,
so the index collapses from a table of entries into a rule about naming. The same
property is what makes it constant on the path axis (section 22).

### Switching it off removes the endpoint, not the cost

`serving.kserve.io/model-based-routing-enabled: "false"` makes
`stripModelBasedRoutingRules` delete both header rules. Measured on `svc-a` with
two adapters loaded:

| state | rules | matches | scales with adapters | service-scoped path | shared endpoint |
|---|---|---|---|---|---|
| enabled | 12 | 37 | 2 rules | works | works |
| disabled | 10 | 10 | 0 | works | **gone** |

**Correction to an earlier revision of this section.** It presented that table as
"the ceiling is optional, and the cheapest fix was never on the list of shapes".
That was wrong. It read the header as a redundant copy of the body - which it is
on service-scoped paths, and is not on the shared endpoint, where it is the only
routing key and without which nothing resolves.

Switching model-based routing off does not remove the ceiling for free. It removes
the shared endpoint, which is the feature the ceiling is the price of. A real
option where nobody can use that endpoint - on ODH the authorization policy denies
it today (section 10) - but a decision about scope rather than a free win, and the
wrong call the moment a body-based router ships.

### The producer gap is still real

What survives from the earlier reading is narrower and still worth stating: kserve
**consumes** `X-Gateway-Model-Name` but nothing in kserve **produces** it, no
body-based router ships with it, and no OpenAI SDK sets a non-standard routing
header. So the index is built and maintained for an endpoint that, today, only a
hand-crafted client can reach - and on ODH not even that. The rules are not wrong,
they are early, and the ceiling will start costing real traffic at the moment the
producer arrives rather than before it.

## 24. Could a GIE model-level resource carry the index instead?

The index in section 23 is a table of names. Gateway API Inference Extension has a
resource whose whole job is model-level configuration, so it is worth asking
whether the index belongs there rather than in HTTPRoute matches.

The resource is **`InferenceModelRewrite`**
(`inference.networking.x-k8s.io/v1alpha2`, with an `llm-d.ai` mirror; it is the
descendant of the older `InferenceModel`). Its shape:

```yaml
spec:
  poolRef:                       # which InferencePool this applies to
    kind: InferencePool
    name: svc-a-inference-pool
  rules:
    - matches:
        - model:                 # matches the `model` field IN THE JSON BODY
            type: Exact
            value: sql-adapter
      targets:
        - modelRewrite: sql-adapter-v2
          weight: 100
```

The interesting part is `matches[].model`: it matches **the request body**, which
is precisely what HTTPRoute cannot do. That is why the question is a good one.

### It cannot replace the index

`poolRef` is the answer. The resource is scoped **by** a pool, so it applies only
after the request has already reached one. It configures behaviour *within* a
pool; it does not select between pools. The question the ceiling exists to answer -
"which InferencePool owns this adapter name" - is the one thing it cannot answer.

So on the shared endpoint the HTTPRoute still needs a match per adapter, and the
ceiling stands.

### But it does two things that matter a lot to `nested`

**It removes the vLLM-registration half of the nested migration.** Section 11
listed re-registering adapters under nested names as part of the cost, and kserve
currently does dual registration via `--lora-modules`. With a rewrite, the EPP can
translate `llama-3-8b/adapters/sql-adapter` back to `sql-adapter` before vLLM sees
it, so **vLLM registration does not change at all**. The combination is coherent:

- HTTPRoute: one constant prefix match, unbounded, because the nested name
  identifies the owning pool (section 23)
- rewrite CRs: one rule per adapter for the name translation - and **custom
  resources have no 64-match cap**

That moves the per-adapter table out of a capped object into an uncapped one,
which is the thing this whole document has been trying to do.

**It gives back the visibility `nested` loses.** Section 19 found nesting's one
real cost: the adapter name never appears in the route, so nothing answers "is
`sql-adapter` routable?". If each adapter has a rewrite CR, then
`kubectl get inferencemodelrewrite` *is* the answer, and it is a better answer
than grepping a 4KB regex.

It also brings per-adapter **weights**, so canarying between adapter versions
becomes expressible - which no HTTPRoute-match shape in this document can do.

### Measured: inert in this deployment

| check | result |
|---|---|
| CRDs installed | yes, both groups |
| instances in cluster | **0** |
| kserve controller RBAC | has get/list/watch on `inferencemodelrewrites`, `inferencemodels`, `inferenceobjectives` |
| does kserve create any | **no** |
| EPP image | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0` |
| EPP plugins configured | scheduling only: queue, kv-cache, prefix-cache, no-hit-lru, lora-affinity, max-score-picker |
| rewrite honoured | **no** |

Tested directly: created a rewrite mapping `alias-test` to `adapter-a1`, sent
`{"model":"alias-test"}` at the service-scoped path, and vLLM answered
``The model `alias-test` does not exist``. The request passed through the endpoint
picker unchanged, so nothing consumed the resource.

That kserve's controller already holds RBAC for these kinds while creating none of
them says the integration is anticipated rather than absent by decision. Worth
tracking: if the EPP gains rewrite support, the nested option gets materially
cheaper and its one measured drawback goes away.

**Scope of this result.** The EPP here is llm-d's `v0.9.0`. This says nothing
about whether the upstream GIE endpoint picker implements rewrites - only that the
one kserve deploys in this configuration does not.

## 25. Realistic names: the alternation dies at two or three adapters

Every number in this document was measured against the fixture's names -
`lora-budget`, `model-a`, `adapter-a1`. Those are short because they were
convenient to generate, and both binding limits on the alternation are
byte-driven. So the fixture flatters it, and by a lot.

Real names are two to three times longer. `publishers/{namespace}/models/` alone
costs 30 to 45 characters before any model is named, and Envoy's stock RE2
program-size limit is **100**.

### Computed, per naming profile

| profile | mean adapter name | istio (4096 B cap) | stock Envoy (RE2 100) | envoy-gateway |
|---|---|---|---|---|
| spike fixture, `adapter-a1` | 10 chars | 320 | 5 | 320 |
| realistic, `granite-3-1-8b-instruct` in `genai-serving` | 21 chars | **188** | **2** | 188 |
| long namespace, `redhat-ods-applications` | 25 chars | **147** | **1** | 147 |

### Measured, three data planes, realistic profile

`genai-serving` / `granite-3-1-8b-instruct` / `sql-generation`,
`customer-support`, `summarizer-legal`:

| adapters | pattern bytes | istio | kgateway | envoy-gw | kgateway program size |
|---|---|---|---|---|---|
| 2 | 96 | ok | ok | ok | under 100 |
| 3 | 114 | ok | **refused** | ok | **107 > 100** |

Long-namespace profile, kgateway:

| adapters | pattern bytes | kgateway | program size |
|---|---|---|---|
| 1 | 100 | ok | under 100 |
| 2 | 126 | **refused** | **117 > 100** |
| 3 | 151 | **refused** | **139 > 100** |

### What this changes

**"320 adapters" is a fixture artifact.** Quoting it without the naming caveat
overstates the option by a factor of two even on Istio, and by two orders of
magnitude on a stock Envoy.

**On a stock Envoy the alternation is not "bounded", it is unusable.** It fails at
the counts people actually run - two or three adapters - not at some distant
ceiling nobody reaches. Section 21 framed kgateway as tolerable because two of
three implementations raise the limit; with realistic names that framing is too
generous, because on the one that does not, the shape does not work at all.

**It does not change `nested`.** Its pattern is the base model name plus
`(/.*)?`. Longer base model names make it slightly longer - about 60 characters
for `publishers/redhat-ods-applications/models/llama-3-1-8b-instruct(/.*)?` -
and still constant in adapter count, so it stays comfortably under 100 on every
data plane. The gap between the two shapes widens with realistic naming rather
than narrowing.

**It does not change the seven-adapter ceiling.** That one is match *count*, not
bytes, so name length is irrelevant to it. `current`, `split`, `prefix`,
`split-noslash` and `collapse` all keep the ceilings recorded in section 2.

### Note on the fixture

The cluster fixture keeps its short names: renaming the namespace and models would
invalidate every golden file for findings that do not depend on name length, which
is most of them. What was made realistic is the *pattern content*, which is the
only thing the byte count and program size depend on -
`hack/render-scale-route.py realistic|longns`. The header values probed match the
pattern, so the measurement is honest even though the namespace on the cluster is
still `lora-budget`.

---

## Method notes

**The probe set moved the answer.** The first run had 57 probes and one
Responses sub-resource probe. On it, `prefix` moved 2 probes and looked like the
better trade. Adding six probes for `/v1/responses/{id}/cancel`, `/input_items`,
`/v1/messages/batches{,/id}` and arbitrary depth under a pool endpoint took
`prefix` from 2 moved to 8 and reversed the recommendation. The reasoning behind
the wrong call was sound; it ran on an incomplete probe set. Treat the probe set
as the deliverable, not any individual verdict.

**Predictions were written down before each run.** `split` → empty diff,
`split-noslash` → exactly 1 line, `collapse` → the itemised 13. All held on the
probe set that existed at the time. The one prediction that failed - "`/health` through the pool returns 400 from
the EPP" - first appeared to fail because the EPP was never in the path on Istio
1.28.1. Once 1.30.3 put it there, the prediction was **disproven outright**: the
EPP passes bodyless non-inference paths through (section 5b). Reading
`director.go` in isolation missed a parser registry in front of it.

**What the harness deliberately cannot see.** Tier 2 swaps backendRefs for echo
Deployments so destination is observable, which removes the EPP from the path.
That is right for characterizing route *matching* and useless for EPP
behaviour - hence the separate `probe-epp.sh`, which keeps real backendRefs.
