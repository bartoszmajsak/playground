# GIE Conformance Findings

**Date:** 2026-07-01
**GIE conformance suite:** v1.4.0 (12 tests)
**Gateway API CRDs:** v1.5.0
**Kubernetes:** v1.36.1 (kind v0.32)

## Results

| Test | Envoy AI GW v1.0.0 | Istio 1.30.2 |
|---|---|---|
| EppUnAvailableFailOpen | PASS | PASS |
| GatewayFollowingEPPRouting | PASS | PASS |
| GatewayFollowingEPPRoutingWithDataParallelism | PASS | PASS |
| **GatewayWeightedAcrossTwoInferencePools** | **FAIL** | PASS |
| **GatewayDestinationEndpointServed** | **FAIL** | PASS |
| HTTPRouteInvalidInferencePoolRef | PASS | PASS |
| HTTPRouteMultipleGatewaysDifferentPools | PASS | PASS |
| HTTPRouteMultipleRulesDifferentPools | PASS | PASS |
| InferencePoolAccepted | PASS | PASS |
| InferencePoolHTTPRoutePortValidation | PASS | PASS |
| InferencePoolInvalidEPPService | PASS | PASS |
| **InferencePoolResolvedRefsCondition** | **FAIL** | PASS |

**Envoy AI Gateway v1.0.0** (on Envoy Gateway v1.8.1): **9 passed, 3 failed.**

**Istio 1.30.2: 12 passed, 0 failed.** Full conformance.

Raw reports:
- [`reports/aigw-v1.0.0-gateway-report.yaml`](reports/aigw-v1.0.0-gateway-report.yaml)
- [`reports/istio-1.30.2-gateway-report.yaml`](reports/istio-1.30.2-gateway-report.yaml)

## Failed: GatewayWeightedAcrossTwoInferencePools

### What the test does

The [GatewayWeightedAcrossTwoInferencePools](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.4.0/conformance/tests/gateway_weighted_two_pools.go) conformance test creates an HTTPRoute with two InferencePool backendRefs at different weights (70/30), sends 200 requests, and asserts the traffic split matches the ratio.

### How Envoy AI Gateway fails

The extension server hard-codes a limit of exactly 1 InferencePool per route rule:

**[`post_route_modify.go:37-38`](https://github.com/envoyproxy/ai-gateway/blob/v1.0.0/internal/extensionserver/post_route_modify.go#L37-L38)**

```go
if len(inferencePools) != 1 {
    return nil, fmt.Errorf("BUG: at most one inferencepool can be referenced per route rule but found %d", len(inferencePools))
}
```

Envoy Gateway's xDS runner receives this gRPC error and skips publishing all xDS resources. The route returns 404.

### Envoy Gateway logs

```
error  xds  skipped publishing xds resources: failed to translate xds ir
  {"error": "rpc error: code = Unknown desc = BUG: at most one inferencepool
            can be referenced per route rule but found 2"}
```

### Impact

Weighted canary rollouts across InferencePools are impossible. The error poisons the entire xDS push, breaking all routes on that listener.

## Failed: GatewayDestinationEndpointServed / InferencePoolResolvedRefsCondition

These are additional conformance gaps in Envoy AI Gateway v1.0.0 surfaced by the v1.4.0 test suite. The `GatewayDestinationEndpointServed` test was added after v1.1.0 and validates that the gateway correctly routes to the specific endpoint selected by the EPP. The `InferencePoolResolvedRefsCondition` test validates the status condition lifecycle when HTTPRoutes referencing an InferencePool are added and removed.

## How to reproduce

```bash
cd conformance/

make test-aigw              # Envoy AI Gateway (expect: 9/12 pass)
make test-istio             # Istio (expect: 12/12 pass)
make compare                # Both in parallel, side by side

# Single test
make test-aigw RUN_TEST=GatewayWeightedAcrossTwoInferencePools
```

The GIE repo is auto-cloned and checked out to v1.4.0 if needed.
