"""LoRA routing strategy qualification suite.

Scenario map (see lora-routing-e2e-validator.md):
  shape        route generation: exact compat, regex shape, negatives
  transitions  global strategy transitions, fan-out, ownership boundaries
  budget       fail-early budget behavior, invalid global configuration
  smoke        the fast development profile (small adapter sets)
  capacity     the full 100-adapter qualification

Phase contract: tests marked routing_strategy_mutation run in a strictly
serial first phase; routing_strategy_readonly tests run afterwards. Every
test declares its starting strategy through the `strategy` fixture, which
restores the original ConfigMap data on teardown.
"""

import pytest

from conftest import (
    ADAPTER_NAMES,
    ensure_istiod_ready,
    wait_for_stable_route,
    FIXTURE_NS,
    MODEL_HEADER,
    condition,
    create_llmisvc,
    epp_destination_rule,
    expected_regex,
    fq,
    get_llmisvc,
    get_route,
    llmisvc_manifest,
    model_header_matches,
    patch_llmisvc,
    probe_completion,
    rule_names,
    save_resource,
    wait_until,
)

SMOKE_ADAPTERS = ADAPTER_NAMES[:4]


def wait_for_route(api, ns, name, desc="route", timeout=180):
    return wait_until(lambda: get_route(api, ns, name), timeout=timeout, desc=desc)


def wait_for_header_value(api, ns, name, value, timeout=180, negate=False):
    def check():
        route = get_route(api, ns, name)
        values = {h["value"] for h in model_header_matches(route)}
        ok = (value not in values) if negate else (value in values)
        return route if ok else None
    verb = "absence of" if negate else ""
    return wait_until(check, timeout=timeout, desc=f"{verb} header value {value[:80]}... on {ns}/{name}")


def assert_all_matches_regex(route, pattern):
    matches = model_header_matches(route)
    assert matches, "route has no model-routing header matches"
    for h in matches:
        assert h.get("type") == "RegularExpression", f"match not transformed: {h}"
        assert h["value"] == pattern


def assert_all_matches_exact(route):
    for h in model_header_matches(route):
        assert h.get("type", "Exact") == "Exact", f"unexpected non-Exact match: {h}"


# ---------------------------------------------------------------------------
# Shape: exact compatibility and regex generation
# ---------------------------------------------------------------------------

@pytest.mark.routing_strategy_readonly
@pytest.mark.shape
@pytest.mark.smoke
def test_exact_default_adapter_expansion(api, test_ns, strategy, record):
    """An omitted strategy behaves as exact: one header match per identity."""
    strategy.require(None)
    svc = "sh-exact"
    create_llmisvc(api, llmisvc_manifest(svc, test_ns, "sh-exact-base", SMOKE_ADAPTERS))

    route = wait_for_header_value(api, test_ns, svc, fq(test_ns, SMOKE_ADAPTERS[0]))
    values = {h["value"] for h in model_header_matches(route)}
    assert fq(test_ns, "sh-exact-base") in values
    for adapter in SMOKE_ADAPTERS:
        assert fq(test_ns, adapter) in values, f"missing exact match for {adapter}"
    assert_all_matches_exact(route)
    save_resource("route-exact-default.json", route)


@pytest.mark.routing_strategy_readonly
@pytest.mark.shape
@pytest.mark.smoke
def test_regex_route_shape(api, test_ns, strategy, record):
    """Regex strategy collapses base+adapters into one anchored alternation on
    every model-routing match; no per-identity exact matches remain."""
    strategy.require("regex")
    svc = "sh-regex"
    base = "sh-regex-base"
    create_llmisvc(api, llmisvc_manifest(svc, test_ns, base, SMOKE_ADAPTERS))

    pattern = expected_regex(test_ns, base, SMOKE_ADAPTERS)
    route = wait_for_header_value(api, test_ns, svc, pattern)
    assert_all_matches_regex(route, pattern)
    values = {h["value"] for h in model_header_matches(route)}
    assert fq(test_ns, base) not in values
    assert fq(test_ns, SMOKE_ADAPTERS[0]) not in values
    record("pattern", {"bytes": len(pattern), "service": svc})
    save_resource("route-regex-shape.json", route)


@pytest.mark.routing_strategy_readonly
@pytest.mark.shape
@pytest.mark.smoke
def test_regex_base_only_stays_exact(api, test_ns, strategy, record):
    """A service without adapters keeps the base model's Exact match even under
    the regex strategy (design Q27)."""
    strategy.require("regex")
    svc = "sh-base-only"
    create_llmisvc(api, llmisvc_manifest(svc, test_ns, "sh-base-only-model"))

    route = wait_for_header_value(api, test_ns, svc, fq(test_ns, "sh-base-only-model"))
    assert_all_matches_exact(route)


@pytest.mark.routing_strategy_readonly
@pytest.mark.shape
def test_regex_deterministic_under_reorder(api, test_ns, strategy, record):
    """Reordering spec.model.lora.adapters must not change the HTTPRoute."""
    strategy.require("regex")
    svc = "sh-reorder"
    base = "sh-reorder-base"
    create_llmisvc(api, llmisvc_manifest(svc, test_ns, base, SMOKE_ADAPTERS))

    pattern = expected_regex(test_ns, base, SMOKE_ADAPTERS)
    wait_for_header_value(api, test_ns, svc, pattern)
    # The InferencePool v1alpha2 -> v1 migration legitimately rewrites the
    # backendRef groups shortly after creation; capture the baseline only once
    # the route has been stable for a few seconds.
    route = wait_for_stable_route(api, test_ns, svc)
    before_rv = route["metadata"]["resourceVersion"]

    reordered = list(reversed(SMOKE_ADAPTERS))
    patch_llmisvc(api, test_ns, svc, {"spec": {"model": {"lora": {"adapters": [
        {"name": a, "uri": f"pvc://{FIXTURE_NS}/adapters/{a}"} for a in reordered
    ]}}}})
    # Same identities and URIs, reversed list order: the rendered route must
    # not change. Settle, then compare.
    import time
    time.sleep(10)
    after = get_route(api, test_ns, svc)
    assert after["spec"] == route["spec"], "adapter reorder must not rewrite the route"
    assert after["metadata"]["resourceVersion"] == before_rv, "route was rewritten on a no-op"


# ---------------------------------------------------------------------------
# Transitions, fan-out, ownership (mutation phase)
# ---------------------------------------------------------------------------

@pytest.mark.routing_strategy_mutation
@pytest.mark.transitions
@pytest.mark.smoke
def test_transition_exact_regex_exact(api, test_ns, strategy, record):
    """Exact -> regex -> exact updates the same HTTPRoute in place (Q20)."""
    strategy.require("exact")
    svc = "tr-small"
    base = "tr-small-base"
    create_llmisvc(api, llmisvc_manifest(svc, test_ns, base, SMOKE_ADAPTERS))

    route = wait_for_header_value(api, test_ns, svc, fq(test_ns, SMOKE_ADAPTERS[0]))
    uid, names_before = route["metadata"]["uid"], rule_names(route)

    pattern = expected_regex(test_ns, base, SMOKE_ADAPTERS)
    strategy.require("regex")
    route = wait_for_header_value(api, test_ns, svc, pattern)
    assert route["metadata"]["uid"] == uid, "transition must update the route in place"
    assert rule_names(route) == names_before, "rule identity must be preserved"
    assert fq(test_ns, SMOKE_ADAPTERS[0]) not in {h["value"] for h in model_header_matches(route)}

    strategy.require("exact")
    route = wait_for_header_value(api, test_ns, svc, fq(test_ns, SMOKE_ADAPTERS[0]))
    assert route["metadata"]["uid"] == uid
    assert pattern not in {h["value"] for h in model_header_matches(route)}
    assert_all_matches_exact(route)


@pytest.mark.routing_strategy_mutation
@pytest.mark.transitions
def test_fanout_mixed_services(api, test_ns, strategy, record):
    """One global strategy change reconciles every affected service: LoRA
    services move to regex, base-only stays exact, user-managed refs are
    untouched (Q8 fan-out + ownership boundaries)."""
    strategy.require("exact")

    with_adapters = "fan-lora"
    base_only = "fan-base"
    refs_svc = "fan-refs"
    create_llmisvc(api, llmisvc_manifest(with_adapters, test_ns, "fan-lora-base", SMOKE_ADAPTERS))
    create_llmisvc(api, llmisvc_manifest(base_only, test_ns, "fan-base-model"))

    # A user-managed HTTPRoute referenced by a service: the controller must
    # never rewrite it, whatever the strategy.
    user_route = {
        "apiVersion": "gateway.networking.k8s.io/v1",
        "kind": "HTTPRoute",
        "metadata": {"name": "user-owned-route", "namespace": test_ns},
        "spec": {
            "parentRefs": [{"group": "gateway.networking.k8s.io", "kind": "Gateway",
                            "name": "kserve-ingress-gateway", "namespace": "kserve"}],
            "rules": [{
                "matches": [{
                    "path": {"type": "Exact", "value": "/v1/completions"},
                    "headers": [{"type": "Exact", "name": MODEL_HEADER,
                                 "value": fq(test_ns, "fan-refs-model")}],
                }],
                "backendRefs": [{"kind": "Service", "name": "user-backend", "port": 8000}],
            }],
        },
    }
    api["custom"].create_namespaced_custom_object(
        "gateway.networking.k8s.io", "v1", test_ns, "httproutes", user_route)
    # Custom route refs require an explicit gateway ref (webhook-enforced).
    create_llmisvc(api, llmisvc_manifest(
        refs_svc, test_ns, "fan-refs-model", SMOKE_ADAPTERS,
        route={"http": {"refs": [{"name": "user-owned-route"}]}},
        gateway={"refs": [{"name": "kserve-ingress-gateway", "namespace": "kserve"}]}))

    wait_for_header_value(api, test_ns, with_adapters, fq(test_ns, SMOKE_ADAPTERS[0]))
    user_before = api["custom"].get_namespaced_custom_object(
        "gateway.networking.k8s.io", "v1", test_ns, "httproutes", "user-owned-route")

    strategy.require("regex")

    pattern = expected_regex(test_ns, "fan-lora-base", SMOKE_ADAPTERS)
    route = wait_for_header_value(api, test_ns, with_adapters, pattern)
    assert_all_matches_regex(route, pattern)

    base_route = wait_for_header_value(api, test_ns, base_only, fq(test_ns, "fan-base-model"))
    assert_all_matches_exact(base_route)

    import time
    time.sleep(10)
    user_after = api["custom"].get_namespaced_custom_object(
        "gateway.networking.k8s.io", "v1", test_ns, "httproutes", "user-owned-route")
    assert user_after["spec"] == user_before["spec"], "user-managed route was mutated"
    # generation only advances on spec writes; resourceVersion legitimately
    # moves when the gateway controller updates the route's status.
    assert user_after["metadata"]["generation"] == user_before["metadata"]["generation"]


@pytest.mark.routing_strategy_mutation
@pytest.mark.budget
def test_over_budget_retains_route_and_workload(api, test_ns, strategy, record):
    """An over-budget regex candidate fails before any workload mutation: the
    last valid route keeps serving, the Deployment does not roll, and
    HTTPRoutesReady=False reports RouteBudgetExceeded with usage and limit."""
    strategy.require("regex")
    svc = "bud-over"
    base = "bud-over-base"
    create_llmisvc(api, llmisvc_manifest(svc, test_ns, base, SMOKE_ADAPTERS))

    valid_pattern = expected_regex(test_ns, base, SMOKE_ADAPTERS)
    wait_for_header_value(api, test_ns, svc, valid_pattern)

    deployments = {d.metadata.name: d.metadata.generation
                   for d in api["apps"].list_namespaced_deployment(test_ns).items}
    assert deployments, "expected at least one workload deployment"

    huge = SMOKE_ADAPTERS + [f"huge-{i}-{'x' * 600}" for i in range(9)]
    patch_llmisvc(api, test_ns, svc, {"spec": {"model": {"lora": {"adapters": [
        {"name": a, "uri": f"pvc://{FIXTURE_NS}/adapters/{a}"} for a in huge
    ]}}}})

    def budget_condition():
        obj = get_llmisvc(api, test_ns, svc)
        cond = condition(obj, "HTTPRoutesReady")
        if cond and cond.get("status") == "False" and cond.get("reason") == "RouteBudgetExceeded":
            return cond
        return None
    cond = wait_until(budget_condition, timeout=120, desc="RouteBudgetExceeded condition")
    assert "4096" in cond["message"]
    assert "left unchanged" in cond["message"]
    record("condition", {"reason": cond["reason"], "message": cond["message"][:500]})

    import time
    time.sleep(10)
    route = get_route(api, test_ns, svc)
    values = {h["value"] for h in model_header_matches(route)}
    assert valid_pattern in values, "last valid route must keep serving"

    after = {d.metadata.name: d.metadata.generation
             for d in api["apps"].list_namespaced_deployment(test_ns).items}
    assert after == deployments, f"workload rolled on a budget failure: {deployments} -> {after}"
    save_resource("route-over-budget-retained.json", route)


@pytest.mark.routing_strategy_mutation
@pytest.mark.budget
def test_invalid_strategy_fails_closed(api, test_ns, strategy, record):
    """An unknown strategy value fails config loading: no route is rewritten
    even when the spec changes, and recovery resumes reconciliation (Q43)."""
    strategy.require("regex")
    svc = "bud-invalid"
    base = "bud-invalid-base"
    create_llmisvc(api, llmisvc_manifest(svc, test_ns, base, SMOKE_ADAPTERS[:2]))

    initial = expected_regex(test_ns, base, SMOKE_ADAPTERS[:2])
    wait_for_header_value(api, test_ns, svc, initial)

    strategy.require("bogus")
    patch_llmisvc(api, test_ns, svc, {"spec": {"model": {"lora": {"adapters": [
        {"name": a, "uri": f"pvc://{FIXTURE_NS}/adapters/{a}"} for a in SMOKE_ADAPTERS[:3]
    ]}}}})

    import time
    time.sleep(15)
    route = get_route(api, test_ns, svc)
    values = {h["value"] for h in model_header_matches(route)}
    assert initial in values, "route must not change under an invalid strategy"
    grown = expected_regex(test_ns, base, SMOKE_ADAPTERS[:3])
    assert grown not in values

    strategy.require("regex")
    wait_for_header_value(api, test_ns, svc, grown)


# ---------------------------------------------------------------------------
# Runtime traffic (real CPU vLLM, PVC-backed adapters)
# ---------------------------------------------------------------------------

def deploy_runtime_service(api, svc, base, adapters, record):
    """Create a runtime-backed service in the fixture namespace and wait until
    the base model answers through the shared endpoint."""
    from kubernetes.client.exceptions import ApiException

    # The data plane (and its validation webhook) must be healthy before any
    # runtime resources are created.
    ensure_istiod_ready(api, record)

    # Exclusive ownership of the fixture namespace: the fast and full profiles
    # declare overlapping adapter identities, and two services sharing an
    # identity is the known namespace-collision defect (Q14/Q15) - it would
    # make traffic attribution ambiguous. Remove any other runtime service and
    # wait for its route to disappear before deploying this one.
    existing = api["custom"].list_namespaced_custom_object(
        "serving.kserve.io", "v1alpha2", FIXTURE_NS, "llminferenceservices")
    for item in existing.get("items", []):
        other = item["metadata"]["name"]
        if other == svc:
            continue
        api["custom"].delete_namespaced_custom_object(
            "serving.kserve.io", "v1alpha2", FIXTURE_NS, "llminferenceservices", other)
        def route_gone(name=other):
            try:
                get_route(api, FIXTURE_NS, name)
                return None
            except ApiException as exc:
                return exc.status == 404 or None
        wait_until(route_gone, timeout=120, desc=f"route of displaced service {other} removed")

    manifest = llmisvc_manifest(
        svc, FIXTURE_NS, base, adapters, runtime=True,
        max_adapters=2 * len(adapters),  # controller registers name + FQN aliases
    )
    # Idempotent for focused reruns against a reused cluster. Istio's
    # validation webhook can go down mid-sequence when the service's own route
    # creation re-triggers the mergeHTTPRoutes race, so 500s recover istiod
    # and retry instead of failing the qualification on a provider crash.
    def apply_ignoring_conflict(create):
        def attempt():
            try:
                create()
                return True
            except ApiException as exc:
                if exc.status == 409:
                    return True
                if exc.status == 500 and "webhook" in str(exc.body):
                    ensure_istiod_ready(api, record)
                    return None
                raise
        wait_until(attempt, timeout=300, interval=5, desc="resource applied")

    apply_ignoring_conflict(lambda: create_llmisvc(api, manifest))
    apply_ignoring_conflict(lambda: epp_destination_rule(api, FIXTURE_NS, svc))
    save_resource(f"llmisvc-{svc}.json", manifest)

    pattern = expected_regex(FIXTURE_NS, base, adapters)
    wait_for_header_value(api, FIXTURE_NS, svc, pattern, timeout=300)

    def base_serves():
        code, parsed, _ = probe_completion(record, fq(FIXTURE_NS, base), fq(FIXTURE_NS, base), "canary")
        # vLLM normalizes --served-model-name aliases to the canonical first
        # name for the base model; LoRA modules echo the requested name.
        return code == 200 and parsed and parsed.get("model") in (base, fq(FIXTURE_NS, base))
    wait_until(base_serves, timeout=1500, interval=15, desc=f"{svc} base model serving")
    return pattern


def run_adapter_matrix(api, svc, base, adapters, record):
    """Every adapter through both supported body-name forms, plus the
    header/body mismatch ring and hard negative identities."""
    failures = []
    for adapter in adapters:
        header = fq(FIXTURE_NS, adapter)
        for body in (header, adapter):  # fully-qualified and short body forms
            code, parsed, _ = probe_completion(record, header, body, "adapter")
            served = (parsed or {}).get("model")
            # LoRA modules echo the requested name; accept either form of the
            # same adapter identity, never a different identity.
            if code != 200 or served not in (body, adapter, header):
                failures.append((adapter, body, code, served))
    assert not failures, f"{len(failures)} adapter probes failed: {failures[:5]}"

    # Mismatch ring: header identifies adapter N, body identifies adapter N+1.
    # Under header-only routing this is a named expected gap: the request lands
    # on the same service and vLLM serves the body model. Anything else - a
    # different service, an unexpected error - is a failure now.
    for i, adapter in enumerate(adapters):
        header = fq(FIXTURE_NS, adapter)
        body = adapters[(i + 1) % len(adapters)]
        code, parsed, _ = probe_completion(record, header, body, "mismatch-ring")
        served = (parsed or {}).get("model")
        if code == 200 and served == body:
            record("expected-gap", {"header": header, "body": body,
                                    "note": "header/body disagreement served body model; "
                                            "must become a rejection once body-aware routing lands"})
        elif code in (400, 404, 422):
            record("mismatch-rejected", {"header": header, "body": body, "status": code})
        else:
            raise AssertionError(f"mismatch ring unexpected outcome: {header} vs {body} -> {code} {served}")

    # Hard negatives: unknown, prefix, suffix, and cross-namespace identities
    # must not be served as a routed model.
    for miss in [fq(FIXTURE_NS, "no-such-adapter"),
                 fq(FIXTURE_NS, adapters[0][:-1]),
                 fq(FIXTURE_NS, adapters[0] + "x"),
                 fq("other-namespace", adapters[0])]:
        code, parsed, _ = probe_completion(record, miss, miss, "negative")
        assert code != 200 or not parsed or parsed.get("model") != miss, \
            f"negative identity {miss} was served (status {code})"


@pytest.mark.routing_strategy_readonly
@pytest.mark.smoke
def test_runtime_smoke_traffic(api, strategy, record):
    """Fast profile: a small adapter set, every member exercised end to end
    under the regex strategy through /v1/completions."""
    strategy.require("regex")
    svc, base = "rt-smoke", "rt-smoke-base"
    pattern = deploy_runtime_service(api, svc, base, SMOKE_ADAPTERS, record)
    record("pattern", {"service": svc, "bytes": len(pattern)})
    run_adapter_matrix(api, svc, base, SMOKE_ADAPTERS, record)

    # Supporting evidence: the runtime's own model table via the
    # service-scoped path (bypasses the model-routing header entirely).
    import requests as http
    from conftest import service_url
    table = http.get(f"{service_url(FIXTURE_NS, svc)}/v1/models", timeout=30).json()
    save_resource(f"models-{svc}.json", table)
    listed = {m.get("id") for m in table.get("data", [])}
    for adapter in SMOKE_ADAPTERS:
        assert adapter in listed or fq(FIXTURE_NS, adapter) in listed, \
            f"adapter {adapter} missing from the runtime model table"


@pytest.mark.routing_strategy_readonly
@pytest.mark.capacity
def test_capacity_100_adapters(api, strategy, record):
    """The published claim: 100 adapters plus the base model (101 identities)
    route and serve under the regex strategy, using the versioned realistic-v1
    fixture. Sampling is not sufficient - every identity is exercised."""
    strategy.require("regex")
    svc, base = "rt-cap", "rt-cap-base"
    pattern = deploy_runtime_service(api, svc, base, ADAPTER_NAMES, record)
    assert len(pattern.encode()) <= 4096, f"fixture pattern {len(pattern)}B exceeds the field budget"
    record("pattern", {"service": svc, "bytes": len(pattern), "adapters": len(ADAPTER_NAMES),
                       "identities": len(ADAPTER_NAMES) + 1})

    route = get_route(api, FIXTURE_NS, svc)
    save_resource("route-capacity-100.json", route)
    assert_all_matches_regex(route, pattern)

    run_adapter_matrix(api, svc, base, ADAPTER_NAMES, record)
