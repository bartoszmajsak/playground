# Per-Participant Routes Validation Spike

Validates Gateway API behavior for the controlled deployment routing model before implementing it in the LLMInferenceService controller.

## Design under test

Each participant creates **one HTTPRoute** with three rule types. Two participants = two HTTPRoutes, each carrying the full rule set:

```
route-v1 (oldest = wins precedence for overlapping rules)
├── Rule 1: header X-Model → [v1:9, v2:1]           ← overlapping (identical on both routes)
├── Rule 2: path /publishers/ns/models/name → [v1:9, v2:1]  ← overlapping (identical)
└── Rule 3: path /direct/v1 → [v1]                  ← non-overlapping (unique to v1)

route-v2 (newest = standby for overlapping rules)
├── Rule 1: header X-Model → [v1:9, v2:1]           ← IDENTICAL to route-v1
├── Rule 2: path /publishers/ns/models/name → [v1:9, v2:1]  ← IDENTICAL to route-v1
└── Rule 3: path /direct/v2 → [v2]                  ← non-overlapping (unique to v2)
```

For overlapping rules (1, 2), Gateway API mandates precedence - oldest route wins. Since both routes carry identical weighted backendRefs, it doesn't matter which the gateway selects - the result is the same split. The standby is pre-positioned for failover.

For non-overlapping rules (3), both routes are active concurrently. Each version's direct-access path routes to that version only.

## What's running

- **Namespace** `route-validation` with a standalone Gateway
- **Two echo services** (`echo-v1`, `echo-v2`) using `hashicorp/http-echo` - each returns its version name in the response body, so you can tell which backend served each request
- **route-v1** applied first (via `manifests.yaml`) - becomes the oldest
- **route-v2** applied second (via `route-v2.yaml`) - newer, acts as hot standby
- **validate.sh** sends curl requests through the gateway and counts which backend responds

## Tests

| # | Test | Validates | How |
|---|------|-----------|-----|
| 1 | Route status | Does the gateway report conflict on the standby? | Reads HTTPRoute `.status.parents[].conditions` |
| 2 | Header split | Weighted distribution via model-routing header | 100 requests with `X-Model` header, expect ~90/10 |
| 3 | Publisher path split | Weighted distribution via stable path | 100 requests to `/publishers/ns/models/name`, expect ~90/10 |
| 4 | Direct access | Per-participant paths pin to correct version | 10 requests each to `/direct/v1` and `/direct/v2` |
| 5 | Concurrent | All three patterns work simultaneously | Sends requests to all patterns in sequence, checks no interference |
| 6 | Failover | Standby takes over when active is deleted | Deletes route-v1, verifies route-v2 handles header + publisher path |
| 7 | Weight change | Updated weights propagate to traffic | Patches both routes to 50/50, verifies distribution changes |

## Usage

```bash
# Deploy
kubectl apply -f manifests.yaml
sleep 2
kubectl apply -f route-v2.yaml

# Run
./validate.sh
# or with explicit gateway URL
./validate.sh http://10.96.1.100

# Cleanup
kubectl delete ns route-validation
```

## Configuration

Edit `manifests.yaml` to change `gatewayClassName: istio` for other implementations (e.g., `envoy`, `nginx`).

## Interpreting results

**All pass**: the per-participant route model works on your gateway. Proceed with controller implementation.

**Test 1 - conflict conditions on route-v2**: the controller will need to suppress or ignore these conditions for grouped routes. They're intentional (overlapping matches by design), not misconfiguration.

**Test 6 - failover fails**: standby route didn't take over. Check if the gateway requires explicit route activation or has a propagation delay longer than the test sleep.

**Test 7 - weights don't change**: the gateway may need more time to propagate Envoy config after a route patch. Increase settle time: `ROUTE_VALIDATION_SETTLE=30 ./validate.sh`. If weights never change, the gateway might be caching the old config aggressively.
