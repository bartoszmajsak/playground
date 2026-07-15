# Envoy (AI) Gateway Weighted Split - InferencePool vs Service

Reproducer for the "at most one inferencepool per route rule" limitation when using weighted traffic splitting with InferencePool backendRefs.

This blocks canary/blue-green rollouts of inference models - you can't gradually shift traffic between two InferencePools (e.g. 90% stable, 10% canary) using standard Gateway API primitives.

## Findings

Tested with Envoy Gateway v1.8.1, AI Gateway v1.0.0, GIE v1.0.2. Validated against the upstream GIE v1.5.0 conformance suite - see [`conformance/`](conformance/).

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
| InferencePool + Service weighted split (plain HTTPRoute) | 200 but weights ignored - ext_proc routes all traffic to pool |
| Pre-existing single-pool (after multi-pool added) | Survives (cached xDS) |
| New single-pool (while multi-pool exists) | Blocked, 404 |
| Single InferencePool (after removing multi-pool) | 200 - recovers |

### How the issue manifests

With a plain HTTPRoute, the route status reports both `Accepted` and `ResolvedRefs` as `True` - everything looks fine from kubectl. The xDS translation silently fails. The only indication is in the Envoy Gateway logs:

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

### Why this is fundamental to the ext_proc architecture

Unclear if that's a deliberate choice or implementation gap.

Currently, the Envoy AI Gateway uses three `ext_proc` filters in its architecture:

1. **Router-level ext_proc** (AI Gateway's own) - parses request body, extracts the `model` field, sets `x-ai-eg-model` header, triggers route re-evaluation via `ClearRouteCache: true`
2. **Upstream-level ext_proc** (AI Gateway's own) - auth injection and request schema translation (e.g. OpenAI -> Bedrock)
3. **InferencePool EPP ext_proc** (one per pool) - the endpoint picker calls the EPP's gRPC service, which sets `x-gateway-destination-endpoint` to a specific pod IP

The critical piece: [`PostClusterModify`](https://github.com/envoyproxy/ai-gateway/blob/v1.0.0/internal/extensionserver/post_cluster_modify.go#L51) converts InferencePool-backed clusters from standard EDS to **`ORIGINAL_DST`** with `HttpHeaderName: "x-gateway-destination-endpoint"`. Envoy routes each request to whatever IP:port the EPP places in that header. The EPP filter is scoped via per-route [`ExtProcPerRoute{Disabled: true}`](https://github.com/envoyproxy/ai-gateway/blob/v1.0.0/internal/extensionserver/post_route_modify.go#L80) so only the matching pool's filter runs.

#### Further analysis

1. **ORIGINAL_DST is single-destination.** Each pool's cluster becomes ORIGINAL_DST with header-based LB. There's no mechanism for "send 90% to pool-A's EPP pick and 10% to pool-B's EPP pick" within a single cluster.

2. **ext_proc scoping is binary.** For a given route, each pool's ext_proc filter is either enabled or disabled - no weights. Two pools competing to set the same `x-gateway-destination-endpoint` header would conflict.

3. **Metadata is singular.** Route and cluster metadata stores the pool reference as a single string, not a list.

The core problem stems from the fact that `ext_proc` runs as part of the HTTP filter chain on each request, before the router makes the final weighted-cluster forwarding decision. If two `ext_proc` filters are configured in the same filter chain, Envoy will execute them sequentially for every matching request; there is no generic “probabilistic filter activation” mechanism that says “run `ext_proc-A` for 90% of requests and `ext_proc-B` for 10%.”

### Mixed backends (InferencePool + Service) are also broken

You might expect that a single InferencePool + a plain Service in the same rule would work - after all, there's only one pool per rule. Unfortunately it doesn't.

`HTTPRoute` rule with `Service weight=9` + `InferencePool weight=1`:

- No xDS errors (only one InferencePool, passes the multi-pool check)
- Route reports `Accepted` and `ResolvedRefs` as `True`
- All requests return 200
- **100% of traffic goes to the InferencePool, 0% to the Service**

The AI Gateway's `PostClusterModify` converts the entire route rule into a single ORIGINAL_DST cluster for the InferencePool. The Service backend is silently dropped:

```json
// What the HTTPRoute declares:
//   backendRefs:
//     - kind: Service, name: canary-v1-svc, weight: 9
//     - kind: InferencePool, name: canary-v2-pool, weight: 1

// What Envoy actually gets:
{
  "route": {
    "cluster": "httproute/.../rule/1"   // single cluster, NOT weighted_clusters
  },
  "metadata": {
    "filter_metadata": {
      "aigateway.envoy.io": {
        "per_route_rule_inference_pool": "ns/canary-v2-inference-pool/..."
      }
    }
  }
}

// That cluster:
{
  "type": "ORIGINAL_DST",
  "lb_policy": "CLUSTER_PROVIDED",
  "original_dst_lb_config": {
    "use_http_header": true,
    "http_header_name": "x-gateway-destination-endpoint"
  }
}
```

There's no `weighted_clusters` in the Envoy config at all. The ext_proc for v2's pool runs on every request, sets `x-gateway-destination-endpoint` to a v2 pod IP, and the ORIGINAL_DST cluster sends it there. The Service backend with weight=9 never existed in Envoy's view.

This is arguably worse than the multi-pool case: no error, no log warning, route looks healthy, traffic flows - but the weight distribution is completely wrong. Silent data plane misconfiguration.

### How Istio handles this differently

Istio takes a fundamentally different approach that separates *which pool* from *which endpoint*:

1. Istiod watches InferencePool CRs and creates **shadow headless Services** for each pool
2. These get **standard EDS clusters** (not ORIGINAL_DST) with endpoints from the pool's pod selector
3. Weighted splitting works at the route level using standard weighted clusters - the same mechanism used for any Service-to-Service split
4. The EPP ext_proc filter runs **after** Envoy has already selected which pool's cluster to use

So Istio's flow is: route matches -> weighted cluster selection picks pool-A or pool-B -> the selected pool's ext_proc runs -> EPP picks the pod. Two stages, cleanly separated.

| Aspect | Envoy AI Gateway | Istio |
|--------|-----------------|-------|
| Pool selection | ext_proc + ORIGINAL_DST (collapsed into one layer) | Standard weighted clusters (data plane routing) |
| Endpoint picking | EPP sets `x-gateway-destination-endpoint` | EPP sets `x-gateway-destination-endpoint` |
| Weighted multi-pool | Not supported (fundamental) | Supported natively |

## Reproducer 

### Setup

Uses the same stack as the upstream `envoyproxy/ai-gateway` inference-pool example: testupstream mock backends, full EPP with plugin config, AIGatewayRoute for routing.

```bash
./setup.sh      # kind + EG v1.8.1 + AI Gateway v1.0.0 + GIE v1.0.2 (matches AI GW's go.mod) + backends + EPP
./validate.sh   # runs all 5 tests with end-to-end traffic checks
```

Override versions with env vars:

```bash
EG_VERSION=v1.8.1 AIEG_VERSION=v0.7.0 GIE_VERSION=v1.5.0 ./setup.sh
```

### Conformance tests

Run the upstream GIE conformance suite against Envoy AI Gateway and Istio for comparison:

```bash
cd conformance/
make test-aigw              # Envoy AI Gateway: 9/12 pass, 3 failed
make test-istio             # Istio 1.30.2: 12/12 pass
make compare                # Both, side by side
```

See [`conformance/FINDINGS.md`](conformance/FINDINGS.md) for details.

### Cleanup

```bash
kind delete cluster --name eg-split-spike
```
