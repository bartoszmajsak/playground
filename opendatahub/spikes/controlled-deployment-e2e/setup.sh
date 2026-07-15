#!/usr/bin/env bash
# Controlled Deployment E2E - Cluster Setup
#
# Sets up the gateway infrastructure and deploys the LLMISVC controller.
# Self-contained - fetches all dependencies from upstream repos. No local kserve checkout needed.
#
# Usage:
#   ./setup.sh kind-istio                    # kind + Istio (recommended)
#   LLMISVC_IMAGE=quay.io/bmajsak/llmisvc-controller:traffic-splitting ./setup.sh kind-istio
#
# Environment:
#   LLMISVC_IMAGE  - Pre-built controller image (required, no local build)
#   KSERVE_REF     - Git ref for kserve manifests (default: master)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="controlled-deployment-spike"
CLUSTER_NAME="${CLUSTER_NAME:-controlled-deployment}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-${CLUSTER_NAME}.config}"
CLUSTER_TYPE="${1:-kind-istio}"

# Upstream refs - defaults to the traffic-splitting branch on the fork
KSERVE_REPO="${KSERVE_REPO:-bartoszmajsak/kserve}"
KSERVE_REF="${KSERVE_REF:-upstream/feat/x-served-by}"
KSERVE_RAW="https://raw.githubusercontent.com/${KSERVE_REPO}/${KSERVE_REF}"
KSERVE_KUSTOMIZE="https://github.com/${KSERVE_REPO}/config"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

# Versions - fetched from kserve-deps.env at the given ref, overridable via env
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
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-83.4.0}"
JAEGER_VERSION="${JAEGER_VERSION:-4.7.0}"
# ponytail: InferencePool v1 (inference.networking.k8s.io) requires Istio >= 1.28
ISTIO_VERSION="${ISTIO_VERSION_OVERRIDE:-1.28.1}"

info() { echo -e "${YELLOW}INFO${NC}: $1"; }
ok()   { echo -e "${GREEN}  OK${NC}: $1"; }
err()  { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

# -------------------------------------------------------------------------
# Shared helpers
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
    kubectl config use-context "kind-${CLUSTER_NAME}" 2>/dev/null || true

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

deploy_kserve_llmisvc() {
    local llmisvc_img="${LLMISVC_IMAGE:-quay.io/bmajsak/llmisvc-controller:traffic-splitting}"

    info "Deploying KServe LLMISVC (image: $llmisvc_img, ref: $KSERVE_REF)"
    kubectl create namespace kserve 2>/dev/null || true

    # CRDs
    info "Applying CRDs"
    kubectl apply --server-side=true --force-conflicts \
        -k "${KSERVE_KUSTOMIZE}/crd/full/llmisvc?ref=${KSERVE_REF}"
    kubectl wait --for=condition=established --timeout=60s crd/llminferenceserviceconfigs.serving.kserve.io \
        || err "CRDs not established"

    # Self-signed issuer for webhook TLS
    kubectl apply -f "${KSERVE_RAW}/config/certmanager/issuer.yaml"

    # inferenceservice-config configmap
    kubectl apply -f "${KSERVE_RAW}/config/configmap/inferenceservice.yaml"

    # Enable Gateway API and set gateway ref
    local gw_ns="${1:-kserve}"
    local gw_class="istio"
    if [[ "$gw_ns" == "openshift-ingress" ]]; then gw_class="openshift-default"; fi
    info "Enabling Gateway API (gateway: $gw_ns/kserve-ingress-gateway, class: $gw_class)"
    local ingress_json
    ingress_json=$(kubectl get configmap inferenceservice-config -n kserve \
        -o jsonpath='{.data.ingress}' | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
cfg['enableGatewayApi'] = True
cfg['kserveIngressGateway'] = '${gw_ns}/kserve-ingress-gateway'
cfg['ingressClassName'] = '${gw_class}'
print(json.dumps(cfg))
")
    kubectl patch configmap inferenceservice-config -n kserve --type merge \
        -p "{\"data\":{\"ingress\":$(printf '%s' "$ingress_json" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')}}"

    # RBAC, webhooks, deployment
    info "Applying LLMISVC controller manifests"
    kubectl apply --server-side=true --force-conflicts \
        -k "${KSERVE_KUSTOMIZE}/llmisvc?ref=${KSERVE_REF}"

    # Patch image
    info "Patching controller image to $llmisvc_img"
    kubectl set image -n kserve deployment/llmisvc-controller-manager \
        manager="$llmisvc_img"
    kubectl patch deployment/llmisvc-controller-manager -n kserve --type=json \
        -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]'

    # On OpenShift, remove hardcoded runAsUser (conflicts with namespace UID range SCC)
    if kubectl get clusterversion >/dev/null 2>&1; then
        kubectl patch deployment/llmisvc-controller-manager -n kserve --type=json \
            -p '[{"op":"remove","path":"/spec/template/spec/containers/0/securityContext/runAsUser"}]' 2>/dev/null || true
    fi

    kubectl rollout status deployment/llmisvc-controller-manager -n kserve --timeout=120s

    # Well-known configs (route template, workload presets)
    info "Applying well-known configs"
    kubectl apply --server-side=true --force-conflicts \
        -k "${KSERVE_KUSTOMIZE}/llmisvcconfig?ref=${KSERVE_REF}"

    kubectl create namespace "$NS" 2>/dev/null || true
}

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

# =========================================================================
# Kind + Istio
# =========================================================================

setup_kind_istio() {
    info "Setting up kind cluster with Istio"
    setup_kind_cluster

    # cert-manager
    info "Installing cert-manager ${CERT_MANAGER_VERSION}"
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    kubectl wait --timeout=120s -n cert-manager \
        deployment/cert-manager-webhook --for=condition=Available || err "cert-manager not ready"

    # Gateway API CRDs
    info "Installing Gateway API CRDs"
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml" 2>/dev/null || true

    # Gateway Inference Extension CRDs
    info "Installing Gateway Inference Extension CRDs ${GIE_VERSION}"
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml"

    # Istio
    info "Installing Istio ${ISTIO_VERSION}"
    helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
    helm repo update istio

    kubectl create namespace istio-system 2>/dev/null || true
    helm upgrade -i istio-base istio/base \
        --namespace istio-system \
        --version "${ISTIO_VERSION}" \
        --wait
    helm upgrade -i istiod istio/istiod \
        --namespace istio-system \
        --version "${ISTIO_VERSION}" \
        --set resources.requests.cpu=5m \
        --set resources.requests.memory=32Mi \
        --set pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
        --set pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true \
        --wait
    kubectl wait --timeout=120s -n istio-system deployment/istiod --for=condition=Available \
        || err "istiod not ready"

    # GatewayClass + Gateway
    kubectl create namespace kserve 2>/dev/null || true
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: istio
spec:
  controllerName: istio.io/gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kserve-ingress-gateway
  namespace: kserve
spec:
  gatewayClassName: istio
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

    # LWS
    info "Installing LWS ${LWS_VERSION}"
    kubectl apply --server-side -f "https://github.com/kubernetes-sigs/lws/releases/download/${LWS_VERSION}/manifests.yaml"
    kubectl wait --timeout=120s -n lws-system deployment/lws-controller-manager --for=condition=Available \
        || err "LWS controller not ready"

    # Prometheus
    info "Installing Prometheus ${PROMETHEUS_VERSION}"
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    kubectl create namespace monitoring 2>/dev/null || true
    helm upgrade -i prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --version "${PROMETHEUS_VERSION}" \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --wait --timeout 5m
    kubectl wait --timeout=120s -n monitoring \
        pod -l app.kubernetes.io/name=prometheus --for=condition=Ready \
        || err "Prometheus pods not ready"

    # Jaeger
    info "Installing Jaeger ${JAEGER_VERSION}"
    helm repo add jaegertracing https://jaegertracing.github.io/helm-charts 2>/dev/null || true
    helm upgrade -i jaeger jaegertracing/jaeger \
        --namespace observability --create-namespace \
        --version "${JAEGER_VERSION}" \
        --set provisionDataStore.cassandra=false \
        --set allInOne.enabled=true \
        --set storage.type=memory \
        --set agent.enabled=false \
        --set collector.enabled=false \
        --set query.enabled=false \
        --wait --timeout 2m

    # OTEL collector alias
    kubectl apply -f - <<OTELEOF
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: kserve
spec:
  type: ExternalName
  externalName: jaeger.observability.svc.cluster.local
  ports:
    - port: 4317
      targetPort: 4317
      protocol: TCP
      name: otlp-grpc
OTELEOF

    deploy_kserve_llmisvc "kserve"

    ok "Kind (Istio) setup complete"
    wait_for_gateway "kserve-ingress-gateway" "kserve"
}

# =========================================================================
# OpenShift (OCP 4.21+ with pre-installed OSSM/Sail)
# =========================================================================

setup_openshift() {
    info "Setting up on OpenShift"

    kubectl get clusterversion >/dev/null 2>&1 || err "Not an OpenShift cluster (no clusterversion resource)"

    # cert-manager
    if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
        info "Installing cert-manager ${CERT_MANAGER_VERSION}"
        kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
        kubectl wait --timeout=120s -n cert-manager \
            deployment/cert-manager-webhook --for=condition=Available || err "cert-manager not ready"
    else
        ok "cert-manager already installed"
    fi

    # GIE CRDs
    if ! kubectl api-resources --api-group=inference.networking.k8s.io 2>/dev/null | grep -q inferencepools; then
        info "Installing Gateway Inference Extension CRDs ${GIE_VERSION}"
        kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml"
    else
        ok "GIE CRDs already installed"
    fi

    # LWS
    if ! kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io >/dev/null 2>&1; then
        info "Installing LWS ${LWS_VERSION}"
        kubectl apply --server-side -f "https://github.com/kubernetes-sigs/lws/releases/download/${LWS_VERSION}/manifests.yaml"
        kubectl wait --timeout=120s -n lws-system deployment/lws-controller-manager --for=condition=Available \
            || err "LWS controller not ready"
    else
        ok "LWS already installed"
    fi

    # GatewayClass - triggers the ingress operator to install OSSM/Istio automatically
    info "Creating GatewayClass (ingress operator provisions OSSM automatically)"
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: "openshift.io/gateway-controller/v1"
EOF

    # Wait for the ingress operator to provision istiod
    info "Waiting for ingress operator to provision istiod..."
    for _ in $(seq 1 60); do
        if kubectl get deployment -n openshift-ingress -l app=istiod -o name 2>/dev/null | grep -q .; then
            break
        fi
        sleep 5
    done
    kubectl wait --timeout=300s -n openshift-ingress deployment -l app=istiod --for=condition=Available \
        || err "istiod not provisioned by ingress operator"

    # Patch istiod with GIE env vars if not already set
    local istiod_deploy
    istiod_deploy=$(kubectl get deployment -n openshift-ingress -l app=istiod -o name 2>/dev/null | head -1)
    if [[ -n "$istiod_deploy" ]]; then
        local gie_enabled
        gie_enabled=$(kubectl get "$istiod_deploy" -n openshift-ingress \
            -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ENABLE_GATEWAY_API_INFERENCE_EXTENSION")].value}' 2>/dev/null || true)
        if [[ "$gie_enabled" != "true" ]]; then
            info "Enabling GIE on istiod"
            kubectl set env "$istiod_deploy" -n openshift-ingress \
                ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
                SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true
            kubectl rollout status "$istiod_deploy" -n openshift-ingress --timeout=120s
        fi
    fi

    # Gateway
    info "Creating Gateway in openshift-ingress"
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kserve-ingress-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
EOF

    deploy_kserve_llmisvc "openshift-ingress"

    # SCC workaround: workload pods need privileged SCC for hardcoded runAsUser/seccomp
    info "Granting SCC for workload namespace"
    oc adm policy add-scc-to-user privileged -z default -n "$NS" 2>/dev/null || true

    ok "OpenShift setup complete"
    wait_for_gateway "kserve-ingress-gateway" "openshift-ingress"
}

# =========================================================================
# Main
# =========================================================================

echo -e "${BOLD}Controlled Deployment E2E - Setup${NC}"
echo "Cluster: $CLUSTER_NAME (kubeconfig: $KUBECONFIG)"
echo "Cluster type: $CLUSTER_TYPE"
echo "Image: ${LLMISVC_IMAGE:-<will build from KSERVE_ROOT>}"
echo "KServe ref: $KSERVE_REF"
echo ""

case "$CLUSTER_TYPE" in
    kind-istio)  setup_kind_istio ;;
    openshift)   setup_openshift ;;
    *)           err "Unknown cluster type: $CLUSTER_TYPE. Use 'kind-istio' or 'openshift'." ;;
esac
