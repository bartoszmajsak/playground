# Per-Participant Routes Validation Spike

Validates Gateway API behavior for the controlled deployment routing model before implementing it in the LLMInferenceService controller.

## Design under test

Each participant creates **one HTTPRoute** with three rule types. Two participants = two HTTPRoutes, each carrying the full rule set:

```
route-v1 (oldest = wins precedence for overlapping rules)
├── Rule 1: header X-Gateway-Model-Name → [v1:9, v2:1]           ← overlapping (identical on both routes)
├── Rule 2: path /publishers/ns/models/name → [v1:9, v2:1]  ← overlapping (identical)
└── Rule 3: path /direct/v1 → [v1]                  ← non-overlapping (unique to v1)

route-v2 (newest = standby for overlapping rules)
├── Rule 1: header X-Gateway-Model-Name → [v1:9, v2:1]           ← IDENTICAL to route-v1
├── Rule 2: path /publishers/ns/models/name → [v1:9, v2:1]  ← IDENTICAL to route-v1
└── Rule 3: path /direct/v2 → [v2]                  ← non-overlapping (unique to v2)
```

For overlapping rules (1, 2), Gateway API mandates precedence - oldest route wins. Since both routes carry identical weighted backendRefs, it doesn't matter which the gateway selects - the result is the same split. The standby is pre-positioned for failover.

For non-overlapping rules (3), both routes are active concurrently. Each version's direct-access path routes to that version only.

## Gateway API model summary

This spike relies on standard HTTPRoute merge and precedence behavior:

- Multiple `HTTPRoute`s can attach to one Gateway listener and are merged into one routing table.
- For each request, one winning rule is selected by match precedence: exact path, longest prefix, method, number of headers, number of query params.
- If still tied across routes, Gateway API tie-breakers apply: oldest route wins, then lexical `{namespace}/{name}`.
- Because overlapping rules are intentionally identical on `route-v1` and `route-v2`, either winner produces the same weighted split.
- Non-overlapping direct paths (`/direct/v1`, `/direct/v2`) should both be active while both routes are accepted by the Gateway.

This validator enforces that model strictly: both `route-v1` and `route-v2` must be `Accepted=True` before traffic tests proceed.

## What's running

- **Namespace** `route-validation` with a standalone Gateway
- **Two echo services** (`echo-v1`, `echo-v2`) using `hashicorp/http-echo` - each returns its version name in the response body, so you can tell which backend served each request
- **route-v1** applied first (via `manifests.yaml`) - becomes the oldest
- **route-v2** applied second (via `route-v2.yaml`) - newer, acts as hot standby
- **validate.sh** sends curl requests through the gateway and counts which backend responds
- Before tests, **validate.sh** waits for the gateway endpoint to serve real routed traffic (helps on first-run ELB/DNS propagation)
- **validate-k6.js** runs parallel load checks for header/publisher/direct patterns
- **validate-k6.sh** discovers gateway URL and launches `k6 run validate-k6.js`
- During setup, **validate.sh** deletes/recreates both routes so `route-v1` is always older than `route-v2` before failover tests

## Tests

| # | Test | Validates | How |
|---|------|-----------|-----|
| 1 | Route status | Are both routes attached and fully resolved? | Asserts `Accepted=True` and `ResolvedRefs=True` for both routes |
| 2 | Header split | Weighted distribution via model-routing header | 100 requests with `X-Gateway-Model-Name` header, expect ~90/10 |
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

## Parallel load validation with k6

Use this when you want a concurrent counterpart to `validate.sh` traffic tests.

```bash
# Requires routes already deployed (manifests.yaml + route-v2.yaml)

# Auto-discover gateway URL and run parallel scenarios
./validate-k6.sh

# Or pass gateway URL explicitly
./validate-k6.sh http://10.96.1.100

# Run longer/harder
ROUTE_VALIDATION_K6_DURATION=60s \
ROUTE_VALIDATION_K6_HEADER_VUS=50 \
ROUTE_VALIDATION_K6_PUBLISHER_VUS=50 \
ROUTE_VALIDATION_K6_DIRECT_V1_VUS=20 \
ROUTE_VALIDATION_K6_DIRECT_V2_VUS=20 \
./validate-k6.sh
```

`validate-k6.js` runs four scenarios concurrently for the same routing model:

- Header match split (`/` + `X-Gateway-Model-Name`)
- Publisher path split (`/publishers/...`)
- Direct `/direct/v1` pinned to v1
- Direct `/direct/v2` pinned to v2

## Configuration

Edit `manifests.yaml` to change `gatewayClassName: istio` for other implementations (e.g., `envoy`, `nginx`).

Distribution thresholds are configurable:

- `ROUTE_VALIDATION_SPLIT_90_MIN` / `ROUTE_VALIDATION_SPLIT_90_MAX` (defaults: `82` / `97`)
- `ROUTE_VALIDATION_SPLIT_50_MIN` / `ROUTE_VALIDATION_SPLIT_50_MAX` (defaults: `35` / `65`)
- `ROUTE_VALIDATION_GATEWAY_READY_TIMEOUT` (default: `180`, seconds)
- `ROUTE_VALIDATION_GATEWAY_READY_INTERVAL` (default: `3`, seconds)

k6-specific knobs:

- `ROUTE_VALIDATION_K6_DURATION` (default: `30s`)
- `ROUTE_VALIDATION_K6_HEADER_VUS` (default: `20`)
- `ROUTE_VALIDATION_K6_PUBLISHER_VUS` (default: `20`)
- `ROUTE_VALIDATION_K6_DIRECT_V1_VUS` (default: `10`)
- `ROUTE_VALIDATION_K6_DIRECT_V2_VUS` (default: `10`)
- `ROUTE_VALIDATION_K6_REQUEST_TIMEOUT` (default: `5s`)

## Interpreting results

**All pass**: the per-participant route model works on your gateway. Proceed with controller implementation.

**Test 1 - `route-v2` not accepted**: this gateway behavior does not fit the strict standby model in this spike. If `route-v2` is not attached, `/direct/v2` and failover guarantees are not reliable.

**Test 6 - failover fails**: standby route didn't take over. Check if the gateway requires explicit route activation or has a propagation delay longer than the test sleep.

**Test 7 - weights don't change**: the gateway may need more time to propagate Envoy config after a route patch. Increase settle time: `ROUTE_VALIDATION_SETTLE=30 ./validate.sh`. If weights never change, the gateway might be caching the old config aggressively.
