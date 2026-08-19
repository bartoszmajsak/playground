# `llmisvc` HTTPRoute — phased plan

Companion to `llmisvc-httproute-budget.md` (findings and spikes). This is the sequencing.

---

## Design principles

These decide the arguments, so they're stated up front.

1. **Fail at admission, never in the data plane.** An apiserver rejection names the field.
   A data-plane config rejection can drop unrelated routes on a shared gateway. Any option
   that moves a failure from the first category to the second is rejected regardless of the
   ceiling it buys.
2. **The shape is fixed; the endpoint policy is data.** Adding an endpoint must never be a
   template edit. If it is, the shape is wrong.
3. **No implementation-specific features on the default path.** Regex header matching,
   regex path rewrite, and raised Envoy runtime keys may exist as operator-installed
   variants, never as the shipped default.
4. **Every ceiling is computed, not documented.** A limit that lives only in a doc will be
   exceeded.
5. **Never make the pool the path-based default.** On a shared gateway, an unscoped
   `PathPrefix` rule forwards every path under a service's prefix to the pool — including
   whatever the workload exposes that isn't inference traffic, across however many models
   and unrelated services share the gateway. Path-addressed pool endpoints stay an
   explicit, enumerated allowlist; the workload Service stays the catch-all, unchanged
   from today. Endpoint growth is free only through header addressing, which never
   examines the path at all — that pays for new endpoints, not a broadened path match.
6. **The path shape is a cross-repo contract.** `odh-model-controller` derives per-model
   authorization from the URL structure. Anything that changes `/{ns}/{name}` — or routes
   traffic that lacks it — is an authz change in a different repository, not a routing
   tweak.

---

## The dual-controller reality

Two controllers reconcile every `LLMInferenceService` on OpenShift AI:

- **`kserve/kserve`** generates and owns the HTTPRoute — the shape this plan changes.
- **`opendatahub-io/odh-model-controller`** watches those routes and attaches security: a
  Gateway-level AuthPolicy plus a route-level AuthPolicy per service, maintained by its
  own AuthPolicy watcher/store machinery.

Four consequences the plan has to absorb:

1. **Authorization parses the path.** The Gateway AuthPolicy's SubjectAccessReview derives
   namespace and name from `request.path.split("/")[1]` and `[2]` and checks `get` on the
   `llminferenceservices` resource. The `/{ns}/{name}` prefix is load-bearing for
   *security*, not just routing — Phase 1 preserves it, and it is hereby frozen
   (principle 6). Two shapes need verification against the real policy *today*:
   header-addressed requests (root `/v1/...` — no ns/name in the path) and the publisher
   family (`split[1]` = `publishers`, so the SAR receives shifted segments). Until S11
   answers, the header family is not claimable as supported on ODH.
2. **Route lifecycle is coupled across repos.** odh reconciliation has already broken when
   a route vanished under it (RHOAIENG-56131: AuthPolicy targeting a deleted route on
   stop). Phase 3 sharding multiplies the coupling: N routes per service means N
   route-level policies from a controller this plan doesn't release.
3. **The merge chain runs twice.** odh-model-controller reads `LLMInferenceServiceConfig`
   and runs MergeSpec in its own reconciler against a *vendored* kserve. Any Phase 0 /
   Phase 1.5 change to merge semantics or rule generation exists in two builds at two
   versions. The generator and pre-flight must live in importable kserve library code, and
   version skew is a supported state to test, not an accident.
4. **Migration is per-distribution.** Upstream kserve lands a phase; odh rebases; RHOAI
   releases. Phase 1.5 happens once per consumer on its own cadence, and alias rules (if
   chosen in S10) must survive until the *slowest* consumer has migrated.

---

## Phase 0 — Safety net (no behaviour change)

Everything else edits the same generator, so this goes first. Nothing here changes routing.

| Work | Why |
|---|---|
| Build-time generation of the route preset: Go authors `config-llm-router-route.yaml`; YAML stays the shipped, overridable artifact | `{{ range }}` can't emit array elements, so endpoint enumeration is hand-duplicated in three places — but the YAML preset is the backward-compat seam (per-platform shipping, namespace shadowing via `getConfig`, per-service `Route.HTTP.Refs` pinning) and must survive. Generate at `make generate`, diff-checked in CI; first output byte-identical to today's template. |
| **Read limits from the installed HTTPRoute CRD** (`maxItems` on `rules`/`matches`, the CEL total), falling back to vendored constants only if the CRD is unreadable — and saying which in the condition | The cluster's CRDs come from the gateway implementation or platform bundle, not our `go.mod`. Older CRDs enforce **8 matches per rule**; a check against vendored constants passes at 40 matches and the apiserver rejects — the exact late failure this phase exists to prevent, now with a condition asserting the config is valid. (S9) |
| Pre-flight budget check on the merged spec, after expansion and `stripModelBasedRoutingRules`, against the limits above | Turns a late CEL rejection into an early condition naming the rule and the arithmetic. |
| `toJSON` escaping for interpolated model/adapter names | `"` or `\` in a name currently corrupts the document and surfaces as an unmarshal error. |
| Webhook for duplicate `spec.model.name` within a namespace — **audit mode** (condition + event), enforcement deferred to Phase 1.5 | Brownfield clusters may already carry collisions; immediate enforcement bricks updates. Enforcement must precede Phase 2 (where a collision becomes a correctness bug), not Phase 1. |

Removed from this phase: `[name=x]`-keyed merge for `rules`. It changes overlay semantics
for anyone relying on wholesale-replace, so it cannot live in a phase whose exit criterion
is "nothing changed" — it moves to Phase 1.5, still gated **before** merge-append is
extended to `rules` (S4).

**Exit criteria.** No configuration reachable through the merge chain can produce an
HTTPRoute the apiserver rejects **on the cluster's actual CRDs**. Budget numbers — and
which limits they were checked against — are observable in status.

**Blocked on.** Nothing. Start here.

---

## Phase 1 — Collapse the header family; leave the path family alone

The prior draft of this phase proposed a broad `PathPrefix /{ns}/{name}` rule that sent
everything under a service's prefix to the pool by default. **Wrong on a shared
gateway** — it forwards whatever the workload exposes that isn't inference traffic, and
the exposure compounds across however many models and unrelated services share the
listener. Withdrawn. The path family is not touched: it stays exactly the enumerated,
per-endpoint shape the template uses today, with the workload Service as the unscoped
catch-all — which was always the safe direction for a broad default, because the Service
is the workload's own space, not a shared scheduler resource.

The actual ceiling problem was never in the path family. It was `v1-model-routing`
duplicating Exact-path-plus-header matches once per endpoint *and* once per adapter.
Collapsing that one rule to a single header-only match is sufficient by itself, and
introduces no new destination for any request that doesn't already reach the pool today.

Gated on **S1**, narrowed to: does the EPP tolerate the *existing* unscoped header-only
match (already present in today's template as `v1-catch-all-model-routing`) at higher
volume, and does growing the pool-addressable endpoint list past today's 4 introduce
anything new. Not "is the EPP a safe default sink" — nothing is being defaulted to it.

### Target

```go
type endpoint struct {
    Path string // e.g. "/v1/chat/completions" — generator emits this both as a
                // path-addressed pool rule and as coverage under the header rule
}

type endpointPolicy struct {
    PoolEndpoints []endpoint // grows via WP0.1's generator; no exception list,
                              // because nothing is being carved out of a broad default
}
```

Path family, per identity (name-addressed; publisher alias optional — see Reserve),
unchanged in structure from today's template:

```
# one rewrite rule per pool endpoint — the rewrite-per-rule constraint (CEL requires
# exactly one PathPrefix/Exact match on a rule using URLRewrite) is why this can't
# collapse; it was never the source of the adapter ceiling, so it doesn't need to.
PE_i:  Exact /{ns}/{name}{endpoint_i}  → ReplaceFullPath {endpoint_i}  → InferencePool   (i = 1..m)

# unchanged safe default
S_A:   PathPrefix /{ns}/{name}         → ReplacePrefixMatch /          → Service
```

Header family, collapsed to one rule regardless of endpoint count:

```
H:     header == qualified-model-name (no path match)                 → InferencePool
```

`H` has no path scope by necessity, not by choice — a header-addressed client hits the
gateway root, with no `{ns}/{name}` to scope on. Its safety comes from a different
guarantee than the path family's: the header *value* is unique per model (enforced by
the duplicate-`spec.model.name` check, WP0.5), not a URL boundary. This is the existing
GIE/BBR convention and the same shape today's `v1-catch-all-model-routing` already uses
— not a new pattern this phase introduces.

Precedence: `PE_i`'s Exact path always outranks `H`'s implicit `PathPrefix /`, so a
path-addressed request is routed even when BBR has also set the header (S8's
mixed-addressing case, unaffected).

### Budget

```
rules   = m + 1                 (m pool endpoints + 1 Service catch-all; ×2 if the
                                  publisher alias is enabled)
matches = m + 1 + A             (pre-Phase 2 — A drops out entirely after Phase 2)
per-rule max = 1 + A            (H)
```

| | rules | matches | max adapters |
|---|---|---|---|
| today | 12 | 9A + 19 | **7** |
| Phase 1, m=4 (today's set), no alias | 6 | A + 6 | **122** |
| Phase 1, m=4, with publisher alias | 11 | A + 6 | **122** |
| Phase 1, m=13, no alias | 15 | A + 15 | **113** |

The entire win is `H` no longer multiplying by endpoint count. Endpoint growth was never
the adapter ceiling's cause — only `v1-model-routing`'s endpoint × adapter duplication
was. Fixing that one rule is sufficient. `m` now trades directly against *rule* budget,
independent of adapter count, capped near 13–15 without the publisher alias.

### Accommodating the gaps

| Gap | How it's handled |
|---|---|
| New pool-addressable endpoints (`/v1/embeddings`, future) | Add to `PoolEndpoints`, regenerate. One rule (path family); nothing (header family — already endpoint-agnostic). |
| Root-level paths (`/score`, `/rerank`, `/pooling`, `/tokenize`, …) | Header-addressable for free. Path-addressable only if explicitly added to `PoolEndpoints` — a deliberate per-endpoint choice, not automatic, since they sit outside `/{ns}/{name}/v1`. |
| Multipart audio (`/v1/audio/*`) | Path-addressable if added to the list. Not header-addressable — BBR parses JSON. Documented limitation. |
| `GET /v1/models`, `/health`, `/metrics` | Already covered — `S_A` sends anything not in `PoolEndpoints` to the Service, unchanged from today. No exception list, because nothing was inverted. |
| Stateful `GET /v1/responses/{id}` | Path-addressable only, same as today. Header routing can't express it — no model in the request. |
| Root discovery: `GET /v1/models` under header addressing | Still impossible — no body, no header, no match. Unsupported; use path addressing. |
| Mixed addressing | Unchanged: path wins on precedence; body not cross-checked against the pool it lands on (S8). |
| ODH authz for header addressing | Unchanged: root-path requests carry no ns/name for the SAR to parse. Verified by S11. |

**What this correction removes.** No `ServiceExceptions`, no inverted default, no class
of traffic reaching the EPP that today's template doesn't already send there.

### Reserve

Publisher-path alias (`/publishers/{ns}/models/{model}/...`) stays **opt-in**, not
default — a second full copy of the path family for a URL alias, and disabling it by
default roughly doubles how far `m` can grow before the 16-rule cap.

### Note

`S_A` references the workload Service on every configuration regardless of `m`, so the
`Scheduler == nil` backend-swap case in `combineBaseRefsConfig` is exercised on every
configuration — no longer a special case to verify separately.

**Exit criteria.** Adding a pool-addressable endpoint costs one generated rule, not a
template edit in three places. No path rule forwards traffic the workload didn't
explicitly opt into serving through the pool. Ceiling ≥ 100 adapters pre-Phase 2, driven
by `H` alone.

---

## Phase 1.5 — Migration (the original blind spot)

Phase 1 replaces the HTTPRoute atomically, but three things outside the object don't
migrate with it. Each is a silent break, not an error.

| Break | Mechanism | Mitigation |
|---|---|---|
| Kuadrant `sectionName` refs detach | Policies target HTTPRoute **rule names**. Phase 1 renames every rule; an `AuthPolicy` pinned to `v1-model-routing` silently stops applying — for auth, a security regression with no error. | For one release, emit legacy-named alias rules (same match/backend, old names) **or** ship an old→new name mapping plus a pre-upgrade check listing attached policies whose `sectionName` will dangle. Which one, decided by observed behaviour in S10. |
| Keyed merge changes overlay semantics | Overlays that relied on wholesale-replace of `rules` (minimal custom rule sets via `baseRefs`) suddenly get base rules merged in. | Keyed merge lands here, release-noted as a behaviour change, and still strictly **before** merge-append is extended to `rules` (S4). |
| Duplicate-model webhook flips to enforce | Brownfield collisions exist and enforcement would brick updates. | One release of audit-mode conditions/events (Phase 0) first; enforcement flips here, before Phase 2 makes collisions correctness bugs. |

**Exit criteria.** An upgrade of a cluster with attached Kuadrant policies, custom rule
overlays, and a pre-existing model-name collision completes with every break surfaced as a
condition or pre-upgrade report — nothing detaches or changes semantics silently.

**Not all policies are equal here.** odh-model-controller's own AuthPolicies target the
*whole* HTTPRoute and are actively reconciled by its watcher — they survive rule renames
and self-heal. The silent-detach risk is specifically **user-attached** policies pinned to
rule names via `sectionName`. S10 rehearses both kinds, and S11 confirms the odh watcher's
behaviour through the rename.

---

## Phase 2 — Decouple adapters from the route

Gated on **S3**. Adopt GIE's base-model header: BBR resolves adapter → base model via a
ConfigMap and emits `X-Gateway-Base-Model-Name`; the route matches the base model only.

```
matches = 2k + 3        (A drops out entirely)
```

`H` becomes a single Exact match. The adapter count no longer appears in any budget
formula, and per-adapter reconcile churn on the HTTPRoute disappears with it.

**What the controller takes on:** generating and reconciling the mapping ConfigMap
(qualified names on both sides), concurrent writes from multiple LLMISVC reconciles if the
map is per-gateway, and — committed here, not deferred — the unmapped-adapter behaviour:

- **Ordering.** The map entry is written and confirmed propagated to BBR *before* the
  adapter is announced in status/discovery; removal is the reverse. The same
  add-before-remove discipline Phase 3 demands of shards, one level up.
- **Failure mode.** An unmapped adapter 404s at the gateway. We accept that window and
  surface map sync (map generation observed by BBR) in the CR status, rather than adding a
  fallback match on the raw header value — the fallback silently re-imports the `1 + A`
  adapter axis Phase 2 exists to remove.
- **The window is measured, not assumed** — S3 step 5 reproduces it under load.

**Fallback if the BBR build or ConfigMap ownership doesn't work out:** nest adapter served
names under the base (`publishers/{ns}/models/{base}/adapters/{adapter}`) and use a single
fixed prefix regex. ~40 characters, constant size, well under the default RE2 program-size
limit — unlike an alternation, which is not.

**Exit criteria.** Adapter count absent from every budget formula. Ceiling determined only
by the exception list.

---

## Phase 3 — Escalation, on trigger only

Build the *detection* in Phase 0. Build the *response* when a real deployment trips a
trigger, not before.

| Trigger | Condition | Response |
|---|---|---|
| **T1** per-rule matches | `1 + A > 64` (Phase 1 only; unreachable after Phase 2) | Split `H`'s matches across `H-0`, `H-1`, … in the same object. Matches are OR'd and share one backendRef with no filters, so this is semantically identical. Buys up to the route-wide 128. Slice on sorted, content-derived chunks — never index order, which reshuffles every `H-i` on each adapter add and churns SSA. |
| **T2** route-wide matches | `m + 1 + A > 128` | **Shard across HTTPRoutes.** Each shard brings a fresh 128. Reachable only pre-Phase 2 at very high `A`, or an implausibly large `m`. |
| **T3** rule count | `m + 1 > 16` (or `2m + 2 > 16` with the publisher alias) | **Not a sharding problem, and not `H`'s problem.** Stop adding path-addressable pool endpoints — the endpoint is still reachable via header addressing, which doesn't consume rule budget. Only relevant if per-service path-addressability is a hard requirement past ~15 endpoints. |

### The ladder matters

T3 is the one actually worth planning for — it's reachable at ordinary endpoint counts,
not just pathological ones, and its fix is one line of policy ("this endpoint is
header-only") rather than an object. T1's response costs a loop. T2's costs N objects per
service with pruning, ownerRefs, status aggregation across N × parents, and shard-aware
Kuadrant `sectionName` targets. Never reach for T2 while T1 or T3's cheap fix has room.

### If sharding does happen

It is unusually safe in this shape. Every `H` match is keyed by a distinct header value,
so shards are mutually exclusive — no request can match two, and cross-route precedence is
never consulted. That is a property of the shape, not a general guarantee; it holds only
while shards split on header value and not on path.

Requirements if built:
- Deterministic, content-derived shard assignment (hash of the identity), never index-based
  — index packing reshuffles on every insertion.
- Globally unique rule names across shards, so policy `sectionName` refs survive.
- Add-before-remove when an identity moves between shards.
- Label-based prune; ownerRefs only if same-namespace, otherwise finalizer.
- Aggregate status: the CR is not Ready until every shard is Accepted **and** Programmed.
- odh-model-controller must handle N routes per service: one route-level AuthPolicy per
  shard, and no reconcile failure when a shard is pruned (the RHOAIENG-56131 class).
  **Sharding cannot ship from kserve alone** — it is a two-repo feature, which alone
  moves it further down the ladder.

### Honest assessment

**If Phases 1 and 2 land, sharding is never needed.** Phase 1 alone puts the adapter
ceiling above 100 with a rule count independent of adapter count; Phase 2 removes the
adapter axis entirely. The one trigger that's practically reachable (T3, running out of
path-addressable rule slots past ~15 endpoints) has a one-line fix that isn't sharding.
Sharding is reachable only if Phase 2 is blocked *and* a single service exceeds the
adapter ceiling, or if per-service path-addressability is required for more endpoints
than the rule cap allows. Phase 3 exists so those cases have a written answer, not
because either is on the path.

---

## Edge-case register

Small enough not to gate phases; real enough to test.

- **Reserved path tokens.** A namespace named `publishers` (or colliding with `v1`)
  overlaps the two path families. Longest-prefix rescues most shapes, not all. Reject in
  validation.
- **URLRewrite is Extended support, not Core.** The whole shape rests on it. Not a
  regression — today's template uses it too — but the portability claim carries this
  footnote.
- **Header matching is case-sensitive; model names are client-typed.** A casing mismatch
  is a 404 tied to nothing in any log. Consider normalising served names; document either
  way. (S8)
- **BBR fail-open asymmetry.** When BBR skips a body (over buffer limit, non-JSON), the
  identical request succeeds path-addressed and 404s header-addressed. (S8)
- **Mode × m matrix.** `stripModelBasedRoutingRules` toggles `H` on/off; `S_A` always
  references the Service regardless of `m`, so `Scheduler == nil`'s backend swap is
  exercised in every configuration, not a separate cell to verify.

---

## Sequencing

```
Phase 0 (pre-flight gated on S9) ─────────► (no blockers, start now)
   │
   ├── S1 + S8 ──► Phase 1  (collapse H; path family unchanged, no shape gate needed)
   │
   └── S6 ──────► S10 ──► Phase 1.5  (migration: aliases vs pre-upgrade report)
                            │
              S3 ──────────► Phase 2  (BBR base-model; sync window measured)
                            │
              S2 ──────────► (regex variant — operator-installed only, or dropped)
                            │
                       Phase 3  (on trigger only)
```

**S6 is worth answering before Phase 2.** If the supported adapter count is under ~100,
Phase 1 alone clears it and Phase 2 becomes an optimisation rather than a requirement —
which changes how much ConfigMap ownership complexity is worth taking on.

**S2 is on a side branch.** Its most valuable output isn't a ceiling, it's the blast-radius
answer: if a data-plane regex rejection drops more than the offending route, principle 1
kills the regex track permanently and the branch closes.

**S8, S9 and S10 are cheap and front-loaded on purpose.** S9 decides whether the Phase 0
safety net is real on the clusters we actually support; S8 verifies the header-only
match's existing cross-tenant safety property at scale; S10 picks Phase 1.5's mechanism
(alias rules vs pre-upgrade report) from observed behaviour rather than assumption.
S7 (originally: replace enumeration with a policy rule) is downgraded — Phase 1 keeps
enumeration by design — and narrows to picking which endpoints join the core
path-addressable set (`m`) versus staying header-only.

**Every phase ships twice.** kserve upstream first, odh-model-controller rebase second.
S11's coupling checks run before any phase is declared done on OpenShift AI, and shared
logic (generator, pre-flight, merge) is structured as importable kserve library code so
the second shipment is a rebase, not a re-implementation.
