# HTTPRoute rule/match budget in `llmisvc` — findings and spike plan

Scope: `config/llmisvcconfig/config-llm-router-route.yaml` and the reconcile-time
expansion in `pkg/controller/v1alpha2/llmisvc/config_merge.go`.

---

## TL;DR

1. The binding limit is **64 matches per rule**, not the 16-rule limit. The template
   sits at 12 of 16 rules and never grows; it grows in *matches*.
2. Today's hard ceiling is **7 LoRA adapters** per `LLMInferenceService`. Failure is a
   raw apiserver rejection at HTTPRoute apply time, late in reconcile and dependent on
   adapter count — so it passes in dev and breaks in production.
3. **Sharding across multiple HTTPRoutes does not help.** Growth is inside a single rule,
   and a rule cannot span two objects.
4. **Regex header matching is not a safe default.** Envoy's default RE2 program-size
   limit caps a literal alternation at roughly two adapters, and it fails in the data
   plane rather than at admission.
5. The enumeration is avoidable. The model name lives in the request body; the routing
   header is a projection of it. Upstream GIE already moves the adapter→base-model
   mapping into BBR, which makes the route **constant-size**.
6. **Adapters are the slower-moving axis.** The endpoint surface multiplies against it:
   adding four plausible endpoints (embeddings, rerank, score, count_tokens) drops the
   ceiling from 7 adapters to 3. Several of those endpoints are not under `/v1`, which
   breaks the prefix collapse in §5.

---

## 1. Verified API limits

From `apis/v1/httproute_types.go` on `main`
(<https://github.com/kubernetes-sigs/gateway-api/blob/main/apis/v1/httproute_types.go>):

| Field | Limit |
|---|---|
| `spec.rules` | 16 (`MinItems=1`) |
| `spec.rules[].matches` | 64 |
| total matches across all rules | **≤ 128** (CEL) |
| `spec.hostnames` | 16 |
| `spec.rules[].filters` | 16 |
| `spec.rules[].backendRefs` | 16 |
| `matches[].headers`, `matches[].queryParams` | 16 each |
| `HTTPHeaderMatch.Value` | 4096 characters |

Notes worth carrying:

- The ≤128 check is an **explicitly unrolled CEL expression over indices 0–15**, because
  CEL has no aggregate `sum()` over lists. Raising the 16-rule cap means hand-extending
  that expression — a decent signal it will not move soon.
- The request to raise hostnames/rules to ~100 was **closed as not planned**
  (kubernetes-sigs/gateway-api#3821). The stated rationale for the caps is etcd object size.
- v1.6.0 *did* relax **TLSRoute** to 1024 hostnames/rules, with an explicit warning to
  validate apiserver/etcd/controller behaviour first. HTTPRoute was not changed.
- The earlier "8 matches per rule" figure that circulates in issues from 2023 is stale.
- Rule-name uniqueness (`Rule name must be unique within the route`) is
  **experimental-channel gated**, so the standard-channel CRD will accept duplicates.

---

## 2. Current template budget

12 rules / 19 matches:

| Rule | Matches | Grows with adapters? |
|---|---|---|
| `v1-completions-path` | 1 | no |
| `v1-chat-completions-path` | 1 | no |
| `v1-responses-path` | 1 | no |
| `v1-messages-path` | 1 | no |
| `v1-model-routing` | **8** | **yes** |
| `v1-completions-publisher-path` | 1 | no |
| `v1-chat-completions-publisher-path` | 1 | no |
| `v1-responses-publisher-path` | 1 | no |
| `v1-messages-publisher-path` | 1 | no |
| `v1-publisher-path-catch-all` | 1 | no |
| `v1-catch-all-path` | 1 | no |
| `v1-catch-all-model-routing` | 1 | **yes** |

The four `*-path` rules cannot batch matches: when a rule uses `URLRewrite` with
`path.replacePrefixMatch`, CEL requires **exactly one** `PathPrefix` match on that rule.
That constraint is permanent for any prefix-rewriting rule.

`expandLoRAAdapterMatches` deep-copies every model-routing match once per adapter.
The 8 matches in `v1-model-routing` are 4 endpoints × trailing-slash variants.

```
v1-model-routing matches = 8 × (1 + A)
route total matches      = 9A + 19
```

| A (adapters) | `v1-model-routing` | route total | result |
|---|---|---|---|
| 0 | 8 | 19 | ok |
| 3 | 32 | 46 | ok |
| 7 | 64 | 82 | at cap |
| **8** | **72** | 91 | **rejected (per-rule 64)** |
| 12 | — | 127 | (would be ok) |
| 13 | — | 136 | rejected (route-wide 128) |

**Effective ceiling: 7 adapters.** Rule count is irrelevant.

---

## 3. Why regex header matching is not a safe default

Collapsing the adapter axis into one `RegularExpression` header match
(`publishers/<ns>/models/(a|b|c…)`) is attractive — the route becomes constant-size —
but on default settings it is worse than what we have.

- Envoy checks compiled regex program size via runtime key
  `re2.max_program_size.error_level`, **default 100**; a regex above it fails to compile.
  <https://www.envoyproxy.io/docs/envoy/latest/api-v3/type/matcher/v3/regex.proto>
- Program size runs roughly 1.2 instructions per literal character. A real-world
  four-name alternation measured 187 (envoyproxy/envoy#21056).
- ~100 program size ≈ ~80 characters of pattern. Minus a ~26-character
  `publishers/<ns>/models/` prefix, that is **two, maybe three adapters**.
- The field is documented as deprecated with validation "to be performed on the
  management server", yet Envoy was still enforcing the 100 default after the
  deprecation (envoyproxy/envoy#18633), and there is no non-deprecated way to raise it
  (envoyproxy/envoy#20254).
- Program size **changes between RE2 versions** (envoyproxy/envoy#9174), so a value that
  compiles today can fail after a data-plane upgrade.
- **Failure mode is a downgrade.** An Exact-match overflow is rejected by the apiserver
  with a precise message. A program-size overflow is accepted by the apiserver, pushed
  via xDS, and rejected by the data plane. Contour hit exactly this and the symptom was
  *all* routes vanishing from Envoy's config (projectcontour/contour#2043) — one
  `LLMInferenceService` taking down unrelated routes on a shared gateway.

Ceiling comparison:

| Encoding | Max adapters |
|---|---|
| Exact, as shipped (8 matches/identity) | 7 |
| Exact, trailing slashes dropped (4/identity) | 15 |
| Regex, default program size 100 | ~2 |
| Regex, `error_level` raised to 1000 | ~150 (4096-char CRD cap binds) |
| Regex chunked across matches, default limit | ~32 |

Conclusion: regex is viable **only** where an operator has raised
`re2.max_program_size.error_level` — a data-plane bootstrap setting the controller can
neither read nor set. If offered at all, it belongs in a **separate
`LLMInferenceServiceConfig` an operator opts into**, not a controller flag.

---

## 4. The actual fix direction

The model name — base or LoRA — is in the **request body**, per the OpenAI spec. BBR
exists to parse the body and project the value into a header so the gateway can match on
it (<https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/pkg/bbr/README.md>).

Consequences:

- **The path selects a pool; the body selects the model.** They are not two addressing
  schemes for the same selector.
- **Per-adapter paths are meaningless.** An adapter lives on the same pool as its base
  model, so `/publishers/{ns}/models/{base}/v1/...` with `{"model": "…adapter"}` already
  reaches it. Nothing to enumerate on the path side.
- **What BBR writes is a design lever.** In the GIE multiple-inference-pools guide, BBR
  extracts the model name, **looks the base model up in a ConfigMap**, and emits
  `X-Gateway-Base-Model-Name`, which is what the HTTPRoute matches.
  <https://gateway-api-inference-extension.sigs.k8s.io/guides/serving-multiple-inference-pools-latest/>

Matching the base-model header means **one Exact match, constant forever** — no regex,
no program-size exposure, no chunking, no sharding, and no per-adapter reconcile churn
on the HTTPRoute. Costs: the adapter→base mapping has to be generated and kept in sync
in a ConfigMap (no 64-item cap, no data-plane compile step), our value scheme is
namespace-qualified (`publishers/{ns}/models/{name}`) so the mapping must use qualified
names on both sides, and the guide is explicit that **all model names, base and LoRA,
must be unique** for the correct pool to be determined.

Fallback if BBR-side mapping is not reachable: nest adapter served-names under the base
(`publishers/{ns}/models/{base}/adapters/{adapter}`) and use a single fixed prefix regex
`publishers/ns/models/base/.*` — ~40 characters, comfortably under the default program
size, and constant regardless of adapter count.

---

## 5. Interim simplifications (superseded — see correction below)

**Superseded.** The `PathPrefix: /{ns}/{name}/v1` collapse below was withdrawn: it sends
*everything* under that prefix to the pool by default, which is unsafe on a gateway
shared by many models and other services — the workload may expose non-inference paths
under `/v1` that a broad prefix rule would silently forward to the EPP, and the exposure
compounds across every service sharing the listener. The path family is kept exactly as
enumerated as it is today; only the collapse below (splitting/dropping trailing slashes on
`v1-model-routing`) is retained, because it touches only the header-only match, not a
path-based default. Full corrected shape and budget: `llmisvc-httproute-phased-plan.md`,
Phase 1.

<details>
<summary>Original (withdrawn) analysis, kept for the trailing-slash and rule-splitting
points, which are still valid</summary>

**~~Collapse the endpoint enumeration~~ (withdrawn).** All four `*-path` rules strip the
same prefix, so one rule with `PathPrefix: /{ns}/{name}/v1` → `ReplacePrefixMatch: /v1`
is equivalent — **but this makes the pool the default for every path under the prefix**,
including `/{ns}/{name}/v1/models` and anything else the workload happens to expose
there. Do not adopt; the path family stays one rule per known endpoint.

**Caveat, still relevant even without the collapse:** `/score`, `/rerank`, `/v2/rerank`,
`/pooling`, `/classify`, `/tokenize` and `/detokenize` sit at the root (§6), outside
`/v1` entirely — they were never reachable by path addressing under either shape unless
explicitly added to the endpoint list.

**Drop the trailing-slash variants.** No OpenAI-compatible SDK emits `/v1/completions/`.
8 → 4 matches per identity on the header-only rule. Still valid — this doesn't touch the
path family.

**Split `v1-model-routing` across several rules.** The 64 cap is per rule, not per route.
Matches are OR'd and all slices share one backendRef with no filters, so `-0`, `-1`, … is
semantically identical. Still valid as the Phase 3 T1 mitigation.

**Stop enumerating endpoints in YAML by hand.** Superseded by WP0.1: the endpoint list
becomes generator input and `config-llm-router-route.yaml` stays the shipped, checked-in
artifact — build-time generation, not reconcile-time Go (the YAML preset is the
backward-compat seam: per-platform shipping, namespace shadowing via `getConfig`,
per-service `Route.HTTP.Refs` pinning all depend on it staying data).

</details>

**Corrected shape (6 rules, path family unchanged, only the header rule collapses):**

```
1. Exact /{ns}/{name}{endpoint_i}       → {endpoint_i}  → InferencePool   (one rule per endpoint)
2. /{ns}/{name}                         → /             → Service        (unchanged catch-all)
3. Exact /publishers/{ns}/models/{model}{endpoint_i} → {endpoint_i} → InferencePool  (opt-in alias)
4. /publishers/{ns}/models/{model}      → /             → Service        (opt-in alias)
5. model header only (no path match)                    → InferencePool
```

| Encoding | matches on the header rule | max adapters |
|---|---|---|
| as shipped (`v1-model-routing`, path×header, 9 matches/identity) | 9A+19 | 7 |
| trailing slashes dropped | 5A+... | 15 |
| + split across rules (T1) | — | 23 |
| **header-only collapse (this correction)** | **1 + A** | **~122** |
| base-model header (BBR ConfigMap lookup, Phase 2) | 0 | unbounded |

The path family's rule count (`m` endpoints + 1 catch-all, doubled if the publisher alias
is enabled) is now the only thing that trades against the 16-rule cap — independent of
adapter count.

---

## 6. API surface: which endpoints, and which can be header-routed

The template currently exposes four endpoints: `/v1/completions`, `/v1/chat/completions`,
`/v1/responses`, `/v1/messages`. The useful way to sort candidates is by whether the
request carries a JSON `model` field that BBR can project into a header.

**Header-routable (JSON body with `model`):**

| Endpoint | Notes |
|---|---|
| `/v1/embeddings` | The obvious gap. Any embedding model, including multimodal. |
| `/v1/score`, `/score` | Cross-encoder, bi-encoder and late-interaction score models. |
| `/v1/rerank`, `/rerank`, `/v2/rerank` | Three aliases for one capability (Jina- and Cohere-compatible). |
| `/pooling` | All pooling models; same input shape as embeddings. |
| `/classify` | Classification models only. |
| `/tokenize`, `/detokenize` | Any model with a tokenizer. |
| `/v1/messages/count_tokens` | Anthropic side; carries `model`. |

**Not header-routable:**

| Endpoint | Why |
|---|---|
| `/v1/audio/transcriptions`, `/v1/audio/translations` | multipart/form-data with file uploads — BBR parses JSON, so the model never reaches a header. Path-addressed only. |
| `GET /v1/responses/{id}`, cancel, input_items | No body. The response ID is opaque and encodes no model. |
| `GET /v1/models`, `/health`, `/ping`, `/metrics` | No model. Also: each service returns only its own models; nothing aggregates across pools on a shared gateway. |
| `/v1/realtime` | WebSocket — no body to inspect before routing, plus upgrade and idle-timeout concerns. |
| LoRA load/unload | Carries `lora_name`, not `model`. |

Three consequences:

1. **Root-level paths break the `/v1` collapse.** Seven of the header-routable endpoints
   are not under `/v1`. On the header side they have no matching rule today and fall
   through to `v1-catch-all-model-routing`, which points at the **workload Service** —
   bypassing the pool and EPP. This is likely already happening for `/v1/embeddings`.
   Whether that is intended is an open question.
2. **Exact vs PathPrefix creates an asymmetry.** The path family uses PathPrefix, so
   `/v1/messages/count_tokens` and `/v1/responses/{id}` already work there. The header
   family uses Exact, so they do not — the same request behaves differently depending on
   how it was addressed.
3. **Stateful Responses cannot be model-routed.** A follow-up `GET /v1/responses/{id}`
   carries no model anywhere. Supporting the Responses API on a shared gateway needs path
   addressing or ID-based affinity; the header scheme fundamentally cannot cover it.

**Budget impact.** Endpoints and adapters multiply. Each endpoint added to
`v1-model-routing` costs 2 matches (with the trailing-slash variant) × (1 + A):

| Endpoints in `v1-model-routing` | Base matches | Max adapters |
|---|---|---|
| 4 (today) | 8 | 7 |
| 6 (+ embeddings, rerank) | 12 | 4 |
| 8 (+ score, count_tokens) | 16 | **3** |

Dropping trailing slashes returns 8 endpoints to a ceiling of 7 adapters. Only the
base-model header (§4) makes endpoint additions genuinely free.

---

## 7. Adjacent risks found while reading

**Merge path.** `mergeSpecs` uses strategic merge with `LLMInferenceServiceSpec{}` as the
schema, and `gwapiv1` types carry no `patchMergeKey` tags, so `rules` is **replaced
wholesale** today. If merge-append is extended to
`spec.router.route.http.spec.rules`, every layer (well-known presets + user `baseRefs` +
the LLMISVC spec) concatenates, bringing duplicate rule names with it. Duplicates are not
rejected on the standard channel but make Kuadrant `sectionName` targeting ambiguous.
Recommendation: use `[name=x]` element matching for `rules` so overlays **override by rule
name** rather than append.

**Model-name collisions.** Two `LLMInferenceService`s in one namespace with the same
`spec.model.name` generate byte-identical publisher paths and header values in two
different HTTPRoutes. Nothing rejects that; it resolves silently by creation timestamp,
then `{namespace}/{name}`. Under the BBR base-model scheme this becomes a correctness
bug, not just a precedence tie. Needs a validating webhook.

**Late, opaque failure.** The budget is only checked when the apiserver rejects the
HTTPRoute apply, surfacing as a raw CEL message. Needs a pre-flight check on the merged
spec with a dedicated condition.

**Mode-dependent ceiling.** `stripModelBasedRoutingRules` drops to 10 rules / 10 matches
when model-based routing is off, so the adapter ceiling exists in one mode and not the
other.

**Template escaping.** `ReplaceVariables` marshals the config to JSON, runs it through
`text/template`, and unmarshals. Substituted values are not JSON-escaped, so a model or
adapter name containing `"` or `\` corrupts the document and surfaces as an unmarshal
error rather than a validation error. A `toJSON` template func closes this.

**Sharding, for the record.** If it were ever needed, it is unusually safe here: every
match is keyed by `{namespace}/{name}` or `{namespace}/{model}`, so shards are
match-disjoint and cross-route precedence is never consulted. But it costs N objects per
service (pruning, ownerRefs, status aggregation, shard-aware policy targets) to raise a
ceiling that §5 raises further for free in one object. Not recommended.

---

## Spikes

### S1 — Header-only match at scale, and endpoint-list growth

**Summary.** The corrected shape doesn't invert any default: the path family stays
exactly as enumerated as today, and the only structural change is collapsing
`v1-model-routing` to a single header-only match — the same pattern
`v1-catch-all-model-routing` already uses in the shipped template. This spike verifies
that existing pattern at higher volume/diversity, and checks growing the pool-addressable
endpoint list (`m`) doesn't introduce anything new.

**Goal.** Confirm the header-only match's safety (no path scope, relies on header-value
uniqueness) holds under adversarial input, and build the addressability register's
path-addressable vs header-addressable classification per endpoint.

**Validation steps** — first against the pool directly (bypassing the route), then through
the full chain (gateway + BBR + EPP); capture EPP logs and `envoy_http_ext_proc_*` stats
throughout:
1. Deploy a single-node LLMISVC with scheduler enabled.
2. **Known-endpoint probes:** `GET /v1/models`, `GET /health`, `/v1/embeddings`,
   `/v1/rerank`, `/v1/score`, `/pooling`, `/tokenize`, `/v1/messages/count_tokens` —
   header-addressed (hitting `H`, no path scope) and, for each candidate added to
   `PoolEndpoints`, path-addressed too. Record status, latency delta vs
   direct-to-runtime, and whether EPP schedules or passes through.
3. **Cross-tenant collision probe (the header-only match's actual risk surface):**
   on a gateway with two or more LLMISVCs plus an unrelated non-LLM HTTPRoute sharing
   the hostname, send a request intended for the unrelated route while carrying a header
   value equal to one LLMISVC's qualified model name. Confirm precedence and that nothing
   outside the intended model's traffic is captured — this is what the header rule's
   "no path scope" actually depends on being safe (value uniqueness, not URL boundary).
4. **Body-shape probes on header-addressed traffic:** bodyless `POST`; `text/plain` and
   malformed JSON; multipart `/v1/audio/transcriptions`; wrong-case and unknown model
   names — the last two also feed S8.
5. **Large-body probes:** `/v1/embeddings` batches at 1 MB, 10 MB, 64 MB against `H`.
   ext_proc buffers the body to parse it — record where the limit bites and whether it
   fails open (proceeds headerless, falling through to the Service catch-all), fails
   closed (413/5xx), or stalls.
6. **Protocol probe:** WebSocket upgrade to `/v1/realtime`, path-addressed (already
   covered by the unchanged path family) and header-addressed if offered.
7. Repeat 2–6 on every EPP build we support (upstream GIE, any downstream variant).

**Exit criteria.** The header-only match's safety confirmed under adversarial input, or a
specific failure mode identified and mitigated (e.g., a minimum-uniqueness requirement
beyond exact-string-equality). Each endpoint classified path-addressable, header-addressable,
or both, feeding `PoolEndpoints` and the addressability register. No scenario found where
`H`'s lack of path scope, by itself, causes traffic to reach the wrong service.

---

### S2 — Measure actual RE2 program size on target data planes

**Summary.** Our ~2-adapter estimate for the regex encoding is derived from a
1.2-instructions-per-character rule of thumb, not measurement.

**Goal.** Either kill the regex option definitively or quantify exactly where it breaks,
per data plane, so the decision is not based on an estimate.

**Validation steps.**
1. On a test gateway, set `re2.max_program_size.warn_level` (unset by default) low enough
   to log.
2. Apply an HTTPRoute with a `RegularExpression` header match containing an alternation of
   1, 3, 5, 10 and 25 realistic adapter names.
3. Read the `re2.program_size` histogram and `re2.exceeded_warn_level` counter at each step;
   record the character-to-program-size ratio.
4. Confirm whether the default `error_level` of 100 is still enforced on our Envoy version
   — apply a knowingly oversized regex and observe whether the apiserver accepts it and the
   data plane rejects it.
5. **Record the blast radius of the data-plane rejection**: does only that route drop, or
   does the whole RDS update fail? This is the deciding factor, not the ceiling.
6. Repeat on OpenShift/OSSM (Istio) and on Envoy Gateway.

**Exit criteria.** If blast radius is route-local *and* the measured ceiling beats 61, keep
regex as an operator-installed config. Otherwise drop the regex track entirely.

---

### S3 — BBR base-model-name mapping

**Summary.** GIE's multiple-inference-pools guide has BBR resolve adapter → base model via
a ConfigMap and emit `X-Gateway-Base-Model-Name`. This makes the HTTPRoute constant-size.

**Goal.** Establish whether we can adopt this without changing the LLMISVC API, and what
the controller would then own.

**Validation steps.**
1. Confirm which header and ConfigMap shape the BBR version we ship actually supports —
   `X-Gateway-Model-Name` vs `X-Gateway-Base-Model-Name`, and whether the lookup is
   available in that build.
2. Verify the mapping accepts our namespace-qualified names
   (`publishers/{ns}/models/{name}`) on both sides.
3. Stand up two LLMISVCs on one shared gateway, each with 3 adapters, and confirm a
   request naming an adapter reaches the right pool with a **single** Exact header match
   per route.
4. Establish who owns the ConfigMap: one per gateway or one per namespace, how the
   controller writes it, what happens on concurrent writes from multiple LLMISVC
   reconciles, and what the size ceiling is.
5. **Reproduce the sync window.** Drive a request loop naming a new adapter at ~10 rps,
   then add the adapter (CR update → ConfigMap write → BBR pickup) and measure the 404
   window end-to-end. Repeat for removal with requests in flight. Record how BBR consumes
   the map (watch vs poll, and the interval), whether a stale map can still emit a mapping
   for a deleted adapter, and what the client sees in each window (gateway 404 vs runtime
   model-not-found).
6. From (5), confirm the Phase 2 ordering is implementable: map generation observed by BBR
   **before** the adapter is announced, and the reverse on removal.
7. Check behaviour on `kgateway`/`agentgateway`, which implement BBR natively rather than
   as a deployed ext_proc — the sync mechanism and window will differ.

**Exit criteria.** If (2), (3) and (4) hold, this becomes the target design and everything
in §5 is interim. If the ConfigMap is per-gateway and cross-namespace, evaluate the nested
served-name fallback instead.

---

### S4 — Rule merge semantics

**Summary.** `rules` is atomically replaced today. Any move to merge-append changes that,
and duplicate rule names are not rejected on the standard channel.

**Goal.** Pick merge semantics for `spec.router.route.http.spec.rules` before the
merge-append annotation is extended to it.

**Validation steps.**
1. Confirm empirically that strategic merge replaces `rules` wholesale with a two-layer
   overlay (base preset + user `baseRef` each defining rules).
2. Build the same case with merge-append enabled and record the resulting rule count and
   duplicate names.
3. Implement `[name=x]`-keyed merge for `rules` and verify a user overlay redefining
   `v1-model-routing` replaces rather than appends.
4. Verify Kuadrant `sectionName` targeting still resolves against the merged result
   (`sectionName` on an HTTPRoute target = HTTPRouteRule name).
5. Confirm rule-name uniqueness holds across the whole chain including reconcile-time
   generated rules.

**Exit criteria.** Keyed merge lands before merge-append is enabled for `rules`.

---

### S5 — Pre-flight budget validation

**Summary.** The ceiling stops being a constant once encoding, mode and endpoint count
vary. It must be computed, not documented.

**Goal.** Turn a late apiserver rejection into an early, actionable condition.

**Validation steps.**
1. Compute rules, matches-per-rule and total matches on the merged spec, after
   `expandLoRAAdapterMatches` and `stripModelBasedRoutingRules`, before apply.
2. Surface a dedicated condition (e.g. `RouteBudgetExceeded`) naming the offending rule
   and the arithmetic — "`v1-model-routing` would have 72 matches with 8 adapters, max 64".
3. Confirm the existing dry-run path catches it, and that the message we emit is ours and
   not the raw CEL string.
4. Test at the boundary in both routing modes and with the publisher family enabled and
   disabled.
5. Add a JSON-escaping (`toJSON`) test for model and adapter names containing `"` and `\`.

**Exit criteria.** No configuration can produce an HTTPRoute the apiserver rejects.

---

### S6 — Establish the actual requirement

**Summary.** Every option above is being ranked against an unstated target. 15 may already
be sufficient; 61 may not be.

**Goal.** Pin the supported adapter count per `LLMInferenceService` so the option choice
stops being open-ended.

**Validation steps.**
1. Collect adapter counts from real and planned deployments.
2. Decide whether "max N adapters, enforced at admission with a clear error" is an
   acceptable product statement, and fix N.
3. Cross-check N against the table in §5 and pick the lowest-cost option that clears it.

**Exit criteria.** A documented, tested, enforced N.

---

### S7 — Endpoint surface: which endpoints get path addressing

**Summary.** The path family stays an enumerated allowlist (design correction —
`llmisvc-httproute-phased-plan.md` Phase 1); it does not collapse to a policy rule. The
open question is narrower than originally scoped: which endpoints are worth the one rule
each costs (`m` trades directly against the 16-rule cap), versus staying
header-addressable only, which costs nothing per endpoint.

**Goal.** A committed `PoolEndpoints` list — the core set that gets both path and header
addressing — plus an explicit statement of which endpoints are header-only, so the
addressability register is a decision, not a default.

**Validation steps.**
1. Using S1's results, confirm each candidate endpoint's behaviour under both addressing
   modes rather than assuming symmetry.
2. Confirm whether header-addressed `/v1/embeddings` currently reaches the Service via
   `v1-catch-all-model-routing` (today's shipped fallback for unmatched headers, if any),
   and whether that's intended or a latent bug — resolved once `/v1/embeddings` is
   explicitly added to `PoolEndpoints`.
3. Decide the root-level path question: `/score`, `/rerank`, `/v2/rerank`, `/pooling`,
   `/classify`, `/tokenize` sit outside `/v1` entirely (§6) — header-addressable for free
   regardless of this decision; path-addressable only if explicitly added.
4. Decide the Responses API question: do we support stateful `GET /v1/responses/{id}` on
   a shared gateway? If yes, it's path-addressable only — header routing can't express it.
5. Decide the audio question: multipart endpoints are path-only by construction (BBR
   parses JSON). Confirm that's an acceptable documented limitation.
6. Re-derive the Phase 1 budget table (`m + 1` rules) for whatever `PoolEndpoints` set is
   committed, and feed the result into S5's pre-flight check and S6's N.

**Exit criteria.** A committed `PoolEndpoints` list with `m` fixed, an explicit
header-only list for everything else, and no endpoint added by hand-editing three
template locations (superseded by WP0.1's generator regardless of the list's size).

---

### S8 — BBR projection semantics and mixed addressing

**Summary.** The routing header is a projection of the body. When BBR skips a body (over
the buffer limit, non-JSON, multipart), header-addressed traffic silently loses its match
while the identical request path-addressed succeeds. Mixed addressing adds a second
asymmetry: the path outranks the header, and the body is never validated against the pool
it lands on.

**Goal.** A truth table — (addressing mode × body condition) → observed routing — per data
plane, so the addressability register and support docs record behaviour rather than
assumption.

**Validation steps.**
1. Send the same `/v1/chat/completions` request three ways: path-addressed,
   header-addressed (root path + body), and **mixed** — `/{nsA}/{svcA}/…` path with a body
   naming svcB's adapter. Confirm the path wins the mixed case and record where the
   mismatched request fails (EPP unknown-model behaviour from S1 governs).
2. Repeat with a body just over BBR's buffer limit: fails open (no header →
   `v1-catch-all-model-routing` → Service) or closed? Does the path-addressed twin behave
   differently?
3. Repeat with `model` casing variants; record whether any component normalises.
4. Run the table on both the ext_proc deployment and native BBR
   (`kgateway`/`agentgateway`); diff the two.

**Exit criteria.** The truth table exists, register lines and the support decision tree are
generated from it, and the mixed-addressing row reads *path wins; body not cross-checked*
— or documents what actually happens instead.

---

### S9 — Installed-CRD limits vs vendored constants

**Summary.** The pre-flight check is only as good as the limits it checks against, and the
cluster's HTTPRoute CRD comes from the gateway implementation or platform bundle — not our
`go.mod`. Older CRDs cap matches at **8 per rule**, not 64.

**Goal.** Reproduce the failure the plan claims (pre-flight passes, apiserver rejects),
then prove the fix catches it.

**Validation steps.**
1. On a kind cluster, install a Gateway API release whose HTTPRoute CRD carries the old
   8-match cap. Apply a route with 40 matches on one rule; record the apiserver error
   verbatim.
2. Run the Phase 0 pre-flight against the same spec using vendored (64/128) constants —
   confirm it wrongly passes. This is the reproduction of the hole.
3. Implement schema discovery: read `spec.versions[].schema` from the installed CRD,
   extract `maxItems` for `rules`/`matches` and the CEL total; re-run and confirm the
   pre-flight now fails with the cluster's real number in the message.
4. Repeat on a current OCP release and on Envoy Gateway's bundled CRDs; record the limits
   each actually ships.
5. Remove the controller's RBAC on CRDs and confirm the fallback: vendored constants, and
   the condition says so.

**Exit criteria.** Pre-flight verdicts match apiserver verdicts on every cluster we
support, and every condition names which limits (cluster-read vs fallback) produced it.

---

### S10 — Migration rehearsal: what silently detaches

**Summary.** Phase 1 renames every rule; Kuadrant policies target rule names via
`sectionName`. The claim is that an `AuthPolicy` detaches silently — no error, it just
stops applying. That must be observed before Phase 1.5's mechanism is chosen.

**Goal.** Watch the break happen; choose alias rules vs pre-upgrade report from what
actually surfaces.

**Validation steps.**
1. On a Kuadrant-enabled cluster, attach an `AuthPolicy` and a `RateLimitPolicy` with
   `sectionName: v1-model-routing`; verify enforcement with a probe that *fails* auth.
2. Apply the Phase 1 route (renamed rules). Re-run the probe: does the previously denied
   request now **pass** (silent security regression)? Record everything that surfaces —
   policy `Accepted`/`Enforced` conditions, route status, events — and everything that
   doesn't.
3. Measure the detach latency: is there a window where the old config still enforces?
4. Add a legacy-named alias rule for the old name; confirm the policy re-attaches and
   enforcement resumes, and record what aliases cost against the rule budget (`3 + 2k`
   plus one per aliased name).
5. Rehearse the overlay break: a `baseRef` overlay defining a minimal `rules` list, applied
   before and after keyed merge; diff the generated routes.

**Exit criteria.** The Phase 1.5 mitigation table is backed by observed behaviour: we know
exactly what signal (if any) fires when a policy detaches, whether the regression window is
real, and whether aliases are required or a pre-upgrade report suffices.

---

### S11 — odh-model-controller coupling

**Summary.** On OpenShift AI a second controller reconciles the same CR:
`odh-model-controller` attaches a Gateway-level and a route-level AuthPolicy, derives
authorization from the URL path (`request.path.split("/")[1..2]` → SubjectAccessReview on
the `llminferenceservices` resource), and runs its own vendored copy of MergeSpec against
`LLMInferenceServiceConfig`. The route shape is a cross-repo security contract, and this
spike observes both sides of it.

**Goal.** A per-addressing-mode authz truth table for ODH, and proof (or disproof) that
the two controllers' merge outputs stay in agreement under version skew.

**Validation steps.**
1. On an ODH/RHOAI cluster with Kuadrant enabled, deploy an LLMISVC and capture both
   generated AuthPolicies verbatim; note target kinds (Gateway vs whole HTTPRoute).
2. **Path family:** request `/{ns}/{name}/v1/chat/completions` with a token that has `get`
   on the LLMISVC and one that doesn't. Confirm allow/deny match the SAR expectation.
3. **Publisher family:** same pair on `/publishers/{ns}/models/{model}/…` — the SAR
   receives shifted segments (`split[1]` = `publishers`). Record: denied, mis-scoped, or
   handled by a rule we haven't seen.
4. **Header family:** same pair on root-path `/v1/chat/completions` + body. Record SAR
   inputs and outcome. This alone decides whether header addressing is supportable on ODH
   without an odh-side change.
5. **Rule rename (with S10):** apply the Phase 1 route and confirm odh's whole-route,
   watcher-reconciled AuthPolicy survives the rename — unlike a user's `sectionName`
   policy — and measure any re-reconcile window where auth is not enforced.
6. **Lifecycle:** stop the LLMISVC (route deleted) and verify reconciliation with the
   RHOAIENG-56131 fix in place; then present two routes for one service (future sharding)
   and record whether the AuthPolicy matcher creates two policies, one, or fails.
7. **Skew:** run the same CR through upstream kserve MergeSpec and through odh's vendored
   copy one minor version behind; diff the generated route specs byte-for-byte.

**Exit criteria.** A truth table (addressing family × token permission) → observed authz
per family; an explicit statement of which families ODH supports without odh changes; and
either matching MergeSpec outputs or a convergence plan behind one imported library.
