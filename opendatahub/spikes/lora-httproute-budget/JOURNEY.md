# Implementation journey: LoRA regex routing

This is the decision log for turning
[`llmisvc-lora-routing-design.md`](llmisvc-lora-routing-design.md) into working
code - the first workstream (Q41): the regex unit in KServe, the review round,
and the self-validating e2e loop from
[`lora-routing-e2e-validator.md`](lora-routing-e2e-validator.md). The design
doc owns *what* was agreed; this file owns *how* it got built and every call
made along the way.

Result up front: branch `upstream/llmisvc/feat/lora-regex-routing` (worktree
`main__worktrees/feat/lora-regex-routing`), seven commits, 290 envtest specs
green, and a clean-cluster e2e qualification passing 10/10 including real
inference through all 100 fixture adapters plus the base model
(run `e2e/artifacts/20260824T235410Z-a9ac556d`, 480 recorded requests).

## Setup decisions

- **Base the branch on `upstream/llmisvc/fix/stale-lora-route-matches`**, not
  master. Q21 says "consume before final integration if it has not merged" -
  the fix had not merged, and the e2e transition scenarios depend on
  rule-removal detection, so starting on top of it beats a late rebase
  surprise. If the fix merges first, rebase drops it for free.
- Worktree and branch follow the house convention
  (`main__worktrees/<type>/<slug>`, `upstream/<area>/<type>/<slug>`), created
  with plain `git worktree add` so auto-indexing fires.

## Implementation decisions

Everything below implements an accepted design decision; the interesting part
is where the code had latitude.

- **Strict parsing lives in the llmisvc `toConfig`, not in
  `v1beta1.NewIngressConfig`.** `IngressConfig` is shared with the v1beta1
  InferenceService controller; validating there would let one llmisvc-only typo
  halt reconciliation for every InferenceService too. The raw string passes
  through `IngressConfig` and the llmisvc config loader rejects unknown values
  (Q18/Q43). Consequence, documented rather than hidden: an invalid value
  halts all *LLMInferenceService* reconciliation (fail closed, existing routes
  keep serving) and the watch map handlers go deaf until the value is fixed -
  recovery via the ConfigMap fan-out is verified by test.
- **The zero value `""` behaves as `exact`.** Q42 demands byte-compatibility
  for an omitted field, and directly constructed `Config{}` values (tests,
  future callers) must not change behavior. Anything else that is not a known
  literal fails - at parse time in production, and defensively again in
  `expectedHTTPRoute`'s exhaustive switch for hand-built configs.
- **`expectedHTTPRoute` returns `(route, error)` with an always-non-nil
  route.** The delete and force-stop paths only need the route's identity, so
  they keep working when the transform fails; any caller that would *write*
  the spec is gated on the error.
- **The validation gate sits in `reconcile()` before `reconcileWorkload`**
  (Q33). On a deterministic policy failure it marks
  `HTTPRoutesReady=False`, emits one event per transition, keeps observing
  workload status (read-only), and returns nil - no requeue, recovery is
  watch-driven. The scheduler/gateway/pool reconciliation deliberately stays
  frozen in that state: the service is terminally invalid pending a spec or
  config change, and nothing should mutate mid-state.
- **Budget constants are pinned, not discovered** (Q25): rules 16, matches per
  rule 64, total matches 128, backendRefs per rule 16, header value 4096 bytes
  - matching vendored Gateway API v1.5.1. A guard test parses the committed
  `test/crds/gatewayapi_httproute.yaml` so a dependency bump that moves a limit
  fails loudly instead of desyncing silently.
- **Budget validation runs twice by design**: once pre-workload on the
  rendered route, and again in `reconcileHTTPRoutes` after group backendRef
  injection - group membership mutates the route after the first gate and can
  push a rule past the backendRefs budget. When the second check fails, the
  route write is skipped, the condition explains why, and the acceptance-based
  condition evaluation is suppressed so it cannot overwrite the budget verdict
  with a stale-looking Ready.
- **Recognition is case-insensitive** (`strings.EqualFold`) and rejects
  duplicate case-equivalent routing headers in one match. Gateway API header
  names are case-insensitive and only the first equivalent entry is evaluated;
  case-sensitive matching would let a lowercase handcrafted regex bypass Q36's
  structural validation (found by the adversarial review, verified, fixed).
  The pre-existing exact/strip/discovery paths stay case-sensitive - that is
  an adjacent upstream defect, captured as a work item, not smuggled into this
  branch.
- **Transform is validate-all-then-rewrite.** A structural failure never
  leaves a partially transformed spec, so nothing depends on callers
  discarding the route on error.
- **Empty adapter names are skipped in the regex path** - an empty alternation
  branch would match the empty identity. The exact path renders them
  (pre-existing behavior, frozen by Q42); the webhook rejects them anyway.
- **The realistic-v1 fixture is generated, versioned, and shared.** 100
  deterministic names (teams x tasks x langs, every 7th with an HF-style
  `acme/` prefix, every 9th with a `.r16` suffix). The golden pattern comes
  from an independent generator - not the production renderer - to keep the
  oracle non-circular. The KServe testdata copy and `e2e/hack/gen-names.py`
  must stay name-for-name identical; both sides assert 100 names and 101
  rendered identities (Q34/Q35).

## Review round

Four specialist agents (Go, k8s security, controller-runtime, KServe domain)
plus a Codex adversarial pass reviewed the feature commit. Every suggestion
was fact-checked before acceptance; the point of being opinionated is having
reasons.

Accepted (all landed in the hardening commit):

- `Lora*` -> `LoRA*` identifier rename (codebase convention; JSON tags stay).
- Case-insensitive recognition + duplicate-header rejection (Codex HIGH, the
  one genuine pre-ship blocker).
- Explicit error classification via a `Reason()` interface; unrecognized
  errors requeue instead of being terminally swallowed.
- Budget messages name the strategy as context, not cause, and carry Q34's
  adapter/identity counts.
- Warning events only on condition transitions.
- `observeWorkloadStatus` keeps running while the gate holds writes back.
- Post-injection revalidation + backendRefs dimension (latent Q33 gap for >16
  group members).
- Budget code moved next to the existing route validation; constants guard
  test; shared test helpers deduplicated; fixture README for reproducibility.
- Six new envtest scenarios: handcrafted-regex structural failure, gate
  recovery, final-adapter removal, partial rollback (small service rolls back
  to exact, large one retains regex + condition), disabled-mode stripping,
  group + regex coexistence. Plus exhaustive printable-ASCII escaping.

Rejected, with reasons:

- *Fall back to exact on an invalid global value* (security review) -
  contradicts accepted Q43; fail-closed is the design, not an accident.
- *Q42 upgrade regression for legacy over-budget inline routes* (Codex) - the
  budget constants mirror the CRD limits exactly, so any route the gate would
  reject was already being rejected by admission; the gate only improves the
  failure mode. Real behavior change worth a release note: >7-adapter exact
  services stop rolling workloads and get a clean condition instead of an
  admission-rejection loop.
- *Include the effective strategy in failure messages* - Q17 (the
  authoritative conditions decision) asks for desired strategy, usage, limit,
  and the retained-route fact; classifying the retained route would add an API
  read on the error path for information the route itself shows.
- *Regex program-size estimation* - explicitly deferred by Q11; tested
  profiles must demonstrate the 4096-byte limit binds first.

Deferred as work items (adjacent, out of scope): case-sensitivity in the
pre-existing exact/strip/discovery paths, exact-path rendering of empty
adapter names, webhook-side name length caps.

### Weighing the adversarial verdict

The Codex adversarial pass (run through the plugin's rescue path -
`/codex:adversarial-review` itself is reserved for direct invocation) returned
an overall **"needs rework"** against the feature commit. That verdict was
right at the time, and is discharged now:

- The verdict rested on one confirmed blocker: the case-sensitive header
  recognition letting a lowercase handcrafted regex slip past Q36. Fact-checked
  against the vendored Gateway API semantics (header-name matching is
  case-insensitive, first equivalent entry wins), confirmed real, fixed, and
  re-proven three ways - unit tests, the handcrafted-regex envtest, and the
  clean-cluster e2e run.
- Its remaining substantive findings did not survive verification: the Q42
  "upgrade regression" was refuted (the budget constants mirror the CRD
  limits, so every route the gate rejects was already inadmissible - the gate
  only changes *how* it fails, which became the release note), and the
  effective-strategy message request lost to Q17's authoritative wording.
- The duplicate-events LOW was accepted (independently raised by two other
  reviewers) and the events now fire only on condition transitions.
- Of its test blind-spot list, roughly half was adopted directly
  (case-insensitivity units, exhaustive ASCII escaping, final-adapter removal,
  the custom-inline Q36 envtest, partial rollback); the traffic-continuity and
  churn items were routed to the live validator where they belong; controller
  restart mid-fan-out was shown to need no test at all (informer initial sync
  re-enqueues everything by construction); and the transition-identity
  assertions were partially adopted - rule names and route UID are pinned,
  while parent refs and hostnames stay under the comparator's derivative
  semantics by design.

Net: one review, one real bug, two refuted claims, and a sharper test suite -
about the best return an adversarial pass can give. The "needs rework" stamp
does not carry forward to the final branch state; the re-validation above is
what retires it, not the passage of time.

A second adversarial pass - this time `/codex:adversarial-review` proper,
against the full branch diff - returned "needs-attention" with one confirmed
medium: the post-injection retained-route path fed `updateRoutingStatus` an
empty route list for managed-only services, clearing `status.url` and
`status.addresses` for an endpoint that was still serving. Verified real,
fixed by feeding the stored route back into discovery while
`HTTPRoutesReady` stays False.

The regression coverage for that fix took a deliberate detour. The retained
branch is only reachable in production when group backendRef injection pushes
a rule past sixteen members, so the first attempts were 17-member envtests -
and they kept fighting the membership mechanics (a brand-new member has no
route, so its resolved model names never match and it is classified divergent;
even a joining standalone service did not converge inside a two-minute
window). Instead of hardening an inherently churny fixture, the final test
passes a hand-built over-budget route straight into `reconcileHTTPRoutes`
with a fake client - same branch, deterministic, and proven to fail without
the fix on exactly the erased-status symptom. The 17-member scenario stays
where that kind of churn belongs: the live validator, if it ever earns a
scenario of its own.

## E2E decisions

- The harness lives in `e2e/` here, per the validator doc's location decision:
  shell owns build and isolated cluster lifecycle, pytest owns assertions and
  machine-readable results. Exit codes: 0 pass, 1 assertion failure, 2 harness
  failure. Success requires exit zero *and* a failure-free `results.json`.
- **No xdist in the first slice.** The doc allows bounded parallelism for
  read-only tests; strictly serial phases (mutation first, then readonly) buy
  the same correctness with none of the coordination, and runtime cost is
  dominated by vLLM startup anyway.
- **Runtime services own the fixture namespace exclusively.** The fast and
  full profiles declare overlapping adapter identities; two services sharing
  an identity is exactly the Q14/Q15 namespace-collision defect and makes
  traffic attribution ambiguous. Deploying a runtime service first displaces
  any other and waits for its route to disappear - order-independent, and it
  reproduced the collision warning as a bonus.
- **Attribution accepts vLLM's canonical served name for the base model.**
  Empirically (v0.19.0): LoRA modules echo the requested name exactly (both
  the short and fully qualified forms), but `--served-model-name` aliases
  normalize to the first name. Assertions accept only the identity set of the
  requested model - never a different identity.
- **User-route non-mutation asserts on `generation`, not `resourceVersion`** -
  Istio legitimately bumps RV writing route status.
- **Route-stability wait before no-op comparisons** - the InferencePool
  v1alpha2 -> v1 migration rewrites backendRef groups shortly after creation;
  comparing against a pre-migration snapshot is a test race, not a product
  bug.
- **The istiod crash is recovered and recorded, not compensated silently.**
  Istio 1.30.x panics with `concurrent map writes` (the known mergeHTTPRoutes
  race) under rapid route churn, and kubelet backoff keeps its validation
  webhook down long after the churn stops. The harness restarts it, retries,
  and writes an `istiod-restart` evidence line - that is the provider
  acceptance signal Layer 3 exists for.
- Local machine workarounds (stale rootless `DOCKER_HOST`, `kind load` vs
  docker 29 multi-arch saves - import via `ctr` without `--all-platforms`)
  live in `lib.sh` and the session notes; they are environment quirks, not
  contract.
- The final verdict came from a fresh, pinned cluster (`--scenario all`), per
  the loop contract - passing focused reruns on a reused cluster never counts
  as done.

## What the live loop actually caught

The point of building the validator before calling the feature finished:

1. **A real controller bug**: `kmeta.ChildName("lora-pvc-", name)` does not
   sanitize DNS-invalid characters, so an HF-style adapter name
   (`acme/billing-summarize-en-v1.r16`) produced an invalid Deployment volume
   name - workload creation failed and route reconciliation never ran. The
   sanitizer regex existed in the file and was never wired in. Fixed with a
   hash-suffixed sanitized name; already-valid names keep their volume name so
   upgrades do not roll workloads.
2. **A provider defect worth evidence**: the istiod crash above - invisible to
   envtest, exactly the class of failure the provider-conformance layers were
   designed around.
3. **A runtime contract nuance**: the served-name alias normalization, now
   documented in the assertions instead of being discovered by the first
   downstream consumer.

## Follow-ups for the PR

- Release note: pre-existing >7-adapter exact services change failure mode
  (see the rejected-Q42 entry above).
- Explicitly descope the Q32 provider result schema and case matrix to a
  follow-up rather than under-delivering silently.
- Decide whether the volume-name fix ships as its own PR - it stands alone and
  maintainers may want it first.
- Check whether `upstream/llmisvc/fix/stale-lora-route-matches` merged before
  opening the PR; rebase accordingly.

Seven commits, one green verdict file, and a validator that earns its keep by
finding bugs the unit tests structurally cannot - which was the whole pitch.
