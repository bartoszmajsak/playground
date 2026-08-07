#!/usr/bin/env bash
# Body-Based Routing Spike - Cluster Setup
#
# Kind cluster + MetalLB + Gateway API + Istio + a Gateway. Nothing else -
# the spike only needs an Istio-managed Envoy we can patch with an EnvoyFilter.
# Scoped kubeconfig, does not touch ~/.kube/config.
#
# Usage:
#   ./setup.sh
#
# Environment:
#   CLUSTER_NAME    Kind cluster name (default: bbr-spike)
#   ISTIO_VERSION   Istio helm chart version (default: 1.28.1)
#   GWAPI_VERSION   Gateway API CRD version (default: v1.4.1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-bbr-spike}"
NS="${NS:-bbr-spike}"
ISTIO_VERSION="${ISTIO_VERSION:-1.28.1}"
GWAPI_VERSION="${GWAPI_VERSION:-v1.4.1}"

export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${YELLOW}INFO${NC}: $1"; }
ok()   { echo -e "${GREEN}  OK${NC}: $1"; }
err()  { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

# -------------------------------------------------------------------------
# Kind cluster
# -------------------------------------------------------------------------

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "Kind cluster '${CLUSTER_NAME}' already exists"
else
    info "Creating kind cluster '${CLUSTER_NAME}'"
    kind create cluster --name "$CLUSTER_NAME"
fi
kind get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG}"

# Scripts here use the scoped kubeconfig above so parallel kind clusters don't
# fight over a context. Also register "kind-${CLUSTER_NAME}" in the default
# kubeconfig so `kubectl --context kind-${CLUSTER_NAME}` works from any shell,
# without stealing the current context.
default_kubeconfig="${HOME}/.kube/config"
if [[ -f "$default_kubeconfig" ]]; then
    prev_ctx=$(KUBECONFIG="$default_kubeconfig" kubectl config current-context 2>/dev/null || true)
    KUBECONFIG="$default_kubeconfig" kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null
    [[ -n "$prev_ctx" ]] && KUBECONFIG="$default_kubeconfig" \
        kubectl config use-context "$prev_ctx" >/dev/null 2>&1 || true
    info "Context 'kind-${CLUSTER_NAME}' available: kubectl --context kind-${CLUSTER_NAME} ..."
fi

# -------------------------------------------------------------------------
# MetalLB - gives the Istio gateway Service a reachable external IP
# -------------------------------------------------------------------------

info "Installing MetalLB"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
kubectl wait --timeout=180s -n metallb-system deployment/controller \
    --for=condition=Available || err "MetalLB controller not ready"

subnet=$(docker network inspect kind \
    -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -v ':' | head -1)
base=$(echo "${subnet:-172.18.0.0/16}" | cut -d. -f1-2)

# Every kind cluster shares the same docker network, so a fixed pool like
# .255.200-250 gets handed out by *every* cluster's MetalLB and whichever
# ARPs first wins - you end up talking to another spike's gateway. Derive a
# single address from this cluster's control-plane node IP, which docker
# already guarantees is unique among running containers.
# Collides only if two clusters' node IPs share a last octet across
# different /24s. Widen to a per-cluster /28 if that ever happens.
node_ip=$(docker inspect "${CLUSTER_NAME}-control-plane" \
    -f '{{.NetworkSettings.Networks.kind.IPAddress}}')
lb_ip="${base}.255.${node_ip##*.}"
info "MetalLB pool for '${CLUSTER_NAME}': ${lb_ip}"

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${lb_ip}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF

# -------------------------------------------------------------------------
# Gateway API CRDs
# -------------------------------------------------------------------------

info "Installing Gateway API CRDs ${GWAPI_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/standard-install.yaml"

# -------------------------------------------------------------------------
# Istio
# -------------------------------------------------------------------------

# Re-running the helm upgrade fights istiod over ownership of its own
# validating webhook, so only install when it isn't there.
if kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
    info "Istio already installed"
else
    info "Installing Istio ${ISTIO_VERSION}"
    helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
    helm repo update istio

    kubectl create namespace istio-system 2>/dev/null || true
    helm upgrade -i istio-base istio/base \
        --namespace istio-system --version "${ISTIO_VERSION}" --wait
    helm upgrade -i istiod istio/istiod \
        --namespace istio-system --version "${ISTIO_VERSION}" \
        --set resources.requests.cpu=5m \
        --set resources.requests.memory=32Mi \
        --wait
fi
kubectl wait --timeout=180s -n istio-system deployment/istiod \
    --for=condition=Available || err "istiod not ready"

# -------------------------------------------------------------------------
# Gateway
# -------------------------------------------------------------------------

kubectl create namespace "$NS" 2>/dev/null || true

info "Creating Gateway"
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: spike-gateway
  namespace: ${NS}
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF

info "Waiting for gateway address..."
for _ in $(seq 1 45); do
    gw_addr=$(kubectl get gateway spike-gateway -n "$NS" \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    if [[ -n "$gw_addr" ]]; then
        echo ""
        ok "Gateway address: ${gw_addr}"
        echo ""
        echo -e "  ${BOLD}./validate.sh${NC}"
        exit 0
    fi
    sleep 2
done
err "Gateway has no address after 90s"
