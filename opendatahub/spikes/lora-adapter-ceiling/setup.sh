#!/usr/bin/env bash
# LoRA adapter ceiling spike - cluster setup.
#
# kind + MetalLB + Gateway API + Istio + GIE CRDs + the kserve llmisvc
# controller. One mode: the spike reads what the controller renders, so the
# controller is never optional here.
#
# Adapted from ../lora-httproute-budget/setup.sh, which proved this cluster
# shape. Copied rather than sourced so the spike stands on its own.
#
# Scoped kubeconfig; does not touch ~/.kube/config's current context.
#
# Environment:
#   CLUSTER_NAME    kind cluster name (default: lora-ceiling-spike)
#   NS              namespace (default: lora-ceiling)
#   ISTIO_VERSION   Istio helm chart version (default: 1.30.3)
#   GWAPI_VERSION   Gateway API CRD version (default: v1.5.1)
#   CERTMGR_VERSION cert-manager version (default: v1.17.0)
#   GIE_VERSION     inference-extension version (default: v1.5.0)
#   KSERVE_REF      kserve git ref for manifests (default: master)
#   LLMISVC_IMAGE   controller image (default: the ref's published image)
#
# Versions track kserve's own kserve-deps.env so the cluster matches what
# kserve tests against.

set -euo pipefail

# A stale DOCKER_HOST pointing at a dead rootless socket breaks docker and kind
# even when the rootful daemon is healthy. Fall back to the default socket.
if [[ -n "${DOCKER_HOST:-}" ]]; then
    _dh_sock="${DOCKER_HOST#unix://}"
    if [[ ! -S "$_dh_sock" && -S /var/run/docker.sock ]]; then
        unset DOCKER_HOST
    fi
fi


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-lora-ceiling-spike}"
NS="${NS:-lora-ceiling}"
KSERVE_REPO="${KSERVE_REPO:-kserve/kserve}"
KSERVE_REF="${KSERVE_REF:-master}"
KSERVE_RAW="https://raw.githubusercontent.com/${KSERVE_REPO}/${KSERVE_REF}"
KSERVE_KUSTOMIZE="https://github.com/${KSERVE_REPO}/config"

# Pull the pinned versions from kserve itself rather than hardcoding a set that
# silently drifts. Matters here more than usual: the spike's whole subject is
# what the installed HTTPRoute CRD allows, so testing against a Gateway API
# version kserve does not use would measure the wrong thing.
load_kserve_deps() {
    local deps
    deps=$(curl -sf "${KSERVE_RAW}/kserve-deps.env" 2>/dev/null || true)
    if [[ -z "$deps" ]]; then
        echo "WARNING: could not fetch kserve-deps.env, using fallback versions" >&2
        return
    fi
    eval "$(echo "$deps" | grep -E '^[A-Z_]+=' | grep -v '^OVERRIDE_' | sed 's/^/export /')"
}
load_kserve_deps

GWAPI_VERSION="${GWAPI_VERSION:-${GATEWAY_API_VERSION:-v1.5.1}}"
CERTMGR_VERSION="${CERTMGR_VERSION:-${CERT_MANAGER_VERSION:-v1.17.0}}"
GIE_VERSION="${GIE_VERSION:-v1.5.0}"
LWS_VERSION="${LWS_VERSION:-v0.8.0}"
# Does NOT track kserve-deps.env (still 1.27.1). InferencePool v1 needs >= 1.28,
# but 1.28.x installs the ext_proc filter as a placeholder pointing at cluster
# "dummy" and never attaches the per-route override -- so the endpoint picker is
# deployed, healthy, resolved, and silently never invoked, with traffic
# round-robining instead of being scheduled. Nothing reports a problem.
# 1.30.3 wires it correctly. See FINDINGS.md section 6. 1.29 not bisected.
ISTIO_VERSION="${ISTIO_VERSION_OVERRIDE:-1.30.3}"

WITH_KSERVE=true   # the spike reads rendered controller output; never optional

export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${YELLOW}INFO${NC}: $1"; }
ok()   { echo -e "${GREEN}  OK${NC}: $1"; }
err()  { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

# -------------------------------------------------------------------------
# Kind
# -------------------------------------------------------------------------

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "Kind cluster '${CLUSTER_NAME}' already exists"
else
    info "Creating kind cluster '${CLUSTER_NAME}'"
    kind create cluster --name "$CLUSTER_NAME"
fi
kind get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG}"

default_kubeconfig="${HOME}/.kube/config"
if [[ -f "$default_kubeconfig" ]]; then
    prev_ctx=$(KUBECONFIG="$default_kubeconfig" kubectl config current-context 2>/dev/null || true)
    KUBECONFIG="$default_kubeconfig" kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null
    [[ -n "$prev_ctx" ]] && KUBECONFIG="$default_kubeconfig" \
        kubectl config use-context "$prev_ctx" >/dev/null 2>&1 || true
    info "Context available: kubectl --context kind-${CLUSTER_NAME} ..."
fi

# -------------------------------------------------------------------------
# MetalLB
#
# Every kind cluster shares the docker network, so a fixed pool gets handed
# out by every cluster's MetalLB and whichever ARPs first wins. Derive the
# address from this cluster's control-plane node IP, which docker guarantees
# is unique among running containers.
# -------------------------------------------------------------------------

info "Installing MetalLB"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
kubectl wait --timeout=180s -n metallb-system deployment/controller \
    --for=condition=Available || err "MetalLB controller not ready"

subnet=$(docker network inspect kind \
    -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -v ':' | head -1)
base=$(echo "${subnet:-172.18.0.0/16}" | cut -d. -f1-2)
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
# Gateway API
# -------------------------------------------------------------------------

# --server-side: the HTTPRoute CRD's CEL rules push it past the annotation size
# limit that a client-side apply has to fit the last-applied-configuration into.
info "Installing Gateway API CRDs ${GWAPI_VERSION}"
kubectl apply --server-side=true --force-conflicts \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/standard-install.yaml"

# The pre-flight check this spike argues for is only as good as the limits it
# checks against, and those ship with whichever CRD the cluster installed --
# not with kserve's go.mod. Print them so every run records what it tested on.
info "HTTPRoute limits on the installed CRD:"
kubectl get crd httproutes.gateway.networking.k8s.io -o json 2>/dev/null | python3 -c '
import json, sys
crd = json.load(sys.stdin)
for ver in crd["spec"]["versions"]:
    if not ver.get("storage"):
        continue
    rules = ver["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["rules"]
    matches = rules["items"]["properties"]["matches"]
    total = next((r["message"] for r in rules.get("x-kubernetes-validations", [])
                  if "total number of matches" in r.get("message", "")), "no CEL total rule")
    print("       version           %s" % ver["name"])
    print("       max rules         %s" % rules.get("maxItems", "unset"))
    print("       max matches/rule  %s" % matches.get("maxItems", "unset"))
    print("       route-wide        %s" % total)
' || info "  (could not read CRD schema)"

# -------------------------------------------------------------------------
# Istio
# -------------------------------------------------------------------------

if kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
    info "Istio already installed"
else
    info "Installing Istio ${ISTIO_VERSION}"
    helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
    helm repo update istio

    kubectl create namespace istio-system 2>/dev/null || true
    helm upgrade -i istio-base istio/base \
        --namespace istio-system --version "${ISTIO_VERSION}" --wait
    # Without these, Istio refuses every InferencePool backendRef with
    # ResolvedRefs=InvalidKind ("InferencePool is not enabled. To enable, set
    # ENABLE_GATEWAY_API_INFERENCE_EXTENSION to true in istiod") and no llmisvc
    # route ever becomes ready.
    helm upgrade -i istiod istio/istiod \
        --namespace istio-system --version "${ISTIO_VERSION}" \
        --set resources.requests.cpu=5m \
        --set resources.requests.memory=32Mi \
        --set pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
        --set pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true \
        --wait
fi
kubectl wait --timeout=180s -n istio-system deployment/istiod \
    --for=condition=Available || err "istiod not ready"

# -------------------------------------------------------------------------
# Gateway
#
# allowedRoutes from All: the fixtures and the neighbour tenant live in
# lora-budget while the Gateway lives in kserve, and cross-namespace parentRef
# attachment needs the Gateway to opt in.
# -------------------------------------------------------------------------

kubectl create namespace kserve 2>/dev/null || true
kubectl create namespace "$NS" 2>/dev/null || true

info "Creating Gateway kserve/kserve-ingress-gateway"
kubectl apply -f - <<EOF
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

# -------------------------------------------------------------------------
# kserve (tier 1 only)
# -------------------------------------------------------------------------

if [[ "$WITH_KSERVE" == true ]]; then
    # config/llmisvc ships a cert-manager Certificate for the webhook serving
    # cert. Without cert-manager the kustomize apply fails on an unknown kind,
    # the controller pod never leaves ContainerCreating waiting for the secret,
    # and every subsequent LLMInferenceServiceConfig apply is refused by a
    # webhook whose backend is not listening.
    if kubectl get deployment cert-manager-webhook -n cert-manager >/dev/null 2>&1; then
        info "cert-manager already installed"
    else
        info "Installing cert-manager ${CERTMGR_VERSION}"
        kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERTMGR_VERSION}/cert-manager.yaml"
    fi
    kubectl wait --timeout=300s -n cert-manager --for=condition=Available \
        deployment/cert-manager deployment/cert-manager-webhook deployment/cert-manager-cainjector \
        || err "cert-manager not ready"

    info "Installing inference-extension CRDs ${GIE_VERSION}"
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml"

    info "Installing LWS ${LWS_VERSION}"
    kubectl apply --server-side -f "https://github.com/kubernetes-sigs/lws/releases/download/${LWS_VERSION}/manifests.yaml"
    kubectl wait --timeout=180s -n lws-system deployment/lws-controller-manager \
        --for=condition=Available || err "LWS controller not ready"

    info "Installing kserve llmisvc (${KSERVE_REF})"
    kubectl apply --server-side=true --force-conflicts \
        -k "${KSERVE_KUSTOMIZE}/crd/full/llmisvc?ref=${KSERVE_REF}"
    # A freshly server-side-applied CRD can exist with no .status yet, and
    # `kubectl wait` errors out on that ("accessor error: <nil>") rather than
    # retrying -- which under `set -e` aborts the whole install. Poll instead.
    for crd in llminferenceserviceconfigs.serving.kserve.io \
               llminferenceservices.serving.kserve.io; do
        for _ in $(seq 1 30); do
            if kubectl get "crd/${crd}" \
                -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' \
                2>/dev/null | grep -q True; then
                break
            fi
            sleep 2
        done
        kubectl get "crd/${crd}" \
            -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' \
            2>/dev/null | grep -q True || err "CRD ${crd} never became Established"
    done

    kubectl apply -f "${KSERVE_RAW}/config/configmap/inferenceservice.yaml" 2>/dev/null || true

    # The webhook Certificate references a self-signed Issuer that lives in a
    # different kustomize root (config/certmanager). Without it the Certificate
    # stays Ready=False forever, the serving-cert Secret is never created, and
    # the controller pod hangs in ContainerCreating on the volume mount.
    info "Installing cert-manager Issuer"
    kubectl apply -f "${KSERVE_RAW}/config/certmanager/issuer.yaml" \
        || err "failed to install the selfsigned issuer"

    info "Pointing kserve at the Gateway"
    ingress_json=$(kubectl get configmap inferenceservice-config -n kserve \
        -o jsonpath='{.data.ingress}' 2>/dev/null || echo '{}')
    patched=$(python3 - <<PY
import json
cfg = json.loads('''${ingress_json}''' or '{}')
cfg['kserveIngressGateway'] = 'kserve/kserve-ingress-gateway'
cfg['enableGatewayApi'] = True
print(json.dumps(cfg))
PY
)
    kubectl patch configmap inferenceservice-config -n kserve --type merge \
        -p "{\"data\":{\"ingress\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$patched")}}"

    # The rolebinding in this kustomize uses kustomize vars and fails to
    # validate standalone -- known and harmless. Anything else is not, so
    # filter that one line rather than swallowing the whole exit status.
    apply_out=$(kubectl apply --server-side=true --force-conflicts \
        -k "${KSERVE_KUSTOMIZE}/llmisvc?ref=${KSERVE_REF}" 2>&1) || true
    echo "$apply_out" | grep -v 'is invalid' || true
    if echo "$apply_out" | grep -q 'no matches for kind'; then
        err "kserve kustomize needs a CRD that is not installed (see above)"
    fi

    # The upstream kustomize leaves the controller on kserve/llmisvc-controller:latest
    # with imagePullPolicy: Always, which is not a pin: any pod restart re-resolves
    # the tag and silently swaps in whatever Docker Hub serves, discarding a locally
    # built controller. Pin the image and stop re-pulling it.
    if [[ -n "${LLMISVC_IMAGE:-}" ]]; then
        info "Patching controller image to ${LLMISVC_IMAGE}"
        kubectl set image -n kserve deployment/llmisvc-controller-manager \
            manager="$LLMISVC_IMAGE"
        kubectl patch deployment/llmisvc-controller-manager -n kserve --type=json \
            -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
        case "$LLMISVC_IMAGE" in
            *:latest) info "LLMISVC_IMAGE uses the :latest tag, which is not reproducible" ;;
        esac
    else
        info "LLMISVC_IMAGE unset: controller stays on the published image for ${KSERVE_REF}"
        info "  a restart will re-pull it; set LLMISVC_IMAGE to pin a specific build"
    fi

    # cert-manager issues the serving cert asynchronously. A pod created before
    # the Secret lands sits in ContainerCreating and kubelet backs off on the
    # mount retry, so it can stay stuck long after the Secret appears -- which
    # reads as "the controller is broken" rather than "it was started too
    # early". Wait for the Secret, then evict anything still waiting on it.
    info "Waiting for the webhook serving cert"
    kubectl wait --timeout=180s -n kserve --for=condition=Ready \
        certificate/llmisvc-serving-cert || err "serving cert never issued"

    if kubectl get pods -n kserve -l control-plane=llmisvc-controller-manager \
        -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Pending; then
        info "Restarting the controller: it predates the serving cert"
        kubectl delete pods -n kserve -l control-plane=llmisvc-controller-manager --wait=false
    fi

    kubectl rollout status deployment/llmisvc-controller-manager -n kserve --timeout=300s \
        || err "llmisvc controller not ready"

    # The presets below go through a validating webhook served by the pod we
    # just rolled out. Deployment Available is not the same as the webhook
    # endpoint accepting connections, and applying too early fails with a
    # connection-refused that looks like a manifest problem.
    info "Waiting for the llmisvc webhook endpoint"
    for _ in $(seq 1 60); do
        ready=$(kubectl get endpointslice -n kserve \
            -l kubernetes.io/service-name=llmisvc-webhook-server-service \
            -o jsonpath='{.items[*].endpoints[*].conditions.ready}' 2>/dev/null || echo "")
        [[ "$ready" == *true* ]] && break
        sleep 2
    done
    [[ "$ready" == *true* ]] || err "webhook endpoint never became ready"

    kubectl apply --server-side=true --force-conflicts \
        -k "${KSERVE_KUSTOMIZE}/llmisvcconfig?ref=${KSERVE_REF}" \
        || err "failed to install llmisvcconfig presets"
fi

# -------------------------------------------------------------------------
# Observable backends
# -------------------------------------------------------------------------

# -------------------------------------------------------------------------
# Endpoint-picker TLS
#
# Istio originates mTLS to workloads in the mesh, but the EPP serves plaintext
# gRPC on 9002. Without a DestinationRule telling Istio otherwise, the ext_proc
# stream is reset ("upstream connect error or disconnect/reset before headers ...
# connection termination") and every pool-bound request 500s -- with the route,
# the filter and the EPP all reporting healthy. Istio's own inference-extension
# task documents this; it is easy to miss because on Istio < 1.29 ext_proc is
# never attached at all, so adding the rule appears to change nothing.
#
# Scope it per EPP Service. A wildcard host originates TLS to every service in
# the namespace, including the plaintext workloads, which trades the 500 for a
# 503.
# -------------------------------------------------------------------------

epp_destinationrule() {
    local svc="$1"
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: ${svc}-tls
  namespace: ${NS}
spec:
  host: ${svc}
  trafficPolicy:
    tls:
      mode: SIMPLE
      insecureSkipVerify: true
EOF
}

# No echo backends here. The upstream spike routes to them; this one deploys
# real LLMInferenceServices in validate.sh and reads what the controller
# renders for them.
kubectl create namespace "$NS" 2>/dev/null || true

# -------------------------------------------------------------------------

info "Waiting for gateway address..."
for _ in $(seq 1 45); do
    gw_addr=$(kubectl get gateway kserve-ingress-gateway -n kserve \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    if [[ -n "$gw_addr" ]]; then
        ok "Gateway address: ${gw_addr}"
        echo
        kubectl create namespace "$NS" 2>/dev/null || true
        echo -e "  ${BOLD}./validate.sh${NC}          # tier 1: what the controller renders"
        echo -e "  ${BOLD}KEEP=1 ./validate.sh${NC}   # leave the services up afterwards"
        exit 0
    fi
    sleep 2
done
err "Gateway has no address after 90s"
