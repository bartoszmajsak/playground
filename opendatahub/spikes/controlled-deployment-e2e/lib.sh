#!/usr/bin/env bash
# Shared helpers for validate.sh and validate-canary.sh

NS="controlled-deployment-spike"
V1="tiny-llama-v1"
V2="tiny-llama-v2"
GROUP="tiny-llama"
MODEL="tiny-llama"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "  ${CYAN}INFO${NC}: $1"; }

# -------------------------------------------------------------------------
# Gateway discovery
# -------------------------------------------------------------------------

GATEWAY_NAME="kserve-ingress-gateway"

discover_gateway() {
    if [[ -n "${GATEWAY_URL:-}" ]]; then return; fi

    local gw_ns="${GATEWAY_NS:-}"
    if [[ -z "$gw_ns" ]]; then
        if kubectl get gateway "$GATEWAY_NAME" -n openshift-ingress >/dev/null 2>&1; then
            gw_ns="openshift-ingress"
        else
            gw_ns="kserve"
        fi
    fi

    local addr
    addr=$(kubectl get gateway "$GATEWAY_NAME" -n "$gw_ns" \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [[ -n "$addr" ]]; then
        GATEWAY_URL="http://$addr"; return
    fi

    addr=$(kubectl get svc -n "$gw_ns" \
        -l "gateway.networking.k8s.io/gateway-name=$GATEWAY_NAME" \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "$addr" ]]; then
        GATEWAY_URL="http://$addr"; return
    fi

    echo "No gateway address found. Pass URL as argument."
    exit 1
}

# -------------------------------------------------------------------------
# Istio workarounds
# -------------------------------------------------------------------------

has_istio() {
    kubectl api-resources --api-group=networking.istio.io 2>/dev/null | grep -q destinationrules
}

apply_peer_authentication() {
    has_istio || return 0
    kubectl apply -f - <<PAEOF 2>/dev/null || true
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: permissive
  namespace: $NS
spec:
  mtls:
    mode: PERMISSIVE
PAEOF
}

patch_epp_tls() {
    has_istio || return 0
    local svc_name
    while IFS= read -r svc_name; do
        [[ -z "$svc_name" ]] && continue
        kubectl apply -f - <<DREOF 2>/dev/null || true
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: ${svc_name}-tls
  namespace: $NS
spec:
  host: "${svc_name}.${NS}.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: SIMPLE
      insecureSkipVerify: true
DREOF
    done < <(kubectl get svc -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep epp || true)
}

# -------------------------------------------------------------------------
# Deploy helpers
# -------------------------------------------------------------------------

ensure_deployed() {
    local overlay_dir="$1"
    local v1_ready v2_ready

    v1_ready=$(kubectl get llmisvc "$V1" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    v2_ready=$(kubectl get llmisvc "$V2" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

    if [[ "$v1_ready" != "True" || "$v2_ready" != "True" ]]; then
        info "Deploying manifests..."
        kubectl apply -k "$overlay_dir" 2>/dev/null
        if kubectl get clusterversion >/dev/null 2>&1; then
            oc adm policy add-scc-to-user privileged -z default -n "$NS" 2>/dev/null || true
        fi
        apply_peer_authentication
        info "Waiting for $V1 to be Ready..."
        kubectl wait llmisvc "$V1" -n "$NS" --for=condition=Ready --timeout=900s
        info "Waiting for $V2 to be Ready..."
        kubectl wait llmisvc "$V2" -n "$NS" --for=condition=Ready --timeout=900s
    fi

    patch_epp_tls
}
