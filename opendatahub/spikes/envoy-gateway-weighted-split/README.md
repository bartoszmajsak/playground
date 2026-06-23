# Envoy Gateway Weighted Split - InferencePool vs Service

Reproducer for the "at most one inferencepool per route rule" limitation when using weighted traffic splitting with InferencePool backendRefs.

This blocks canary/blue-green rollouts of inference models - you can't gradually shift traffic between two InferencePools (e.g. 90% stable, 10% canary) using standard Gateway API primitives.

## Findings

Tested with EG v1.8.1 + AI Gateway v1.0.0 + GIE v1.0.2.

The limitation is still there, enforced at **two levels**:

1. **AIGatewayRoute CRD validation** rejects multi-pool rules at admission: `only one InferencePool backend is allowed per rule`
2. **xDS translation** rejects any HTTPRoute (whether hand-crafted or generated) with multiple InferencePool backendRefs: `BUG: at most one inferencepool can be referenced per route rule`

It gets worse though - the xDS failure is fatal for the **entire** push, not just the offending route. Pre-existing single-pool routes survive (Envoy keeps cached xDS), but any new InferencePool route created while the multi-pool route exists can never enter the Envoy config. One bad route poisons all new InferencePool routing on the gateway. Removing the offending route restores everything immediately.

| Test | Result |
|------|--------|
| Service weighted split (9:1) | 200 - works end-to-end |
| Single InferencePool via AIGatewayRoute | 200 - works end-to-end |
| Multi-InferencePool weighted split (AIGatewayRoute) | Rejected at admission |
| Multi-InferencePool weighted split (plain HTTPRoute) | xDS rejected, 404 |
| Pre-existing single-pool (after multi-pool added) | Survives (cached xDS) |
| New single-pool (while multi-pool exists) | Blocked, 404 |
| Single InferencePool (after removing multi-pool) | 200 - recovers |

### How the issue manifests

When bypassing AIGatewayRoute validation with a plain HTTPRoute, the route status reports both `Accepted` and `ResolvedRefs` as `True` - everything looks fine from kubectl. The xDS translation silently fails. The only indication is in the Envoy Gateway logs:

```
error  xds  skipped publishing xds resources: failed to translate xds ir
  {"error": "BUG: at most one inferencepool can be referenced per route rule but found 2"}
```

No Envoy config is generated for the route, so traffic returns 404 with no surface-level clue why. You have to dig into the EG pod logs to find the real cause.

### Where the limitation lives

The rejection happens in the **Envoy AI Gateway controller** (`envoyproxy/ai-gateway`), not in Envoy Gateway itself:

- CRD validation: [`AIGatewayRouteRule`](https://github.com/envoyproxy/ai-gateway/blob/v1.0.0/api/v1alpha1/ai_gateway_route_types.go) - rejects at admission
- xDS translation: [`PostRouteModify`](https://github.com/envoyproxy/ai-gateway/blob/v1.0.0/internal/extensionserver/post_route_modify.go#L38) and [`PostClusterModify`](https://github.com/envoyproxy/ai-gateway/blob/v1.0.0/internal/extensionserver/post_cluster_modify.go#L51) - enforce `len(inferencePools) != 1`

The error is prefixed with "BUG:" which suggests the authors consider this an unexpected state rather than a deliberate limitation. The fix needs to happen in `envoyproxy/ai-gateway`, not `envoyproxy/gateway`.

## Setup

Uses the same stack as the upstream `envoyproxy/ai-gateway` inference-pool example: testupstream mock backends, full EPP with plugin config, AIGatewayRoute for routing.

```bash
./setup.sh      # kind + EG v1.8.1 + AI Gateway v1.0.0 + GIE v1.0.2 + backends + EPP
./validate.sh   # runs all 5 tests with end-to-end traffic checks
```

Override versions with env vars:

```bash
EG_VERSION=v1.8.1 AIEG_VERSION=v0.7.0 GIE_VERSION=v1.5.0 ./setup.sh
```

## Cleanup

```bash
kind delete cluster --name eg-split-spike
```
