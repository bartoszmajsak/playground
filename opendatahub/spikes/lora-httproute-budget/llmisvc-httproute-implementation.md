# `llmisvc` HTTPRoute — implementation plan, grounded in the reconcilers

Companion to `llmisvc-httproute-phased-plan.md` (design) and
`llmisvc-httproute-budget.md` (findings + spikes). This maps each phase onto the code
that exists in `kserve/kserve` and `opendatahub-io/odh-model-controller`.

Legend: **[real]** = verified symbol/file. **[new]** = to be created (names are
proposals). **[verify]** = existence confirmed, exact location to be checked at
implementation time.

---

## 0. Code map — what exists today

### kserve/kserve (`pkg/controller/v1alpha2/llmisvc`)

| Anchor | Status | Role |
|---|---|---|
| `config/llmisvcconfig/config-llm-router-route.yaml` | [real] | `LLMInferenceServiceConfig` preset holding the 12-rule template under `spec.router.route.http.spec.rules`; deliberately excluded from versioned well-known resolution because it depends on the Gateway API provider. |
| `config_merge.go` — `MergeSpecs` / strategic merge with `LLMInferenceServiceSpec{}` schema | [real] | Layer resolution: well-known presets + user `baseRefs` + CR spec. `gwapiv1` types carry no `patchMergeKey`, so `rules` replaces wholesale today. |
| `config_merge.go` — `ReplaceVariables` | [real] | Marshals the whole config to JSON, runs `text/template`, unmarshals. No JSON escaping of substituted values; `{{ range }}` cannot emit array elements. |
| `config_merge.go` — `expandLoRAAdapterMatches` (around L534) | [real] | Deep-copies every model-routing match per adapter; the growth axis. |
| `config_merge.go` — `stripModelBasedRoutingRules` | [real] | Drops the two header rules when model-based routing is off. |
| `reconcileRouter` — creates/manages the HTTPRoute when `spec.router.route.http` is set (kserve#4525) | [real] | The apply point; where pre-flight and generation hook in. |
| Model-based routing gates + `status.models` (kserve#5579) | [real] | Status surface for served models — the anchor for Phase 2 ordering. |
| Conditions with godoc conventions (kserve#5586) | [real] | Pattern to follow for new conditions. |
| `inferenceservice-config` cached and watched (kserve#5573) | [real] | Pattern for config caching/invalidations. |
| CRD-availability guard: InferencePool reconcile skipped when CRD absent (kserve#5890); `utils.IsCrdAvailable` in the v1beta1 controller | [real] | Existing pattern for cluster-capability discovery. |
| Merge-append machinery: `serving.kserve.io/merge-append-fields` annotation, `ParseFieldPath` / `ParseMergeAppendFieldPaths`, `mergeAnnotatedSpecs` / `mergeSpecsWithAppend` / `concatSequenceFields` | [real] | The in-flight work this plan builds on for keyed rule merge. |
| RBAC generated via `controller-gen rbac paths=./pkg/controller/v1alpha2/llmisvc` → `config/rbac/llmisvc` (Makefile) | [real] | Where new RBAC markers land. |

### opendatahub-io/odh-model-controller

| Anchor | Status | Role |
|---|---|---|
| Gateway-level + route-level AuthPolicy per LLMISVC; Gateway policy SAR parses `request.path.split("/")[1..2]` | [real] | The path-shape security contract. |
| `AuthPolicyStore` (#522), `AuthPolicyMatcher` + authPolicy watcher (#528) | [real] | Discovery/attachment machinery; the seam for multi-route support. |
| `MergeSpec` moved into the main reconciler (#565) + `LLMInferenceServiceConfig` read access (#564) | [real] | The duplicated merge chain. |
| RHOAIENG-56131 fix: AuthPolicy targeting a deleted route on stop (#822) | [real] | The lifecycle-coupling failure class. |

---

## Phase 0 — Safety net

### WP0.1 — One authored source; YAML stays the shipped contract
**Repo:** kserve. **Files:** build-time generator [new] (e.g. `hack/genroutes/`);
`config-llm-router-route.yaml` remains — now a generated, checked-in artifact.

Revised from "move rules to Go at reconcile time": the YAML preset is the backward-compat
and environment seam and must survive. Because the route config is data resolved through
`getConfig` (service namespace first, then system) and gated on `!Route.HTTP.HasRefs()`,
platforms ship different rule content per release without a controller rebuild, operators
shadow it per namespace, and services pin an explicit shape via `Route.HTTP.Refs`.
Provider breakage (GKE rejecting `timeouts` #5311, regex path matches #5319) is fixable
today by editing data; compiled rules would turn every such fix into a controller release.

- Generator emits the preset from the endpoint list + `endpointPolicy` at `make generate`
  — controller-gen idiom, regenerate + `git diff --exit-code` in CI. First PR reproduces
  today's template **byte-identical**: provably a no-op.
- Three-place endpoint enumeration collapses to one edit + regenerate, with a reviewable
  YAML diff.
- Reconcile-time Go keeps only what is inherently per-CR and already lives there:
  `expandLoRAAdapterMatches`, `stripModelBasedRoutingRules`, the backendRef rewrites in
  `combineBaseRefsConfig`, and (new) budget counting — all operating on whatever rules
  the merge produced, preset-authored or user-authored.
- Shape variants (Phase 1's E/P shape, a regex variant for permissive data planes) ship
  as **additional generated presets**, selected by chart/install or per-service
  `Route.HTTP.Refs` — which is also the Phase 1.5 migration vehicle: existing services
  keep the legacy preset explicitly while new ones default to the new shape.

### WP0.2 — Limits read from the installed CRD
**Repo:** kserve. **Files:** `route_limits.go` [new]; RBAC marker
`+kubebuilder:rbac:groups=apiextensions.k8s.io,resources=customresourcedefinitions,verbs=get;list;watch`
on the llmisvc controller (regenerated into `config/rbac/llmisvc`).

- `RouteLimits{MaxRules, MaxMatchesPerRule, MaxTotalMatches, Source}` resolved from the
  installed `httproutes.gateway.networking.k8s.io` CRD schema (`spec.versions[].schema`:
  `maxItems` on `rules`/`matches`; parse the unrolled CEL total or infer 128 by version).
  Follow the kserve#5890 / `IsCrdAvailable` pattern for absence, and the kserve#5573
  caching pattern with a watch on that one CRD name.
- `Source` ∈ {`cluster`, `vendored-fallback`} — carried into every condition message
  (S9 exit criterion).

### WP0.3 — Pre-flight budget check
**Repo:** kserve. **Files:** `route_budget.go` [new]; condition added next to the
existing llmisvc conditions with godoc (kserve#5586 conventions).

- `validateRouteBudget(rules, limits)` runs in `reconcileRouter` after expansion and
  stripping, **before** the SSA apply. Failure → the existing router condition goes
  `False` with reason `RouteBudgetExceeded` and the arithmetic in the message
  ("`v1-model-routing` would have 72 matches with 8 adapters; max 64 (source: cluster
  CRD)"), plus an event, and no apply — the previous route stays serving. **No new
  condition type:** the llmisvc condition set is Knative-style and part of Ready's
  aggregation — adding a type changes Ready semantics for existing CRs on upgrade. A
  budget failure is one more way the router fails, not an orthogonal state.
- Same function exported for the validating webhook path so obvious overruns fail at
  admission of the CR, not first reconcile. Boundary tests enumerate the four cells of
  {model-based routing on/off} × {scheduler nil/non-nil}.

### WP0.4 — `toJSON` escaping in `ReplaceVariables`
**Repo:** kserve. **File:** `config_merge.go` [real].
Register a `toJSON` func in the template FuncMap; switch interpolations of model/adapter
names to it; regression test with `"` `\` and non-ASCII in names.

### WP0.5 — Duplicate `spec.model.name` audit
**Repo:** kserve. Field indexer on `spec.model.name`; on reconcile, list same-namespace
LLMISVCs via the index; collision → condition + event, **no rejection** (enforcement is
Phase 1.5). Kept cheap: index lookup, no extra API calls.

---

## Phase 1 — Shape change

### WP1.1 — Generator collapses the header rule; path family unchanged
**Repo:** kserve. **File:** the build-time generator (WP0.1).
**Design correction:** the originally planned broad `PathPrefix /{ns}/{name}` "pool by
default" rule is withdrawn — unsafe on a shared gateway, since it forwards every path
under a service's prefix to the pool regardless of what the workload actually exposes
there, and the exposure compounds across every model and unrelated service sharing the
listener. The path family stays exactly as enumerated as today (one `URLRewrite` rule per
`PoolEndpoints` entry, unchanged `PathPrefix /{ns}/{name}` catch-all to the Service). The
only structural change: `v1-model-routing` (endpoint × adapter matches) collapses into a
single header-only rule `H`, the same shape `v1-catch-all-model-routing` already uses in
the shipped template. Ships as a **second generated preset** alongside the legacy one,
selected by chart/install default or per-service `Route.HTTP.Refs`.
`stripModelBasedRoutingRules` post-pass becomes "drop `H`"; `S_A`'s reference to the
workload Service means the `Scheduler == nil` backend swap is exercised on every
configuration, not a cell-specific case.

### WP1.2 — `status.router`: the register becomes API
**Repo:** kserve. Structured status block generated from `endpointPolicy`:
route ref(s) plus `rules: [{name, role}]`, where `role` is the semantic key
(`pool-endpoint`, `service-catch-all`, `header-routing`) and `name` is the current
HTTPRouteRule name. One surface serves three needs: the addressability register (which
endpoints are path-addressable vs header-addressable, from S1/S7), human discovery before
authoring a `sectionName` policy, and role→name resolution for controller consumers
(odh's `AuthPolicyMatcher`) so attachment survives renames. Rule names thereby become
documented API with stability guarantees; Phase 1.5 aliases appear here too while they
exist. Builds on the `status.models` surface (kserve#5579); status fields need upstream
API review, so this PR is sliced separately.

### WP1.3 — S1/S7-driven `PoolEndpoints` lands as data
`PoolEndpoints` (the `m` endpoints that get a path-addressed rule) is generator input,
sized by S7's decision and validated against S1's findings — not a controller-flippable
mode. Growing it costs one generated rule per entry; it never re-triggers a shape
change, since the header rule (`H`) already covers every endpoint regardless of `m`.

---

## Phase 1.5 — Migration

### WP1.5.1 — Alias rules or pre-upgrade report (per S10)
**Repo:** kserve emits aliases (a `legacyRuleNames` bool on the generator, one release);
the **detection** of dangling user `sectionName` policies lands in odh-model-controller,
which already lists AuthPolicies via `AuthPolicyStore` — kserve takes no Kuadrant
dependency.

### WP1.5.2 — Keyed merge for `rules`
**Repo:** kserve. Extend the merge-append machinery: `rules` handled via `[name=x]`
element matching (`ParseFieldPath` already supports the syntax) so overlays override by
rule name instead of wholesale replace/append. Release-noted behaviour change; gated on
the existing `serving.kserve.io/merge-append-fields` opt-in so default merges are
untouched. Lands strictly before merge-append is otherwise enabled for `rules` (S4).

### WP1.5.3 — Webhook enforcement flip
`WP0.5` audit → deny, one release after audit ships, before Phase 2.

---

## Phase 2 — BBR base-model mapping

### WP2.1 — Mapping reconciler
**Repo:** kserve. **File:** `reconcile_model_mapping.go` [new] — a child resource of the
LLMISVC reconcile: the BBR ConfigMap entries for this service's base model + adapters
(qualified names both sides), SSA'd with the llmisvc field manager. Per-gateway map ⇒
entries merged across services: SSA field ownership per key, or one CM per service
aggregated by BBR config — decided by S3 step 4.

### WP2.2 — Ordering via `status.models`
Adapter appears in `status.models` (kserve#5579) only after the map generation is
observed by BBR (readiness probe or generation annotation — S3 decides the observable).
Removal reverses. **No CR-wide `RouterModelMappingSynced` condition** — it would flap on
every adapter change. Sync state is carried **per model entry** in `status.models`
(routable/pending), and Ready may aggregate "all declared adapters routable" from there
if required.

**Dynamic LoRA is the forcing case.** Spec-declared adapters ride the reconcile loop;
adapters loaded at runtime via vLLM's load/unload API change the served set with **no CR
update**, so nothing reconciles the map and BBR goes stale — the runtime serves a model
the gateway 404s. Decide before this WP: either the CR is the source of truth (runtime
load API not exposed through the gateway), or the map gains a second writer watching the
runtime — and two writers to one ConfigMap is the concurrency case S3 step 4 scopes.

### WP2.3 — `H` collapses to one Exact match
`route_rules.go` emits the base-model header match; `expandLoRAAdapterMatches` is
deleted (its tests move to the mapping reconciler).

---

## Phase 3 — Triggered only

Detection ships in WP0.3 (`RouterRouteBudgetExceeded` distinguishes T1/T2/T3). The T1
splitter (`H-i` slices, sorted content-derived chunks) is a contained change in
`route_rules.go`. T3 (path-family rule count) has a non-sharding mitigation: stop adding
an endpoint to `PoolEndpoints`, leave it header-only — a one-line policy change, not a
code change. T2 sharding is **not scheduled**: it requires a route-set abstraction
in `reconcileRouter` (deterministic names, labels, prune, aggregated status) *and*
multi-route support in odh's `AuthPolicyMatcher` — a two-repo feature per the design doc.

---

## odh-model-controller work (S11-driven)

| WP | Change | Anchor |
|---|---|---|
| O1 | Publisher-family SAR: extend the Gateway AuthPolicy CEL to recognise `/publishers/{ns}/models/{model}` (segments shifted) | Gateway AuthPolicy template [real] |
| O2 | Header-family authz decision: either an authz rule keyed on the routing header (post-BBR) or an explicit documented deny for root-path addressing | same |
| O3 | Rename resilience: confirm/extend `AuthPolicyMatcher` + watcher through the Phase 1 route replacement; measure the re-reconcile window | #528 [real] |
| O4 | Multi-route readiness (pre-req for any future T2): matcher creates one route-level policy per matched route; prune on route deletion (RHOAIENG-56131 class) | #822, #528 [real] |
| O5 | Merge convergence: replace the local `MergeSpec` copy with the kserve llmisvc library import once WP0.1 lands, so both controllers generate from one implementation | #565 [real] |

---

## Test matrix

| Layer | What | Where |
|---|---|---|
| Unit / golden | Generator bit-identity (WP0.1), budget arithmetic per {mode × scheduler} cell, `toJSON`, keyed merge | llmisvc package tests |
| envtest | Pre-flight vs real CRD: run twice, against current Gateway API CRDs and against an old-cap CRD fixture (S9's reproduction as a permanent regression test) | llmisvc envtest suite |
| e2e | S1/S8 probe set as conformance: known endpoints, unknown paths, large bodies, casing, mixed addressing | kserve llmisvc e2e |
| e2e (ODH) | S11 authz truth table per addressing family; rename through the odh watcher | odh-model-controller e2e |
| Upgrade | Phase 1.5 rehearsal: attached policies + custom overlay + collision, before/after | per-distro pipelines |

## Sequencing constraint

WP0.1 is still the keystone, but the invariant is **one authored source, many generated
presets** — not "rules live in Go". WP0.3 counts merged rules regardless of who authored
them; WP1.1 and WP2.3 are new generated preset variants plus post-processor changes; the
T1 splitter stays a reconcile-time post-pass (it depends on per-CR adapter count); O5 is
unchanged. WP0.1 lands first as a byte-identical regeneration, and later phases edit the
endpoint list and generator, then regenerate — every shape change arrives as a reviewable
YAML diff.
