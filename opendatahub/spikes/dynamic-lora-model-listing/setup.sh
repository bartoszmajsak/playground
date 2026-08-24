#!/usr/bin/env bash
# Builds a kind cluster with MetalLB, Gateway API, cert-manager, the inference
# extension, LWS, Istio and kserve, then the on-demand LoRA fixture on top.
# No pre-existing cluster required.
#
# Writes a scoped .kubeconfig next to this script; leaves ~/.kube/config's
# current context alone.
#
# manifests/fixture.yaml is a template - its route rules are an empty
# placeholder that this script fills from manifests/route-rules.yaml.
#
# Fixture order matters:
#
#   1. namespace + PVC
#   2. seed the PVC through a throwaway pod. A WaitForFirstConsumer PVC does
#      not bind until something mounts it, and that must not be the workload:
#      vLLM needs the adapters on disk at startup.
#   3. apply the fixture with the committed route rules spliced in
#   4. DestinationRule for the endpoint picker
#   5. wait on a request, not a sleep
#
# Usage:
#   ./setup.sh                  # cluster + fixture
#   ./setup.sh --skip-cluster   # fixture only, against an existing cluster
#   ./setup.sh --teardown       # delete the namespace
#   ./setup.sh --destroy        # delete the kind cluster
#
# Environment:
#   CLUSTER_NAME            kind cluster name (default: dynlora-spike)
#   NS, SVC                 fixture namespace / service
#   ISTIO_VERSION_OVERRIDE  default 1.30.3; must be >= 1.29
#   KSERVE_REF              kserve git ref (default: master)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-dynlora-spike}"
NS="${NS:-dynamic-lora}"
SVC="${SVC:-svc-dyn}"
PVC="dynlora-models"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"

KSERVE_REPO="${KSERVE_REPO:-kserve/kserve}"
KSERVE_REF="${KSERVE_REF:-master}"
KSERVE_RAW="https://raw.githubusercontent.com/${KSERVE_REPO}/${KSERVE_REF}"
KSERVE_KUSTOMIZE="https://github.com/${KSERVE_REPO}/config"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  ok${NC} $*"; }
warn() { echo -e "${YEL}   !${NC} $*"; }
err()  { echo -e "${RED}FAIL${NC} $*"; exit 1; }

# Track kserve's pinned versions rather than a set that drifts.
load_kserve_deps() {
    local deps
    deps=$(curl -sf "${KSERVE_RAW}/kserve-deps.env" 2>/dev/null || true)
    [[ -z "$deps" ]] && { warn "could not fetch kserve-deps.env, using fallbacks"; return; }
    eval "$(echo "$deps" | grep -E '^[A-Z_]+=' | grep -v '^OVERRIDE_' | sed 's/^/export /')"
}
load_kserve_deps

GWAPI_VERSION="${GWAPI_VERSION:-${GATEWAY_API_VERSION:-v1.5.1}}"
CERTMGR_VERSION="${CERTMGR_VERSION:-${CERT_MANAGER_VERSION:-v1.17.0}}"
GIE_VERSION="${GIE_VERSION:-v1.5.0}"
LWS_VERSION="${LWS_VERSION:-v0.8.0}"
# Not tracked from kserve-deps.env, and not named ISTIO_VERSION: load_kserve_deps
# exports that name (1.27.1 today), so ${ISTIO_VERSION:-1.30.3} would keep
# kserve's value. Below 1.29 Istio installs the ext_proc filter as a placeholder
# and never attaches the per-route override: the endpoint picker is deployed,
# healthy, resolved and never invoked, with nothing reporting a problem.
ISTIO_VERSION="${ISTIO_VERSION_OVERRIDE:-1.30.3}"

SKIP_CLUSTER=false
case "${1:-}" in
    --teardown)
        info "deleting namespace ${NS}"
        kubectl delete namespace "$NS" --wait=false 2>/dev/null || true
        ok "done"; exit 0 ;;
    --destroy)
        info "deleting kind cluster ${CLUSTER_NAME}"
        kind delete cluster --name "$CLUSTER_NAME"
        rm -f "${SCRIPT_DIR}/.kubeconfig"
        ok "done"; exit 0 ;;
    --skip-cluster) SKIP_CLUSTER=true; shift ;;
esac

# Fixed at four to match the committed route. Changing it requires recapturing
# the route, so it is not a flag.
ADAPTERS=(adapter-1 adapter-2 adapter-3 adapter-4)

# ===========================================================================
# Cluster
# ===========================================================================
if [[ "$SKIP_CLUSTER" == false ]]; then

for bin in kind kubectl helm docker curl python3; do
    command -v "$bin" >/dev/null 2>&1 || err "missing required binary: ${bin}"
done

info "kind cluster ${CLUSTER_NAME}"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    ok "already exists"
else
    kind create cluster --name "$CLUSTER_NAME"
fi
kind get kubeconfig --name "$CLUSTER_NAME" > "$KUBECONFIG"
if [[ -f "${HOME}/.kube/config" ]]; then
    prev=$(KUBECONFIG="${HOME}/.kube/config" kubectl config current-context 2>/dev/null || true)
    KUBECONFIG="${HOME}/.kube/config" kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    [[ -n "$prev" ]] && KUBECONFIG="${HOME}/.kube/config" \
        kubectl config use-context "$prev" >/dev/null 2>&1 || true
fi

# Every kind cluster shares the docker network, so a fixed pool is handed out by
# every cluster's MetalLB and whichever ARPs first wins. Derive the address from
# this cluster's control-plane IP, which docker keeps unique.
info "MetalLB"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml >/dev/null
kubectl wait --timeout=180s -n metallb-system deployment/controller \
    --for=condition=Available >/dev/null || err "MetalLB controller not ready"
subnet=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' \
    | grep -v ':' | head -1)
base=$(echo "${subnet:-172.18.0.0/16}" | cut -d. -f1-2)
node_ip=$(docker inspect "${CLUSTER_NAME}-control-plane" \
    -f '{{.NetworkSettings.Networks.kind.IPAddress}}')
lb_ip="${base}.255.${node_ip##*.}"
kubectl apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: kind-pool, namespace: metallb-system}
spec:
  addresses: ["${lb_ip}/32"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: kind-l2, namespace: metallb-system}
EOF
ok "pool ${lb_ip}"

# --server-side: the HTTPRoute CRD's CEL rules push it past the annotation size
# limit a client-side apply must fit last-applied-configuration into.
info "Gateway API ${GWAPI_VERSION}"
kubectl apply --server-side=true --force-conflicts \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/standard-install.yaml" >/dev/null
ok "installed"

info "cert-manager ${CERTMGR_VERSION}"
if kubectl get deployment cert-manager-webhook -n cert-manager >/dev/null 2>&1; then
    ok "already installed"
else
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERTMGR_VERSION}/cert-manager.yaml" >/dev/null
fi
kubectl wait --timeout=300s -n cert-manager --for=condition=Available \
    deployment/cert-manager deployment/cert-manager-webhook deployment/cert-manager-cainjector >/dev/null \
    || err "cert-manager not ready"
ok "ready"

info "inference extension ${GIE_VERSION} and LWS ${LWS_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml" >/dev/null
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/lws/releases/download/${LWS_VERSION}/manifests.yaml" >/dev/null
kubectl wait --timeout=180s -n lws-system deployment/lws-controller-manager \
    --for=condition=Available >/dev/null || err "LWS controller not ready"
ok "installed"

info "Istio ${ISTIO_VERSION}"
if kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
    ok "already installed"
else
    helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
    helm repo update istio >/dev/null
    kubectl create namespace istio-system >/dev/null 2>&1 || true
    helm upgrade -i istio-base istio/base -n istio-system --version "$ISTIO_VERSION" --wait >/dev/null
    # Without these two, Istio refuses every InferencePool backendRef with
    # ResolvedRefs=InvalidKind and no llmisvc route ever becomes ready.
    helm upgrade -i istiod istio/istiod -n istio-system --version "$ISTIO_VERSION" \
        --set resources.requests.cpu=5m --set resources.requests.memory=32Mi \
        --set pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
        --set pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true --wait >/dev/null
fi
kubectl wait --timeout=180s -n istio-system deployment/istiod \
    --for=condition=Available >/dev/null || err "istiod not ready"
ok "ready"

# allowedRoutes from All: the fixture lives in its own namespace while the
# Gateway lives in kserve, and cross-namespace attachment needs the opt-in.
info "Gateway kserve/kserve-ingress-gateway"
kubectl create namespace kserve >/dev/null 2>&1 || true
kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: kserve-ingress-gateway, namespace: kserve}
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces: {from: All}
  infrastructure:
    labels:
      serving.kserve.io/gateway: kserve-ingress-gateway
EOF
ok "created"

info "kserve llmisvc (${KSERVE_REF})"
kubectl apply --server-side=true --force-conflicts \
    -k "${KSERVE_KUSTOMIZE}/crd/full/llmisvc?ref=${KSERVE_REF}" >/dev/null
# A freshly server-side-applied CRD can exist with no .status yet, and
# `kubectl wait` errors on that rather than retrying, which aborts under set -e.
for crd in llminferenceserviceconfigs.serving.kserve.io llminferenceservices.serving.kserve.io; do
    for _ in $(seq 30); do
        kubectl get "crd/${crd}" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' \
            2>/dev/null | grep -q True && break
        sleep 2
    done
    kubectl get "crd/${crd}" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' \
        2>/dev/null | grep -q True || err "CRD ${crd} never became Established"
done
kubectl apply -f "${KSERVE_RAW}/config/configmap/inferenceservice.yaml" >/dev/null 2>&1 || true
# The webhook Certificate references a self-signed Issuer from a different
# kustomize root. Without it the cert never issues and the controller hangs in
# ContainerCreating on the volume mount.
kubectl apply -f "${KSERVE_RAW}/config/certmanager/issuer.yaml" >/dev/null \
    || err "failed to install the selfsigned issuer"

ingress_json=$(kubectl get configmap inferenceservice-config -n kserve \
    -o jsonpath='{.data.ingress}' 2>/dev/null || echo '{}')
patched=$(python3 - "$ingress_json" <<'PY'
import json, sys
cfg = json.loads(sys.argv[1] or "{}")
cfg["kserveIngressGateway"] = "kserve/kserve-ingress-gateway"
cfg["enableGatewayApi"] = True
print(json.dumps(cfg))
PY
)
kubectl patch configmap inferenceservice-config -n kserve --type merge \
    -p "{\"data\":{\"ingress\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$patched")}}" >/dev/null

# One rolebinding in this kustomize uses kustomize vars and fails to validate
# standalone -- known and harmless. Filter that line rather than the exit status.
apply_out=$(kubectl apply --server-side=true --force-conflicts \
    -k "${KSERVE_KUSTOMIZE}/llmisvc?ref=${KSERVE_REF}" 2>&1) || true
echo "$apply_out" | grep -q 'no matches for kind' && err "kserve kustomize needs a missing CRD"

kubectl wait --timeout=180s -n kserve --for=condition=Ready \
    certificate/llmisvc-serving-cert >/dev/null || err "serving cert never issued"
# A pod created before the Secret landed sits in ContainerCreating and kubelet
# backs off, so it stays stuck long after the Secret appears.
if kubectl get pods -n kserve -l control-plane=llmisvc-controller-manager \
    -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Pending; then
    kubectl delete pods -n kserve -l control-plane=llmisvc-controller-manager --wait=false >/dev/null
fi
kubectl rollout status deployment/llmisvc-controller-manager -n kserve --timeout=300s >/dev/null \
    || err "llmisvc controller not ready"

# Deployment Available is not the webhook endpoint accepting connections, and
# applying presets too early fails with a connection-refused that reads like a
# manifest problem.
for _ in $(seq 60); do
    ready=$(kubectl get endpointslice -n kserve \
        -l kubernetes.io/service-name=llmisvc-webhook-server-service \
        -o jsonpath='{.items[*].endpoints[*].conditions.ready}' 2>/dev/null || echo "")
    [[ "$ready" == *true* ]] && break
    sleep 2
done
[[ "$ready" == *true* ]] || err "webhook endpoint never became ready"
kubectl apply --server-side=true --force-conflicts \
    -k "${KSERVE_KUSTOMIZE}/llmisvcconfig?ref=${KSERVE_REF}" >/dev/null \
    || err "failed to install llmisvcconfig presets"
ok "ready"

fi  # SKIP_CLUSTER

# ===========================================================================
# Fixture
# ===========================================================================
kubectl get gateway kserve-ingress-gateway -n kserve >/dev/null 2>&1 \
    || err "no Gateway kserve/kserve-ingress-gateway (drop --skip-cluster?)"

info "namespace and PVC"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: ${PVC}}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: 128Mi}
EOF
ok "${NS}/${PVC}"

info "seeding ${#ADAPTERS[@]} adapters into the PVC"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
"${SCRIPT_DIR}/hack/gen-adapter.py" "$STAGE" "${ADAPTERS[@]}" | sed 's/^/  /'
kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: lora-seeder}
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts: [{name: models, mountPath: /models}]
  volumes:
    - name: models
      persistentVolumeClaim: {claimName: ${PVC}}
EOF
kubectl wait --for=condition=Ready pod/lora-seeder -n "$NS" --timeout=300s >/dev/null
for a in "${ADAPTERS[@]}"; do
    kubectl cp "${STAGE}/${a}" "${NS}/lora-seeder:/models/${a}" >/dev/null 2>&1
done
kubectl exec -n "$NS" lora-seeder -- ls /models | sed 's/^/  /'
kubectl delete pod lora-seeder -n "$NS" --wait=false >/dev/null 2>&1
ok "seeded"

info "applying the fixture"
# route-rules.yaml was captured once from a kserve-managed route for four
# adapters. Splicing it in keeps the route identical to a managed one while
# spec.model.lora stays absent, so the runtime starts empty.
python3 - "${SCRIPT_DIR}" >"${STAGE}/final.yaml" <<'PYEOF'
import sys, yaml
root = sys.argv[1]
rules = yaml.safe_load(open(root + "/manifests/route-rules.yaml"))["rules"]
docs = [d for d in yaml.safe_load_all(open(root + "/manifests/fixture.yaml")) if d]
for d in docs:
    if d.get("kind") == "LLMInferenceService":
        d["spec"]["router"]["route"] = {"http": {"spec": {"rules": rules}}}
yaml.safe_dump_all(docs, sys.stdout, sort_keys=False)
PYEOF
kubectl apply -f "${STAGE}/final.yaml" >/dev/null
ok "applied"

# Several routes merging on one gateway trips istio's mergeHTTPRoutes data race.
# istiod crash-loops, the validating webhook stops answering, and the next apply
# fails with connection refused. A restart clears it.
istiod_ready() {
    kubectl get pod -n istio-system -l app=istiod \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true
}
info "checking istiod"
if ! istiod_ready; then
    warn "not ready (likely the mergeHTTPRoutes race); restarting"
    kubectl rollout restart deploy/istiod -n istio-system >/dev/null 2>&1 || true
    kubectl rollout status deploy/istiod -n istio-system --timeout=300s >/dev/null 2>&1 || true
fi
for _ in $(seq 30); do istiod_ready && break; sleep 10; done
istiod_ready || err "istiod will not stay up"
ok "ready"

# Istio originates mTLS to mesh workloads; the EPP serves plaintext gRPC on 9002.
# Without this the ext_proc stream is reset and every pool-bound request 500s
# while the route, the pool and the EPP all report healthy.
info "DestinationRule for the endpoint picker"
kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: {name: ${SVC}-epp-service-tls}
spec:
  host: ${SVC}-epp-service
  trafficPolicy:
    tls: {mode: SIMPLE, insecureSkipVerify: true}
EOF
ok "${SVC}-epp-service-tls"

info "waiting for the workload"
kubectl wait --for=condition=Ready pod -l "app.kubernetes.io/name=${SVC}" \
    -n "$NS" --timeout=900s >/dev/null 2>&1 || true

GW="http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
    -o jsonpath='{.status.addresses[0].value}')"
BASE_URL="${GW}/${NS}/${SVC}"

info "canary: base model through the gateway"
for _ in $(seq 60); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 25 -X POST \
        -H 'Content-Type: application/json' \
        -d '{"model":"model-dyn","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
        "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && break
    sleep 10
done
[[ "$code" == "200" ]] || err "canary returned ${code}, not 200"
ok "serving"

n=$(curl -sS --max-time 20 "${BASE_URL}/v1/models" 2>/dev/null | python3 -c '
import json,sys
print(sum(1 for m in json.load(sys.stdin).get("data",[]) if m.get("parent")))' 2>/dev/null || echo "?")

printf '\n%bready%b\n\n' "$BOLD" "$NC"
cat <<EOF
  route indexes   model-dyn + ${ADAPTERS[*]}
  adapters loaded ${n}   (none preloaded)

  export KUBECONFIG=${KUBECONFIG}
  export B=${BASE_URL}

EOF
printf '  %b./lora.sh list%b            what is loaded right now\n' "$BOLD" "$NC"
printf '  %b./lora.sh load adapter-1%b  from the PVC, no restart\n' "$BOLD" "$NC"
printf '  %b./check.sh%b                does /v1/models match reality?\n\n' "$BOLD" "$NC"
