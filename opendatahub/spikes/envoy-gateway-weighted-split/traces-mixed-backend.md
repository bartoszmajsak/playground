# Traces: Mixed Backend (InferencePool + Service) Weighted Split

**Stack:** docker.io/envoyproxy/gateway:v1.8.1 + docker.io/envoyproxy/ai-gateway-controller:v1.0.0
**Scenario:** model-v1 (Service, weight=9) + pool-v2 (InferencePool, weight=1)
**Date:** 2026-07-02

## HTTPRoute

```yaml
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: test-gateway
  rules:
  - backendRefs:
    - group: ""
      kind: Service
      name: model-v1
      port: 8080
      weight: 9
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: pool-v2
      weight: 1
    matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
```

## Result

All 200 OK, but **100% of traffic goes to InferencePool (pool-v2)**. Service weight=9 is silently ignored.

The xDS config shows a single ORIGINAL_DST cluster for the entire rule - no weighted_clusters, no Service backend.

## Envoy Route Config

```json
{
  "match": {
    "path_separated_prefix": "/v1/chat/completions"
  },
  "route": {
    "cluster": "httproute/eg-split-test/mixed-weighted/rule/0",
    "auto_host_rewrite": false,
    "upgrade_configs": [
      {
        "upgrade_type": "websocket"
      }
    ]
  },
  "metadata": {
    "filter_metadata": {
      "aigateway.envoy.io": {
        "per_route_rule_inference_pool": "eg-split-test/pool-v2/pool-v2-epp/9002/duplex/false"
      },
      "envoy-gateway": {
        "resources": [
          {
            "namespace": "eg-split-test",
            "kind": "HTTPRoute",
            "name": "mixed-weighted"
          }
        ]
      }
    }
  },
  "typed_per_filter_config": {
    "envoy.filters.http.ext_proc/endpointpicker/pool-v1_eg-split-test_ext_proc": {
      "@type": "type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExtProcPerRoute",
      "disabled": true
    }
  },
  "name": "httproute/eg-split-test/mixed-weighted/rule/0/match/0/*"
}
```

## Envoy Cluster Config

```json
{
  "name": "httproute/eg-split-test/mixed-weighted/rule/0",
  "type": "ORIGINAL_DST",
  "lb_policy": "CLUSTER_PROVIDED",
  "original_dst_lb_config": {
    "use_http_header": true,
    "http_header_name": "x-gateway-destination-endpoint"
  }
}
```

## Key finding

The route action uses `cluster` (single), not `weighted_clusters`. The cluster type is `ORIGINAL_DST` with header-based LB via `x-gateway-destination-endpoint`. The Service backend with weight=9 doesn't appear anywhere in the Envoy config - it was dropped during xDS translation by the AI Gateway extension server.

## EG Logs

```

```
