# Controlled Deployment E2E Validation Spike

End-to-end validation of canary rollout lifecycle and per-version observability on a real cluster.

## Quick Start

```bash
export LLMISVC_IMAGE=quay.io/bmajsak/llmisvc-controller:traffic-splitting

./setup.sh kind-istio
./validate.sh --smoke
./observe.sh
```

## Setup

```bash
LLMISVC_IMAGE=... ./setup.sh kind-istio     # kind + Istio (local)
LLMISVC_IMAGE=... ./setup.sh openshift      # OCP 4.21+ (assumes OSSM/Sail pre-installed)
```

Versions are fetched automatically from `kserve-deps.env` at the `KSERVE_REF`. Override any version via env var (e.g. `ISTIO_VERSION_OVERRIDE=1.27.1`).

**Prerequisites** - kind-istio: `kind`, Docker, `kubectl`, `helm`. OpenShift: `kubectl`/`oc`.

## Validate

```bash
./validate.sh                              # pool scenario (default)
./validate.sh --smoke                      # core canary lifecycle (steps 1,2,3,5,6,13)
./validate.sh --scenario service           # plain Service backend
./validate.sh --scenario mixed             # v1 InferencePool, v2 Service
./validate.sh --scenario all               # all scenarios in sequence
./validate.sh --scenario all --smoke       # smoke across all scenarios
./validate.sh --phase 1                    # canary lifecycle only
./validate.sh --step 3                     # single step
./validate.sh --skip-deploy                # pods already running
```

### Scenarios

Manifests are kustomize overlays under `manifests/overlays/`:

| Scenario | Description |
|----------|-------------|
| `pool` | Both members use InferencePool (scheduler). Default. |
| `service` | Both members use plain Service backend (no scheduler). |
| `mixed` | v1 with InferencePool, v2 with plain Service. |

### Test Steps

**Phase 1: Canary Rollout Lifecycle** (steps 1-9)

| Step | Action | Verify |
|------|--------|--------|
| 1 | Deploy v1 (w=9) and v2 (w=1) | Ready, group status, routing-group label |
| 2 | Baseline: 90/10 split | ~90/10 weighted split |
| 3 | Canary ramp: v1=7, v2=3 | ~70/30 weighted split |
| 4 | 50/50 split via Prometheus | Observability pipeline validates split |
| 5 | Promote: v1 weight to 0 | 100% to v2 |
| 6 | Direct access | Per-participant paths always hit targeted version |
| 7 | Rollback: v1=9, v2=0 | 100% to v1 |
| 8 | Re-promote, force-stop v1 | Route preserved, GPU reclaimed |
| 9 | Decommission v1 | v2 standalone, group cleanup |

**Phase 2: Error handling** (steps 10-11)

| Step | Action | Verify |
|------|--------|--------|
| 10 | Wrong model.name in group | GroupReady=False, ModelNameAmbiguous |
| 11 | Weight without group | Webhook rejects |

**Phase 3: Publisher path + x-served-by** (steps 12-13)

| Step | Action | Verify |
|------|--------|--------|
| 12 | Publisher path routing | Routed correctly |
| 13 | x-served-by header | Present with LLMISVC name |

**Phase 4: Group lifecycle** (steps 14-18)

| Step | Action | Verify |
|------|--------|--------|
| 14 | Leave group: member removes group field | Label removed, group status updated |
| 15 | N>2 group: three-member weighted routing | 3-way group status, weighted traffic split |
| 16 | Join existing group: v2 arrives after v1 | Late joiner onboarded, routing works |
| 17 | Delete member at weight > 0 | Dangling backendRef cleaned up, remaining member healthy |
| 18 | Force-stop the route owner | Gateway precedence handoff, traffic continues |

**Phase 5: Model name validation** (steps 19-20)

| Step | Action | Verify |
|------|--------|--------|
| 19 | ModelNameAmbiguous: no majority (1 vs 1) | Both members GroupReady=False (symmetric) |
| 20 | GroupDegraded: majority excludes outlier (2 vs 1) | GroupReady=True, GroupDegraded=True/MemberExcluded on all (symmetric) |

### Traffic validation

Most steps use the `x-served-by` response header (fast, per-request attribution). Step 4 uses Prometheus `vllm:request_success_total` by `llm_isvc_name` to validate the observability pipeline end-to-end.

## Zero-Downtime Canary Validation

Runs continuous traffic via k6 while applying the full canary lifecycle in the background, then checks for request errors during each transition.

```bash
./validate-canary.sh                        # deploys pool scenario if needed
./validate-canary.sh --scenario service     # service backend variant
```

The test sends requests at a steady rate (2 req/s default, override with `RATE=5`) while applying six phases over ~3 minutes: baseline (90/10), canary ramp (70/30), 50/50 split, promote, force-stop, and decommission. Each response is logged with its `x-served-by` attribution and timestamp. Since members deploy at weight=1 (not 0), all weight transitions are pure value updates with no structural route changes - avoiding the gateway config reload drops.

After the run, the analysis script checks:
- Per-phase traffic distribution matches expected weights (with 5s grace after each mutation)
- Zero request errors during transition windows
- Final verdict: `ZERO DOWNTIME` or `DOWNTIME DETECTED` with details

Requires: `k6` (`go install go.k6.io/k6@latest`)

## Observe

```bash
./observe.sh
```

Explores per-version metrics, traces, and response headers. Requires both v1 and v2 deployed.

| Channel | Per-version label | Source |
|---|---|---|
| x-served-by header | Response header | Client-side |
| Istio gateway metrics | `destination_canonical_service` | Native |
| vLLM metrics | `llm_isvc_name` | PodMonitor relabeling |
| EPP scheduler metrics | `job` label | ServiceMonitor with SA auth |
| OTEL traces | `llmisvc.name` | Jaeger via `spec.tracing` |

See `docs/observability-findings.md` for PromQL examples and gap analysis.

## Gateway Compatibility

| Gateway | Weighted multi-pool split | Notes |
|---------|--------------------------|-------|
| Istio 1.27+ | Supported | Tested on 1.27.1, 1.28.0, 1.30.1 |
| Envoy AI Gateway | Not supported | "at most one inferencepool per route rule" - [see reproducer](https://github.com/bartoszmajsak/playground/tree/main/opendatahub/spikes/envoy-gateway-weighted-split) |
| OpenShift | Depends on Istio version | |

## Operational Characteristics

- **Canary onboarding at weight=1**: members deploy at weight=1 (not 0) so the gateway has all backends warmed from the start. Changing weight from 0 to non-zero triggers a structural HTTPRoute change (new backendRef) that causes gateway config reload and brief request drops. Starting at weight=1 keeps subsequent weight changes as pure value updates - no route structure changes, no drops. See `docs/research-zero-downtime-routing.md` for the full analysis.

## Known Issues

- **EPP TLS workaround**: upstream controller always mounts self-signed certs, EPP defaults `--secure-serving=true`. Istio needs DestinationRules for TLS origination. See [kserve/kserve#5716](https://github.com/kserve/kserve/pull/5716), [opendatahub-io/kserve#1595](https://github.com/opendatahub-io/kserve/pull/1595).
:x
## Cleanup

```bash
kubectl delete namespace controlled-deployment-spike
kind delete cluster
```
