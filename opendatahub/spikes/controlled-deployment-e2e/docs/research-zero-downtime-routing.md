# Zero-Downtime During Gateway API Weight Changes

Research into whether gateway implementations guarantee zero dropped requests during HTTPRoute weight transitions, and what patterns mitigate drops in practice.

## The problem

When an HTTPRoute's backendRef weights change - especially when a backend goes from weight=0 to non-zero for the first time - the gateway must reload its routing config. During that reload window, some requests can be dropped.

In our canary test at 2 req/s, we observed 5 connection timeouts and a 28s propagation delay when v2's weight changed from 0 to 1. All subsequent weight changes (1->5, 5->0, etc.) were clean.

## Does the spec guarantee zero downtime?

No. The [Gateway API traffic splitting guide](https://gateway-api.sigs.k8s.io/guides/traffic-splitting/) describes weight semantics but makes no mention of atomicity, zero-downtime guarantees, or what happens to in-flight requests during weight changes. There is no GEP for zero-downtime route updates, and it's not part of the [conformance test suite](https://gateway-api.sigs.k8s.io/concepts/conformance/).

Envoy's xDS protocol is explicitly eventually consistent: "traffic may drop briefly during updates" ([xDS protocol docs](https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol)).

## How do implementations behave?

The [gateway-api-bench](https://github.com/howardjohn/gateway-api-bench) project tests whether implementations return 100% 200 responses during route modifications:

| Implementation | Zero-downtime route updates | Notes |
|---|---|---|
| Istio | Pass | RDS updates are graceful, no connection draining |
| Kgateway | Pass | |
| Traefik | Pass | |
| Kong | Pass | |
| Envoy Gateway | Fail | 503s and 500s throughout transitions |
| Cilium | Fail | 503s during changes |
| Nginx | Fail | Crashlooped |

Istio passes because Envoy's RDS (route) updates are swapped gracefully without draining connections. The risk increases when a **new cluster** must be added to Envoy's config (a structural change), which is what happens when a backend goes from weight=0 to weight=non-zero.

## Why weight=0 to weight=1 is the dangerous transition

Envoy processes different xDS resource types with different levels of disruption:

- **RDS (Route) updates**: graceful swap, no connection draining - this is a pure weight change
- **CDS (Cluster) updates**: all existing connection pools are drained and reconnected - this happens when a new backend cluster appears in the route
- **EDS (Endpoint) updates**: least disruptive

When v2 is at weight=0, the gateway may not have v2's cluster/endpoints warmed. Changing to weight=1 triggers both a CDS update (new cluster) and an RDS update (new backendRef in the route). The CDS update causes the brief disruption.

Subsequent weight changes (1->5, 5->50, etc.) are pure RDS updates on an already-warmed cluster - no disruption.

## The fix: onboard at weight=1, not weight=0

The safest pattern: always keep backends in the route with weight >= 1. Never truly "add" a backend via a weight change from 0.

For canary rollouts this means:
- Deploy v2 at `weight: 1` (gets ~10% of traffic in a 9/1 split)
- Increase to desired canary weight when ready
- This avoids the structural route change that causes drops

The trade-off: v2 gets a small trickle of traffic immediately on deployment. For LLM inference this is actually desirable - it validates the new version's vLLM/EPP stack handles real requests before ramping up.

## Istio propagation delay

Even for pure weight changes, Istio batches xDS pushes via debounce:

- `PILOT_DEBOUNCE_AFTER`: delay before pushing (default 100ms)
- `PILOT_DEBOUNCE_MAX`: maximum debounce window (default 10s)

[Airbnb observed](https://medium.com/airbnb-engineering/improving-istio-propagation-delay-d4da9b5b9f90) P90 propagation delay of 1.5-4.5s depending on Istio version, with worst cases exceeding 100s under lock contention. There is no API to confirm propagation is complete ([istio/istio#23956](https://github.com/istio/istio/issues/23956)).

## Additional mitigations

**Retry policies** - configure on the gateway to handle transient failures during propagation:
```
retryOn: connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes
```

**Outlier detection** - via DestinationRule to eject unhealthy endpoints quickly:
```yaml
outlierDetection:
  consecutive5xxErrors: 3
  interval: 10s
  baseEjectionTime: 30s
```

**Make-before-break ordering** - when adding a new backend: deploy pods, wait for readiness, then update weights. When removing: update weights first, then delete.

**Progressive rollout controllers** - Flagger and Argo Rollouts automate weight transitions with metric validation between steps.

## Sources

- [Gateway API traffic splitting guide](https://gateway-api.sigs.k8s.io/guides/traffic-splitting/)
- [Gateway API conformance](https://gateway-api.sigs.k8s.io/concepts/conformance/)
- [gateway-api-bench results](https://github.com/howardjohn/gateway-api-bench)
- [Envoy xDS protocol docs](https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol)
- [Envoy draining docs](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/draining)
- [Airbnb - Improving Istio Propagation Delay](https://medium.com/airbnb-engineering/improving-istio-propagation-delay-d4da9b5b9f90)
- [Istio #23956 - No API to verify propagation](https://github.com/istio/istio/issues/23956)
- [Istio #36021 - Empty weighted_clusters breaks routing](https://github.com/istio/istio/issues/36021)
- [Istio #29310 - 503 NR during VirtualService updates](https://github.com/istio/istio/issues/29310)
- [Envoy #12095 - Versioned atomic updates proposal](https://github.com/envoyproxy/envoy/issues/12095)
