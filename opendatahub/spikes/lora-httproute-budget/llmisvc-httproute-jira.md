# JIRA drafts — llmisvc HTTPRoute rule/match budget

Paste each section as one issue. Epic first, then the Phase 0 tickets (ready to work
now), then stub child-epics for later phases so the roadmap is visible from the epic.

---

## EPIC: HTTPRoute rule/match budget for the llmisvc router

**Issue Type:** Epic
**Components:** kserve/llmisvc, odh-model-controller
**Labels:** `gateway-api`, `llmisvc`, `router`, `technical-debt`

### Summary
Remove the hard ceiling on LoRA adapters and API endpoints per `LLMInferenceService`,
caused by Gateway API HTTPRoute match limits, without moving the failure from admission
time (safe) to the data plane (unsafe) or introducing a controller-owned encoding that
depends on cluster settings we don't control.

### Problem
The generated HTTPRoute for `spec.router.route.http` has a fixed match budget (16 rules,
64 matches/rule, 128 matches total on the standard channel — verified against
`apis/v1/httproute_types.go`). `expandLoRAAdapterMatches`
(`pkg/controller/v1alpha2/llmisvc/config_merge.go`) duplicates 8 matches per adapter, so:

- **Today's ceiling is 7 LoRA adapters** per service before the apiserver rejects the
  route (`v1-model-routing` exceeds 64 matches at adapter 8).
- Adding any of the currently-unsupported endpoints (embeddings, rerank, score,
  count_tokens) lowers that ceiling further — 3 adapters once 8 endpoints are enumerated
  the same way.
- Failure surfaces as a raw CEL rejection at HTTPRoute apply, late in reconcile, so a
  service can work in staging and break in production purely on adapter count.

### Goal
1. Raise the practical ceiling to the point adapter count stops being the constraint
   (target: 100+ adapters via header-only rule collapse; unbounded via BBR base-model
   routing — achieved without broadening any path match, see design correction below).
2. Turn any remaining budget as a pre-flight condition at reconcile time, never a
   surprise at apply time.
3. Do it without regex header matching on the default path — Envoy's default
   `re2.max_program_size.error_level` (100) caps a name alternation at ~2 adapters and
   fails in the data plane, not at admission, which is a worse failure mode than today's.
4. Preserve backward compatibility: the route shape stays data
   (`LLMInferenceServiceConfig` presets resolved via `getConfig`), not compiled Go, so
   platforms keep shipping/overriding it per install without a controller rebuild.
5. Account for `opendatahub-io/odh-model-controller`, which reconciles AuthPolicies
   against the same HTTPRoute and derives authorization from the URL path shape
   (`request.path.split("/")[1..2]`) — any path-shape change is a cross-repo security
   change, not just a routing one.

### Non-goals (this epic)
- Sharding rules across multiple HTTPRoute objects. Analysis shows it's unreachable if
  the rule-shape change (Phase 1) and BBR mapping (Phase 2) land — tracked as a
  contingency, not scheduled work.
- Raising Envoy's regex program-size limit or shipping any config that depends on an
  operator having done so.
- Any "route everything under a service's path prefix to the pool by default" shape.
  Rejected on design review: unsafe on a gateway shared by many models and other
  services, since it forwards whatever the workload exposes under that prefix —
  including non-inference paths — to the EPP. The path family stays a per-endpoint
  allowlist; only the header-only routing rule collapses (see SPIKE-1).

### Reference docs
- Findings + spike catalogue: `llmisvc-httproute-budget.md`
- Phased design + principles: `llmisvc-httproute-phased-plan.md`
- Reconciler-grounded implementation plan: `llmisvc-httproute-implementation.md`

### Definition of Done (epic)
- No configuration reachable through the merge chain produces an HTTPRoute the apiserver
  rejects; the failure (if any) is a status condition with the exact arithmetic.
- Adding a new OpenAI/Anthropic-compatible endpoint requires editing one endpoint list and
  regenerating, not touching three template locations.
- The default adapter ceiling is documented, tested, and enforced.
- odh-model-controller's authz behavior for every addressing family (path, publisher,
  header) is verified and documented, not assumed.

---

## SPIKE-1: Header-only routing match at scale, and endpoint-list growth

**Issue Type:** Spike
**Priority:** Highest (validates the Phase 1 collapse)
**Components:** kserve/llmisvc
**Labels:** `spike`, `gateway-api`, `epp`

### Summary
Confirm that collapsing `v1-model-routing` (today's per-endpoint × per-adapter header
matches) into a single header-only match — the same shape `v1-catch-all-model-routing`
already uses in the shipped template — is safe under adversarial input and at higher
adapter counts, and determine which candidate endpoints belong in the path-addressed
allowlist (`PoolEndpoints`) versus staying header-only.

### Why
**Design correction:** an earlier draft of this epic proposed making the pool the
default destination for every path under a service's prefix, exempting only a short
list. That's withdrawn — on a gateway shared by many models and other services, it would
forward whatever the workload exposes under that prefix, including non-inference paths,
to the EPP, and the exposure compounds across every service on the listener. The path
family is **not changing** — it stays exactly the one-rule-per-endpoint shape it is
today, with the workload Service as the unscoped catch-all (safe, because the Service is
the workload's own space, not a shared scheduler resource). The only structural change is
collapsing the header-only rule, which removes the endpoint × adapter multiplication
without touching how any path is matched.

### Acceptance criteria / steps
- [ ] Deploy a single-node LLMISVC with scheduler enabled; probe the pool directly
      (bypassing the route) and through the full chain (gateway + BBR + EPP).
- [ ] Known-endpoint probes, both header-addressed (hitting the collapsed rule) and
      path-addressed for each `PoolEndpoints` candidate: `/v1/models`, `/health`,
      `/v1/embeddings`, `/v1/rerank`, `/v1/score`, `/pooling`, `/tokenize`,
      `/v1/messages/count_tokens`. Record status, latency delta, EPP behavior.
- [ ] **Cross-tenant collision probe:** with two or more LLMISVCs and an unrelated
      non-LLM HTTPRoute on the same shared hostname, send a request intended for the
      unrelated route while carrying a header value equal to one LLMISVC's qualified
      model name. Confirm nothing outside that model's own traffic gets captured — this
      is the property the header-only match's safety actually depends on (header-value
      uniqueness, not a URL boundary).
- [ ] Body-shape probes on header-addressed traffic: bodyless POST, `text/plain`,
      malformed JSON, multipart audio upload, wrong-case model name, unknown model name.
- [ ] Large-body probes: `/v1/embeddings` at 1MB / 10MB / 64MB against the header rule —
      find where ext_proc's buffering limit bites and whether it fails open (falls
      through to the Service catch-all), fails closed, or stalls.
- [ ] Repeat against every EPP build we support (upstream GIE + any downstream variant).

### Outcome / exit
- [ ] Header-only match's safety confirmed under adversarial input, or a specific
      mitigation identified.
- [ ] Each candidate endpoint classified path-addressable / header-addressable / both,
      feeding the `PoolEndpoints` list and `status.router` addressability register.
- [ ] No scenario found where the header rule's lack of path scope, by itself, misroutes
      traffic to the wrong service.

---

## SPIKE-2: Installed HTTPRoute CRD limits vs vendored constants

**Issue Type:** Spike
**Priority:** High (blocks WP0.2/WP0.3 correctness)
**Components:** kserve/llmisvc
**Labels:** `spike`, `gateway-api`, `validation`

### Summary
Prove that a pre-flight budget check hardcoded to today's Gateway API limits (16 rules /
64 matches-per-rule / 128 total) can silently pass on a cluster running older CRDs, and
verify the fix (read limits from the installed CRD schema) closes it.

### Why
Older Gateway API CRDs capped matches-per-rule at 8, not 64. The CRDs on a cluster come
from the gateway implementation or platform bundle — not from our `go.mod`. A pre-flight
check against vendored constants would wrongly pass a spec the real apiserver rejects,
recreating exactly the late-failure problem this epic exists to fix.

### Acceptance criteria / steps
- [ ] On a kind cluster, install a Gateway API release whose HTTPRoute CRD enforces the
      old 8-match cap; apply a 40-match rule directly; capture the apiserver error.
- [ ] Run a pre-flight check hardcoded to 64/128 against the same spec — confirm it
      wrongly passes (this is the bug reproduction).
- [ ] Implement CRD-schema discovery (read `maxItems` from the installed
      `httproutes.gateway.networking.k8s.io` CRD; fall back to vendored constants with
      the fallback recorded in the condition message if RBAC/CRD is unavailable).
- [ ] Re-run: pre-flight now fails with the cluster's real number.
- [ ] Repeat against a current OpenShift release and Envoy Gateway's bundled CRDs; record
      actual shipped limits for both.
- [ ] Remove controller RBAC on CRDs; confirm graceful fallback to vendored constants
      with that fact stated in the condition.

### Outcome / exit
- [ ] Pre-flight verdicts match apiserver verdicts on every cluster in our support matrix.
- [ ] Every budget-related condition states which limit source (cluster-read vs
      vendored-fallback) produced the verdict.

---

## STORY: Build-time generation of the router-route preset

**Issue Type:** Story
**Priority:** High (keystone — later work depends on this)
**Components:** kserve/llmisvc
**Labels:** `router`, `codegen`, `technical-debt`

### Summary
Author `config/llmisvcconfig/config-llm-router-route.yaml` from a small Go endpoint list
at build time (`make generate`), instead of hand-editing the YAML. The generated YAML
remains the shipped artifact — this is not a move to reconcile-time Go.

### Why
The API surface (`/v1/completions`, `/v1/chat/completions`, ...) is currently duplicated
across the name-path family, publisher-path family, and header-match family — three
edits per new endpoint. But the preset must stay data: `combineBaseRefsConfig` resolves
it via `getConfig` (service namespace, then system namespace) specifically because "this
configuration depends on the GW API provider version" (existing code comment), and
services can pin their own shape via `Route.HTTP.Refs`. Compiling rules into the
controller binary would break per-platform shipping, namespace overrides, and per-service
pinning — all currently free.

### Acceptance criteria
- [ ] Generator + endpoint-list data structure added under `hack/` (or similar);
      `make generate` regenerates `config-llm-router-route.yaml`.
- [ ] First generated output is **byte-identical** to the current checked-in template
      (golden-file / diff test in CI: regenerate, `git diff --exit-code`).
- [ ] Adding an endpoint to the list and regenerating produces the expected 3x rule
      change with no other diffs.
- [ ] No change to `reconcileRouter`, `expandLoRAAdapterMatches`, or
      `stripModelBasedRoutingRules` behavior in this story.

### Out of scope
Rule-shape change (Phase 1), budget validation (separate story) — this story only
changes how the existing shape is authored.

---

## STORY: Read HTTPRoute limits from the installed CRD

**Issue Type:** Story
**Depends on:** SPIKE-2
**Components:** kserve/llmisvc
**Labels:** `router`, `validation`

### Summary
Resolve `{MaxRules, MaxMatchesPerRule, MaxTotalMatches}` from the cluster's installed
`httproutes.gateway.networking.k8s.io` CRD schema at controller startup (with watch-based
invalidation), falling back to vendored constants — with the source recorded — only when
the CRD can't be read.

### Acceptance criteria
- [ ] RBAC marker added for `get/list/watch` on `customresourcedefinitions`
      (`apiextensions.k8s.io`), regenerated into `config/rbac/llmisvc`.
- [ ] Limits struct exposes `Source: cluster | vendored-fallback`.
- [ ] envtest: matches SPIKE-2's reproduction case (old-CRD fixture → correct lower
      limits resolved).
- [ ] Follows the existing CRD-availability guard pattern used for InferencePool
      (`utils.IsCrdAvailable`).

---

## STORY: Pre-flight route budget validation

**Issue Type:** Story
**Depends on:** prior two stories
**Components:** kserve/llmisvc
**Labels:** `router`, `validation`, `status-conditions`

### Summary
Validate the merged, expanded rule set against the resolved limits before the HTTPRoute
is applied. On failure, set the existing router condition `False` with a reason naming
the exact arithmetic — no new condition type.

### Acceptance criteria
- [ ] `validateRouteBudget(rules, limits)` runs in `reconcileRouter` after
      `expandLoRAAdapterMatches` / `stripModelBasedRoutingRules`, before the SSA apply.
- [ ] On failure: router condition `False`, reason `RouteBudgetExceeded`, message
      includes offending rule name, current count, and limit + source
      (e.g. "`v1-model-routing` would have 72 matches with 8 adapters; max 64
      (source: cluster CRD)"). Event emitted. Previous route object is left untouched
      (no partial apply).
- [ ] Boundary tests cover all four cells of {model-based routing on/off} ×
      {scheduler nil/non-nil}.
- [ ] No new condition *type* introduced (avoids Ready-aggregation churn on upgrade for
      existing CRs).

---

## STORY: `toJSON` escaping in `ReplaceVariables`

**Issue Type:** Story
**Priority:** Medium
**Components:** kserve/llmisvc
**Labels:** `router`, `bug-prevention`

### Summary
`ReplaceVariables` (`config_merge.go`) marshals the config to JSON, runs it through
`text/template`, and unmarshals — but interpolated values (model/adapter names) aren't
JSON-escaped. A name containing `"` or `\` corrupts the document and surfaces as an
unmarshal error rather than a validation error at the source.

### Acceptance criteria
- [ ] `toJSON` template func added to the existing FuncMap alongside `ChildName`,
      `kvTransferConfig`, `shutdownTimeout`.
- [ ] Model/adapter name interpolations switched to use it.
- [ ] Regression test: model or adapter name containing `"`, `\`, and non-ASCII
      characters round-trips correctly through template execution.

---

## STORY: Audit duplicate `spec.model.name` within a namespace

**Issue Type:** Story
**Priority:** Medium
**Components:** kserve/llmisvc
**Labels:** `router`, `validation`

### Summary
Add a field indexer on `spec.model.name` and, on reconcile, detect same-namespace
LLMInferenceServices sharing a model name. Surface as a condition + event.
**Audit only in this story** — no rejection. Enforcement is a separate, later story
gated behind one release of audit-mode data, and must land before any base-model routing
change (Phase 2) where a collision becomes a routing correctness bug rather than a
same-object precedence tie.

### Acceptance criteria
- [ ] Field indexer registered; collision detection uses the index (no extra listing
      cost beyond the indexed lookup).
- [ ] Collision → condition + event on both affected CRs; no reconcile failure, no
      admission rejection.
- [ ] Test: two LLMISVCs, same namespace, same `spec.model.name` → both surface the
      condition; unrelated namespaces unaffected.

---

## Backlog — later phases (child epics, not yet detailed)

Create as separate Epics under the parent, one per phase, referencing
`llmisvc-httproute-phased-plan.md` for full content:

- **EPIC: Router — collapse the header routing rule (Phase 1)**
  Depends on SPIKE-1, SPIKE-2. Path family unchanged (stays a per-endpoint allowlist);
  the header-only match collapses to remove endpoint × adapter duplication. Ships as a
  second generated preset, selectable per-service via `Route.HTTP.Refs`. Target ceiling:
  100+ adapters, achieved with no path match broadened to a default-to-pool shape.

- **EPIC: Migration — rule rename and merge-semantics compatibility (Phase 1.5)**
  Covers: legacy-named alias rules or pre-upgrade report for user `sectionName` policies
  (rehearsed against real Kuadrant AuthPolicies before choosing the mechanism); keyed
  (`[name=x]`) merge for `rules` using the existing merge-append annotation machinery;
  flipping the duplicate-model audit to enforcement.

- **EPIC: BBR base-model header routing (Phase 2)**
  Removes the adapter axis from the route entirely via GIE's
  adapter→base-model ConfigMap mapping. Requires a product decision on dynamic
  (runtime-loaded) LoRA adapters first — the CR is the mapping's source of truth today,
  and runtime-loaded adapters have no representation in `enumerateLoRAAdapters`.

- **EPIC: odh-model-controller coupling (cross-repo)**
  Publisher-family and header-family authz verification and fixes in the Gateway-level
  AuthPolicy SAR (path-segment parsing); rename resilience for the watcher-reconciled
  AuthPolicy; MergeSpec convergence onto the kserve library once presets are generator-
  authored.

- **EPIC: Sharding contingency (Phase 3 — trigger-gated, not scheduled)**
  Detection ships with the pre-flight story above. Only builds if a real deployment
  exceeds the Phase 1/2 ceilings; requires odh-model-controller changes too
  (multi-route-per-service AuthPolicy support), so it does not ship from kserve alone.
