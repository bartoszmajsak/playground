# GIE Conformance Findings - Envoy AI Gateway

**Date:** 2026-07-03
**GIE conformance suite:** v1.5.0 (13 tests)
**Gateway API CRDs:** v1.5.0
**Kubernetes:** v1.36.1 (kind v0.32)

## Results

### Baseline (Envoy AI GW v1.0.0 unmodified)

| Test | Envoy AI GW v1.0.0 | Istio 1.30.2 |
|---|---|---|
| EppUnAvailableFailOpen | PASS | PASS |
| GatewayDestinationEndpointServed | **FAIL** | PASS |
| GatewayFollowingEPPRouting | PASS | PASS |
| GatewayFollowingEPPRoutingWithDataParallelism | PASS | PASS |
| **GatewayWeightedAcrossTwoInferencePools** | **FAIL** | PASS |
| HTTPRouteInvalidInferencePoolRef | PASS | PASS |
| HTTPRouteMultipleGatewaysDifferentPools | PASS | PASS |
| HTTPRouteMultipleRulesDifferentPools | PASS | PASS |
| InferencePoolAccepted | PASS | PASS |
| InferencePoolAppProtocol (h2c) | **FAIL** | PASS |
| InferencePoolAppProtocol (http) | PASS | PASS |
| InferencePoolAppProtocol (default) | PASS | PASS |
| InferencePoolHTTPRoutePortValidation | PASS | PASS |
| InferencePoolInvalidEPPService | PASS | PASS |
| InferencePoolResolvedRefsCondition | PASS | PASS |

**Envoy AI Gateway v1.0.0 (EG v1.8.1): 10 passed, 3 failed.**

**Istio 1.30.2: 13 passed, 0 failed.** Full conformance.

### With fixes applied

Three changes to `envoy-ai-gateway` bring the score to **12/13**, leaving only the weighted split test:

| Fix | Tests unblocked |
|---|---|
| MetadataOptions + Lua filter for `x-gateway-destination-endpoint-served` | GatewayDestinationEndpointServed |
| h2c upstream protocol options based on InferencePool appProtocol | InferencePoolAppProtocol/h2c |
| (both above combined) | InferencePoolAppProtocol/http, default (already passed) |

Raw report (with fixes): [`reports/aigw-v1.0.0-gateway-report.yaml`](reports/aigw-v1.0.0-gateway-report.yaml)

## Root causes

### 1. Missing `envoy.lb` metadata forwarding (GatewayDestinationEndpointServed)

The [EPP protocol spec](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/docs/proposals/004-endpoint-picker-protocol/README.md#destination-endpoint-served) requires the data plane to populate `envoy.lb["x-gateway-destination-endpoint-served"]` in the ext_proc MetadataContext on the response path.

**Two issues:**

1. The InferencePool ext_proc filter (`buildHTTPFilterForInferencePool`) had no `MetadataOptions`, so Envoy never forwarded the `envoy.lb` namespace to/from the EPP. Fix: add `ReceivingNamespaces` and `ForwardingNamespaces` with `envoy.lb`.

2. The `x-gateway-destination-endpoint-served` key itself was never populated. Istio uses the `OverrideHost` LB policy with `SelectedHostKey` to have Envoy write the served endpoint automatically. The AI gateway uses `ORIGINAL_DST` clusters which lack this mechanism. Fix: a Lua response filter that copies `envoy.lb["x-gateway-destination-endpoint"]` (set by the EPP during request processing) to `envoy.lb["x-gateway-destination-endpoint-served"]`. With `ORIGINAL_DST`, the served endpoint is always the selected endpoint - there is no retry fallback to alternative endpoints.

### 2. Missing h2c upstream protocol options (InferencePoolAppProtocol)

`handleInferencePoolCluster` configures `ORIGINAL_DST` clusters but does not set `TypedExtensionProtocolOptions` based on the InferencePool's `appProtocol` field. When a pool specifies `appProtocol: kubernetes.io/h2c`, the backend expects HTTP/2 cleartext but Envoy sends HTTP/1.1, resulting in 400 responses.

Fix: read `appProtocol` from the unstructured InferencePool resource (the AI gateway depends on GIE v1.0.2 which predates the `AppProtocol` field) and set `Http2ProtocolOptions` on the cluster when h2c is specified.

Note: [GIE #2965](https://github.com/kubernetes-sigs/gateway-api-inference-extension/issues/2965) reports issues with the h2c conformance test fixture itself (echo server serving both protocols from one container). The AI gateway fix is still needed regardless.

### 3. Weighted split across InferencePools (GatewayWeightedAcrossTwoInferencePools)

The conformance test creates an HTTPRoute with two InferencePool `backendRefs` at different weights (80/20). Every request returns **404**.

**Two issues across two repos:**

1. **envoy-ai-gateway** enforces "at most one InferencePool per route rule" (`post_cluster_modify.go:50`, `post_route_modify.go:38`). This is a deliberate design choice, not a bug - the comment says `BUG:` but the constraint is CEL-validated. When triggered, it returns a gRPC error that poisons the entire xDS push, breaking all routes on the listener.

2. **envoy-gateway** (`internal/xds/translator/route.go:351`) skips custom backends when building weighted cluster actions. The condition only checks `len(destinationSetting.Endpoints) > 0 || destinationSetting.IsDynamicResolver` but is missing `|| destinationSetting.IsCustomBackend`.

This is the only remaining conformance gap. Fixing it requires changes in both repos and careful design around multi-EPP routing (each pool has its own EPP, so after the weight split, Envoy needs to call the correct EPP for the selected pool).

## How to reproduce

```bash
cd conformance/

make test-aigw              # Envoy AI Gateway baseline (expect: 10/13 pass)
make test-istio             # Istio (expect: 13/13 pass)
make compare                # Both in parallel, side by side

# With custom controller image (includes fixes):
make test-aigw AIGW_CONTROLLER_IMAGE=docker.io/envoyproxy/ai-gateway-controller:fix-metadata

# Single test
make test-aigw RUN_TEST=GatewayWeightedAcrossTwoInferencePools
```

The GIE repo is auto-cloned and checked out to v1.5.0 if needed.
