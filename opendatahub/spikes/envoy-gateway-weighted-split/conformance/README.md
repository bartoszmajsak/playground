# GIE Conformance Tests

Runs the upstream [Gateway API Inference Extension conformance suite](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/main/conformance) against gateway implementations. Fresh kind cluster per run, YAML report output.

## Prerequisites

Docker, [kind](https://kind.sigs.k8s.io/) v0.32+, kubectl, helm, Go 1.25+

## Usage

```bash
make test-aigw             # Envoy AI Gateway (fresh cluster)
make test-istio            # Istio (fresh cluster)
make compare               # Both, side by side

# Single test
make test-aigw  RUN_TEST=GatewayWeightedAcrossTwoInferencePools
make test-istio RUN_TEST=GatewayWeightedAcrossTwoInferencePools
```

Each `make test-*` tears down any previous cluster, creates a fresh one, installs everything, runs the suite, and leaves the cluster up for inspection. The GIE repo is auto-cloned and checked out to the right tag if needed.

```bash
make teardown-aigw         # Delete Envoy AI Gateway cluster
make teardown-istio        # Delete Istio cluster
```

## Default versions

| Component | Version |
|---|---|
| GIE conformance suite | v1.4.0 |
| Gateway API CRDs | v1.5.0 |
| Envoy Gateway | v1.8.1 |
| Envoy AI Gateway | v1.0.0 |
| Istio | 1.30.2 |
| Kubernetes (kind) | v1.36.1 |
| MetalLB | v0.13.10 |

All overridable via Make variables. Run `make help` for the full list.

## Findings

See [FINDINGS.md](FINDINGS.md).
