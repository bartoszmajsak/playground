#!/usr/bin/env bash
# Collect exploratory diagnostics for a run into its artifact bundle.
# Read-only; safe to invoke at any point, including after a failed validate.
#
# Usage: ./observe.sh [--run <run-id>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

RUN_ARG=""
if [[ "${1:-}" == "--run" ]]; then RUN_ARG="${2:-}"; fi
load_run "$RUN_ARG"
guard_cluster

OUT_RES="${RUN_DIR}/resources"
OUT_LOG="${RUN_DIR}/logs"
mkdir -p "$OUT_RES" "$OUT_LOG"

info "collecting cluster diagnostics into ${RUN_DIR}"

kc get llminferenceservices -A -o yaml > "${OUT_RES}/llmisvc.yaml" 2>&1 || true
kc get httproutes -A -o yaml > "${OUT_RES}/httproutes.yaml" 2>&1 || true
kc get inferencepools.inference.networking.k8s.io -A -o yaml > "${OUT_RES}/inferencepools.yaml" 2>&1 || true
kc get gateway -A -o yaml > "${OUT_RES}/gateway-status.yaml" 2>&1 || true
kc get configmap inferenceservice-config -n kserve -o yaml > "${OUT_RES}/inferenceservice-config.yaml" 2>&1 || true
kc get events -A --sort-by=.lastTimestamp > "${OUT_RES}/events.txt" 2>&1 || true
kc get pods -A -o wide > "${OUT_RES}/pods.txt" 2>&1 || true

kc logs -n kserve deployment/llmisvc-controller-manager --tail=4000 \
    > "${OUT_LOG}/controller.log" 2>&1 || true
kc logs -n kserve deployment/llmisvc-controller-manager --previous --tail=2000 \
    > "${OUT_LOG}/controller-previous.log" 2>&1 || true
kc logs -n istio-system deployment/istiod --tail=2000 > "${OUT_LOG}/provider.log" 2>&1 || true

# Data-plane acceptance signal: what the proxy actually programmed. An
# HTTPRoute Accepted=True alone is not sufficient (design layer 3).
if command -v istioctl >/dev/null 2>&1; then
    gw_pod="$(kc get pods -n kserve -l serving.kserve.io/gateway=kserve-ingress-gateway \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$gw_pod" ]]; then
        istioctl --kubeconfig "$KUBECONFIG_PATH" proxy-config routes "${gw_pod}.kserve" -o json \
            > "${OUT_RES}/envoy-routes.json" 2>&1 || true
    fi
else
    warn "istioctl not found; skipping envoy route dump"
fi

for ns in $(kc get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -E '^lora-'); do
    for pod in $(kc get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        kc logs -n "$ns" "$pod" --all-containers --tail=1000 \
            > "${OUT_LOG}/${ns}-${pod}.log" 2>&1 || true
    done
done

ok "diagnostics collected: $(du -sh "$RUN_DIR" | cut -f1) in ${RUN_DIR}"
