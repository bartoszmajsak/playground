#!/usr/bin/env bash
# AgentGateway BackendRef Override Spike - Cluster Setup
#
# Sets up kind + AgentGateway + LLMISVC controller to validate PR kserve/website#697:
# overriding HTTPRoute backendRef to AgentgatewayBackend for LLM-aware routing.
#
# Usage:
#   LLMISVC_IMAGE=quay.io/bmajsak/llmisvc-controller:traffic-splitting ./setup.sh
#
# Environment:
#   LLMISVC_IMAGE  - Pre-built controller image (required)
#   KSERVE_REF     - Git ref for kserve manifests (default: master)
#   CLUSTER_NAME   - Kind cluster name (default: agentgateway-spike)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="agentgateway-spike"
CLUSTER_NAME="${CLUSTER_NAME:-agentgateway-spike}"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"

KSERVE_REPO="${KSERVE_REPO:-bartoszmajsak/kserve}"
KSERVE_REF="${KSERVE_REF:-upstream/feat/x-served-by}"
KSERVE_RAW="https://raw.githubusercontent.com/${KSERVE_REPO}/${KSERVE_REF}"
KSERVE_KUSTOMIZE="https://github.com/${KSERVE_REPO}/config"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

# Versions
load_kserve_deps() {
    local deps_url="${KSERVE_RAW}/kserve-deps.env"
    local deps
    deps=$(curl -sf "$deps_url" 2>/dev/null || true)
    if [[ -z "$deps" ]]; then
        echo -e "${YELLOW}WARNING${NC}: Could not fetch kserve-deps.env from $deps_url, using defaults"
        return
    fi
    eval "$(echo "$deps" | grep -E '^[A-Z_]+=' | grep -v '^OVERRIDE_' | sed 's/^/export /')"
}
load_kserve_deps

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.0}"
GIE_VERSION="${GIE_VERSION:-v1.5.0}"
LWS_VERSION="${LWS_VERSION:-v0.8.0}"
AGENTGATEWAY_VERSION="${AGENTGATEWAY_VERSION:-v1.3.1}"

info() { echo -e "${YELLOW}INFO${NC}: $1"; }
ok()   { echo -e "${GREEN}  OK${NC}: $1"; }
err()  { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

# -------------------------------------------------------------------------
# Kind cluster + MetalLB
# -------------------------------------------------------------------------

setup_kind_cluster() {
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        info "Kind cluster '${CLUSTER_NAME}' already exists"
    else
        info "Creating kind cluster '${CLUSTER_NAME}'"
        cat <<KINDEOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
KINDEOF
    fi
    kind get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG}"

    info "Installing MetalLB"
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
    kubectl wait --timeout=120s --namespace metallb-system \
        deployment/controller --for=condition=Available || err "MetalLB controller not ready"

    local subnet
    subnet=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -v ':' | head -1)
    subnet="${subnet:-172.18.0.0/16}"
    local base
    base=$(echo "$subnet" | cut -d. -f1-2)
    kubectl apply -f - <<METALEOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${base}.255.200-${base}.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
METALEOF
}

# -------------------------------------------------------------------------
# LLMISVC controller
# -------------------------------------------------------------------------

deploy_kserve_llmisvc() {
    local llmisvc_img="${LLMISVC_IMAGE:-quay.io/bmajsak/llmisvc-controller:traffic-splitting}"
    if [[ -z "$llmisvc_img" ]]; then
        err "LLMISVC_IMAGE is required. Set it to a pre-built controller image (e.g., quay.io/bmajsak/llmisvc-controller:traffic-splitting)"
    fi

    info "Deploying KServe LLMISVC (image: $llmisvc_img, ref: $KSERVE_REF)"
    kubectl create namespace kserve 2>/dev/null || true

    info "Applying CRDs"
    kubectl apply --server-side=true --force-conflicts \
        -k "${KSERVE_KUSTOMIZE}/crd/full/llmisvc?ref=${KSERVE_REF}"
    kubectl wait --for=condition=established --timeout=60s crd/llminferenceserviceconfigs.serving.kserve.io \
        || err "CRDs not established"

    kubectl apply -f "${KSERVE_RAW}/config/certmanager/issuer.yaml"
    kubectl apply -f "${KSERVE_RAW}/config/configmap/inferenceservice.yaml"

    # Enable Gateway API and set gateway ref - point to agentgateway
    info "Enabling Gateway API (gateway: kserve/kserve-ingress-gateway, class: agentgateway)"
    local ingress_json
    ingress_json=$(kubectl get configmap inferenceservice-config -n kserve \
        -o jsonpath='{.data.ingress}' | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
cfg['enableGatewayApi'] = True
cfg['kserveIngressGateway'] = 'kserve/kserve-ingress-gateway'
cfg['ingressClassName'] = 'agentgateway'
print(json.dumps(cfg))
")
    kubectl patch configmap inferenceservice-config -n kserve --type merge \
        -p "{\"data\":{\"ingress\":$(printf '%s' "$ingress_json" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')}}"

    info "Applying LLMISVC controller manifests"
    kubectl apply --server-side=true --force-conflicts \
        -k "${KSERVE_KUSTOMIZE}/llmisvc?ref=${KSERVE_REF}"

    info "Patching controller image to $llmisvc_img"
    kubectl set image -n kserve deployment/llmisvc-controller-manager \
        manager="$llmisvc_img"
    kubectl patch deployment/llmisvc-controller-manager -n kserve --type=json \
        -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]'

    kubectl rollout status deployment/llmisvc-controller-manager -n kserve --timeout=120s

    info "Applying well-known configs"
    kubectl apply --server-side=true --force-conflicts \
        -k "${KSERVE_KUSTOMIZE}/llmisvcconfig?ref=${KSERVE_REF}"

    kubectl create namespace "$NS" 2>/dev/null || true
}

# -------------------------------------------------------------------------
# AgentGateway
# -------------------------------------------------------------------------

install_agentgateway() {
    info "Installing AgentGateway CRDs ${AGENTGATEWAY_VERSION}"
    helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
        --create-namespace --namespace agentgateway-system \
        --version "${AGENTGATEWAY_VERSION}" \
        --set controller.image.pullPolicy=Always

    info "Installing AgentGateway control plane ${AGENTGATEWAY_VERSION}"
    helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
        --namespace agentgateway-system \
        --version "${AGENTGATEWAY_VERSION}" \
        --set controller.image.pullPolicy=Always \
        --set inferenceExtension.enabled=true \
        --wait

    kubectl wait --timeout=120s -n agentgateway-system \
        deployment -l app.kubernetes.io/name=agentgateway --for=condition=Available \
        || err "AgentGateway control plane not ready"

    ok "AgentGateway ${AGENTGATEWAY_VERSION} installed"
}

# -------------------------------------------------------------------------
# Main setup
# -------------------------------------------------------------------------

wait_for_gateway() {
    local gw_name="$1" gw_ns="$2"
    info "Waiting for gateway address..."
    for _ in $(seq 1 30); do
        local gw_url
        gw_url=$(kubectl get gateway "$gw_name" -n "$gw_ns" \
            -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
        if [[ -n "$gw_url" ]]; then
            echo ""
            info "Gateway URL: http://$gw_url"
            echo ""
            echo "  ./validate.sh"
            return 0
        fi
        sleep 2
    done
    err "Gateway $gw_ns/$gw_name has no address after 60s"
}

setup() {
    info "Setting up kind cluster with AgentGateway"
    setup_kind_cluster

    # cert-manager
    info "Installing cert-manager ${CERT_MANAGER_VERSION}"
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    kubectl wait --timeout=120s -n cert-manager \
        deployment/cert-manager-webhook --for=condition=Available || err "cert-manager not ready"

    # Gateway API CRDs (v1.5.0 per agentgateway docs)
    info "Installing Gateway API CRDs"
    kubectl apply --server-side --force-conflicts \
        -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml" 2>/dev/null || true

    # Gateway Inference Extension CRDs (needed by LLMISVC controller for InferencePool)
    info "Installing Gateway Inference Extension CRDs ${GIE_VERSION}"
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml"

    # LWS
    info "Installing LWS ${LWS_VERSION}"
    kubectl apply --server-side -f "https://github.com/kubernetes-sigs/lws/releases/download/${LWS_VERSION}/manifests.yaml"
    kubectl wait --timeout=120s -n lws-system deployment/lws-controller-manager --for=condition=Available \
        || err "LWS controller not ready"

    # AgentGateway
    install_agentgateway

    # Gateway resource - agentgateway as the implementation
    kubectl create namespace kserve 2>/dev/null || true
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kserve-ingress-gateway
  namespace: kserve
spec:
  gatewayClassName: agentgateway
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
  infrastructure:
    labels:
      serving.kserve.io/gateway: kserve-ingress-gateway
EOF

    # LLMISVC controller
    deploy_kserve_llmisvc

    ok "Setup complete (kind + AgentGateway)"
    wait_for_gateway "kserve-ingress-gateway" "kserve"
}

# =========================================================================

echo -e "${BOLD}AgentGateway BackendRef Override Spike - Setup${NC}"
echo "Cluster: $CLUSTER_NAME (kubeconfig: $KUBECONFIG)"
echo "Image: ${LLMISVC_IMAGE:-<required>}"
echo "KServe ref: $KSERVE_REF"
echo "AgentGateway: $AGENTGATEWAY_VERSION"
echo ""

setup
