# `llmisvc` routing profiles and provider conformance

Status: design discussion, not an accepted implementation plan.

This note captures the implications discussed while answering Q7 of the design
review: where the approximately 100-adapter guarantee applies, how a routing
profile could be selected without immediately adding a new typed field, and what
machinery is needed to validate additional Gateway providers.

## Q7 decision

The proposed contract is:

- `Exact` uses Gateway API Core exact-header behavior. Its capacity is computed
  from the installed HTTPRoute limits and may be much lower than 100. With the
  current route shape it stops at approximately seven adapters.
- A provider-specific regex profile uses `RegularExpression` header matching and
  guarantees at least 100 adapters only for provider versions and configurations
  that pass the conformance suite below.
- A possible future `ShardedExact` profile distributes Core exact matches across
  several controller-owned HTTPRoutes. It is the portable high-capacity escape
  hatch, but requires substantial control-plane work.

**Accepted:** the product guarantees 100 adapters when an explicitly selected,
tested regex profile applies. Exact mode remains supported with a lower capacity
computed from the installed HTTPRoute limits. KServe does not claim a universal
100-adapter guarantee across every Gateway provider.

A future ShardedExact profile may provide a portable 100-adapter guarantee, but
that is not a prerequisite for the initial Istio/Envoy-targeted implementation.

"Certified" is deliberately avoided here. The intended term is **tested provider
profile**: a KServe-maintained compatibility contract for a provider version and
configuration, not an external certification and not a Gateway API conformance
level.

## Why a provider profile is necessary

Gateway API defines exact header matching as Core behavior, but regular-expression
header matching is implementation-specific. The API does not provide a portable
way to discover:

- the regex dialect;
- full-match versus partial-match behavior;
- the proxy's regex program-size limit;
- whether an accepted HTTPRoute was rejected later by the data plane; or
- implementation-specific runtime settings that change the effective limit.

Provider identity alone is insufficient. Two installations of the same provider
can have different runtime settings. A tested profile therefore describes a
provider **plus a supported configuration**, and the operator asserts that the
target Gateway satisfies that profile.

An illustrative profile contract is:

```yaml
name: istio-re2
provider: istio
versions: ">=1.30 <1.31"
headerRegex:
  dialect: RE2
  semantics: full-match
  maxValueBytes: 4096
  maxProgramSize: 32768
capacity:
  minimumAdapters: 100
  namingFixture: realistic-v1
```

This schema is illustrative test data, not a proposed public API.

## Selecting a profile with existing presets

Adding `spec.router.modelRouting.profile` to `LLMInferenceServiceConfig` would be a
new typed API. An annotation would also be a behavioral API, only with weaker
schema validation and discoverability.

The initial implementation can instead use the existing
`LLMInferenceServiceConfig` preset mechanism. KServe already injects a well-known
router-route preset when HTTP routing is enabled and the service does not provide
user-managed route refs. The current code explicitly treats this preset as
provider-version-dependent.

### Single-provider cluster

The platform operator installs the standard well-known router-route preset with
the appropriate contents:

```text
generic upstream installation  -> Exact preset contents
supported RHOAI/Istio install   -> Istio RE2 preset contents
```

Users make no new selection. Enabling the router causes the existing well-known
preset to be applied.

### Multi-provider cluster

The operator can publish explicitly named presets:

```text
kserve-config-llm-router-route-exact
kserve-config-llm-router-route-istio-re2
kserve-config-llm-router-route-envoy-re2
```

A service selects an allowed preset through the existing `spec.baseRefs` API.
Explicit base refs have higher merge precedence than well-known defaults; the
service spec remains highest. The applied config is already reported through
`status.appliedConfigs`.

This is sufficient selection machinery, but it is not capability discovery. In a
multi-provider cluster, admission or controller validation still needs to verify
that the selected preset is allowed for the referenced Gateway.

### Trust boundary

Config lookup prefers an `LLMInferenceServiceConfig` in the service namespace
over one in the KServe system namespace. Namespace shadowing is a backward-
compatibility feature, but it matters here: a tenant may be able to replace a
well-known profile with provider-specific behavior that the Gateway does not
support.

Before provider profiles become a supported contract, choose one of:

- restrict creation of `LLMInferenceServiceConfig` resources through RBAC;
- reject namespace-shadowed provider profiles;
- explicitly permit tenant-controlled profiles and treat resulting failures as
  tenant configuration errors; or
- introduce a typed, operator-owned Gateway capability binding later.

The recommended starting point is an operator-selected well-known preset in a
single-provider cluster. Multi-provider selection should not be claimed safe
until the trust and Gateway-binding rule exists.

## Driving generation from the resolved preset

The resolved HTTPRoute match shape can select the LoRA expansion algorithm:

- `Exact`: retain today's one-exact-match-per-model expansion;
- `RegularExpression`: generate one escaped alternation containing the base model
  and adapters for every model-routing path match.

The controller must not treat every arbitrary regex header as a model-index
instruction. It should recognize a narrow model-routing contract: the configured
model-routing header, the expected generated-value marker, and the semantic rule
role. If this recognition becomes implicit or brittle, a typed strategy field is
preferable to inference from YAML shape.

The profile is selected after all presets and service overrides are merged.
Budget validation therefore runs on the fully expanded expected HTTPRoute, just
before create or update.

## Failure and fallback semantics

Falling back to today's Exact shape does **not** preserve a 100-adapter guarantee.
It is only valid when the desired models fit the computed Exact budget.

Recommended behavior when the requested profile is unsupported or over budget:

1. Do not generate a knowingly invalid replacement.
2. Leave the last valid HTTPRoute object serving.
3. Set the existing `HTTPRoutesReady=False` condition with a specific reason such
   as `RoutingProfileUnsupported` or `RouteBudgetExceeded`.
4. Report desired profile, effective profile, relevant budget usage, and limit.
5. Never silently omit adapters.
6. Never oscillate profiles in response to transient data-plane health.

A profile change is an explicit rollout. Candidate configuration should be
validated before replacing the serving route.

Portable preflight can validate the installed HTTPRoute schema limits. Regex
program-size validation is provider-specific and only applies when the selected
tested profile defines a conservative limit or estimator.

## `ShardedExact`: the portable high-capacity profile

ShardedExact keeps Core exact-header matching but partitions model matches across
several HTTPRoutes:

```text
LLMInferenceService
|- route-paths
|- route-models-000
|- route-models-001
|- route-models-002
`- route-models-003
```

It would live in KServe's `LLMISVCReconciler`. Each shard should be a
same-namespace, controller-owned child; the Gateway remains platform-owned.

Current inline `route.http.spec` reconciliation owns exactly one deterministic
HTTPRoute. User-supplied `route.http.refs` are not modified, and selecting refs
causes deletion of the owned route. Controller-generated sharding therefore needs
a managed route-set abstraction rather than reusing refs as if they were owned.

Control-plane implications include:

- deterministic and stable adapter-to-shard assignment;
- create/update/prune lifecycle for a set of child routes;
- an explicit non-atomic rollout sequence across Kubernetes objects;
- aggregate status for desired, ready, old, and failed shards;
- globally safe rule names containing service, role, and shard identity;
- policy creation and pruning for every shard in ODH;
- route-owner/label indexes instead of cluster-wide event scans;
- a supported Istio version floor for safe multi-route merging;
- defined behavior for grouped services, whose member routes already reconcile
  independently and are eventually consistent.

ShardedExact is consequently a control-plane feature, not a small rendering
fallback. Regex is the smaller first implementation for an operator-controlled
Istio/Envoy target; ShardedExact remains the path to a portable 100-adapter
guarantee if that becomes a requirement.

## Provider conformance machinery

The test system should answer three different questions independently:

1. **Portable API conformance:** does the generated route use and satisfy the
   installed Gateway API schema and Core behavior?
2. **KServe routing conformance:** do requests reach the correct pool and model,
   and are lifecycle/status behaviors correct?
3. **Provider-profile conformance:** does this provider configuration satisfy the
   additional regex semantics and capacity claimed by its profile?

Do not collapse these into one end-to-end script. A provider can pass Core exact
routing while failing the regex profile, and KServe can reconcile correctly while
the provider silently rejects proxy configuration.

### Repository layout

A possible layout in this spike, later movable into KServe, is:

```text
conformance/
  profiles/
    exact.yaml
    istio-re2.yaml
    envoy-ai-gateway-re2.yaml
  providers/
    istio/
      install.sh
      observe.sh
    envoy-ai-gateway/
      install.sh
      observe.sh
  cases/
    matching.yaml
    isolation.yaml
    lifecycle.yaml
    capacity.yaml
  fixtures/
    names-realistic-v1.txt
  runner/
    ...
  results/
    <provider>/<version>/<profile>.json
```

Provider adapters should do only provider-specific work: install/configure the
Gateway implementation and collect its data-plane acceptance signal. Test cases,
requests, expected destinations, and capacity fixtures remain provider-neutral.

### Test layers

#### Layer 1: render and admission

- Render the expected HTTPRoute from an LLMInferenceService fixture.
- Count rules, per-rule matches, total matches, and serialized regex bytes.
- Apply it against the provider's installed Gateway API CRDs.
- Assert admission success or the expected structured KServe condition.
- Test old CRDs with lower limits so validation uses installed constraints rather
  than vendored constants.

This layer does not require a live proxy and belongs in unit/envtest where
possible.

#### Layer 2: semantic routing

Run a provider-neutral request matrix against instrumented backends:

- exact base-model and adapter names hit the expected pool;
- unknown, prefix, suffix, embedded, and cross-namespace names miss;
- regex metacharacters in legal names are escaped;
- path-addressed and header-addressed requests preserve precedence;
- two services with overlapping short names remain isolated;
- rule names cannot cross-wire endpoint-picker configuration;
- adding, reducing, and clearing adapters updates the effective route;
- an over-budget update leaves the last valid route serving and reports failure.

Each assertion records both the HTTP response and the backend/pool/model that
actually handled the request.

#### Layer 3: provider acceptance

An HTTPRoute `Accepted=True` is insufficient. The provider adapter must inspect a
provider-specific signal that the programmed route reached the data plane:

- proxy/xDS configuration contains the expected route;
- no RouteConfiguration NACK was emitted;
- provider control-plane logs contain no rejected-regex signal;
- a canary request proves the newly generated pattern, not merely an old route.

This is the primary reason provider adapters are necessary.

#### Layer 4: capacity boundary

For the profile's versioned naming fixture:

1. Generate 99, 100, 101, and provider-boundary adapter sets.
2. Record pattern bytes and, where observable, regex program size.
3. Require 100 to route successfully for every tested name in the fixture.
4. Verify that the first unsupported configuration fails observably and leaves
   the prior valid route serving.
5. Repeat with maximum-length and regex-metacharacter-heavy names as robustness
   tests, without confusing those results with the guaranteed naming fixture.

The fixture must be checked into source control and versioned. A statement such as
"100 realistic adapters" is otherwise not reproducible.

#### Layer 5: churn and shared-Gateway safety

- Repeatedly add/remove adapters while traffic flows.
- Run multiple services and multiple HTTPRoutes on one Gateway.
- Verify no request reaches another service's endpoint picker.
- Verify unrelated routes remain programmed during rejected updates.
- Exercise upgrade from Exact to regex and rollback from regex to Exact when the
  model set fits.
- For future ShardedExact, exercise create-before-delete rollout, shard pruning,
  policy fan-out, and partial reconciliation failures.

### Result and promotion contract

Every run should emit machine-readable evidence containing:

```yaml
provider: istio
providerVersion: 1.30.3
profile: istio-re2
gatewayAPIVersion: 1.5.1
gieVersion: 1.5.0
configurationDigest: "..."
tests:
  coreExact: pass
  regexSemantics: pass
  capacity100: pass
  sharedGatewayIsolation: pass
  rejectedConfigObservable: pass
artifacts:
  routes: "..."
  requests: "..."
  providerLogs: "..."
```

A provider/version/configuration is added to the tested profile table only when
all mandatory tests pass. Results must include the configuration digest because
provider version alone does not determine regex limits.

Run this matrix:

- in pull requests for render, budget, and envtest layers;
- nightly for live providers;
- before adding or widening a supported version range;
- against the exact profile on every provider;
- against regex only where the operator profile claims it.

## Immediate implementation sequence

1. Fix exact comparison/pruning for every controller-owned HTTPRoute.
2. Add post-expansion HTTPRoute admission-budget validation using installed CRD
   limits and the existing `HTTPRoutesReady` condition.
3. Define and version the realistic-name fixture and provider result format.
4. Extract the current spike probes into provider-neutral cases plus Istio and
   Envoy AI Gateway adapters.
5. Add the regex preset and alternation generator behind an operator-installed
   well-known preset.
6. Require the conformance matrix to pass before documenting a provider profile
   as guaranteeing 100 adapters.
7. Defer ShardedExact until portable 100-adapter support is an accepted product
   requirement.
