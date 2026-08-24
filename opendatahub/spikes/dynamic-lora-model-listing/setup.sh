#!/usr/bin/env bash
# Stand up the on-demand LoRA fixture, end to end.
#
# Assumes a cluster that already has kserve, Gateway API, Istio and a Gateway
# named kserve/kserve-ingress-gateway. The sibling spike builds one:
#
#   ../lora-httproute-budget/setup.sh --with-kserve
#
# and its .kubeconfig is picked up automatically if this spike has none.
#
# What this does, in order, because the order matters:
#
#   1. namespace + PVC
#   2. seed the PVC with N tiny adapters -- via a throwaway pod, because a
#      WaitForFirstConsumer PVC does not bind until something mounts it, and
#      the workload must not be that something: vLLM has to start with the
#      adapters already present
#   3. BOOTSTRAP: apply the service WITH spec.model.lora declaring the adapters,
#      so the controller generates its own route
#   4. capture those rules, then strip spec.model.lora
#   5. re-apply with the captured rules inline via spec.router.route.http.spec
#   6. DestinationRule for the EPP, or every pool-bound request 500s while the
#      route, the pool and the EPP all report healthy
#   7. wait on a real request, not a sleep
#
# Steps 3-5 exist so the route is byte-identical to a kserve-managed one for N
# adapters while the runtime starts empty. Hand-writing the route instead would
# introduce a difference that then has to be reasoned about in every result.
#
# Usage:
#   ./setup.sh              # 4 adapters
#   ./setup.sh 7            # more
#   ./setup.sh --teardown
#
# Environment: NS, SVC, KUBECONFIG

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-dynamic-lora}"
SVC="${SVC:-svc-dyn}"
PVC="dynlora-models"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  ok${NC} $*"; }
warn() { echo -e "${YEL}  !${NC} $*"; }

# Borrow the sibling spike's kubeconfig if we have none of our own.
if [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -f "${SCRIPT_DIR}/.kubeconfig" ]]; then
        export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig"
    elif [[ -f "${SCRIPT_DIR}/../lora-httproute-budget/.kubeconfig" ]]; then
        export KUBECONFIG="$(cd "${SCRIPT_DIR}/../lora-httproute-budget" && pwd)/.kubeconfig"
        cp "$KUBECONFIG" "${SCRIPT_DIR}/.kubeconfig"
        export KUBECONFIG="${SCRIPT_DIR}/.kubeconfig"
        warn "using ../lora-httproute-budget/.kubeconfig"
    fi
fi

if [[ "${1:-}" == "--teardown" ]]; then
    info "deleting namespace ${NS}"
    kubectl delete namespace "$NS" --wait=false 2>/dev/null || true
    ok "done"
    exit 0
fi

A="${1:-4}"
ADAPTERS=(); for i in $(seq 1 "$A"); do ADAPTERS+=("adapter-${i}"); done

# --- 0. preflight -----------------------------------------------------------
info "checking the cluster"
kubectl get gateway kserve-ingress-gateway -n kserve >/dev/null 2>&1 || {
    echo -e "${RED}no Gateway kserve/kserve-ingress-gateway.${NC}"
    echo "Build a cluster first: ../lora-httproute-budget/setup.sh --with-kserve"
    exit 1
}
kubectl get crd llminferenceservices.serving.kserve.io >/dev/null 2>&1 || {
    echo -e "${RED}kserve LLMInferenceService CRD not installed.${NC}"; exit 1; }
ok "gateway and kserve present"

# --- 1. namespace + PVC -----------------------------------------------------
info "namespace and PVC"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 128Mi
EOF
ok "${NS}/${PVC}"

# --- 2. seed the adapters ---------------------------------------------------
info "seeding ${#ADAPTERS[@]} adapters into the PVC"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
"${SCRIPT_DIR}/hack/gen-adapter.py" "$STAGE" "${ADAPTERS[@]}" | sed 's/^/  /'

kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: lora-seeder
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - {name: models, mountPath: /models}
  volumes:
    - name: models
      persistentVolumeClaim: {claimName: ${PVC}}
EOF
kubectl wait --for=condition=Ready "pod/lora-seeder" -n "$NS" --timeout=300s >/dev/null
for a in "${ADAPTERS[@]}"; do
    kubectl cp "${STAGE}/${a}" "${NS}/lora-seeder:/models/${a}" >/dev/null 2>&1
done
kubectl exec -n "$NS" lora-seeder -- ls /models | sed 's/^/  /'
kubectl delete pod lora-seeder -n "$NS" --wait=false >/dev/null 2>&1
ok "seeded"

# --- 3. bootstrap: declare the adapters so kserve generates a route ---------
info "bootstrap: declaring ${A} adapters so the controller emits a route"
python3 - "$A" >"${STAGE}/bootstrap.yaml" <<'PY'
import re, sys, yaml
n = int(sys.argv[1])
docs = list(yaml.safe_load_all(open("manifests/fixture.yaml")))
for d in docs:
    if d and d.get("kind") == "LLMInferenceService":
        d["spec"]["model"]["lora"] = {"adapters": [
            {"name": f"adapter-{i}", "uri": f"pvc://dynlora-models/adapter-{i}"}
            for i in range(1, n + 1)]}
        d["spec"]["router"]["route"] = {}          # managed route, for now
yaml.safe_dump_all([d for d in docs if d], sys.stdout, sort_keys=False)
PY
kubectl apply -f "${STAGE}/bootstrap.yaml" >/dev/null
ok "applied"

# --- 4. capture, then strip -------------------------------------------------
info "capturing the generated route"
"${SCRIPT_DIR}/hack/capture-route.sh" "$A" 2>&1 | sed 's/^/  /'

# --- 5. re-apply with the captured rules inline -----------------------------
info "re-applying with the captured rules inline, no spec.model.lora"
python3 - <<'PY'
import yaml
rules = yaml.safe_load(open("manifests/route-rules.yaml"))["rules"]
docs = list(yaml.safe_load_all(open("manifests/fixture.yaml")))
for d in docs:
    if d and d.get("kind") == "LLMInferenceService":
        d["spec"]["model"].pop("lora", None)
        d["spec"]["router"]["route"] = {"http": {"spec": {"rules": rules}}}
yaml.safe_dump_all([d for d in docs if d], open("/tmp/.dynlora-final.yaml", "w"),
                   sort_keys=False)
PY
kubectl apply -f /tmp/.dynlora-final.yaml >/dev/null
rm -f /tmp/.dynlora-final.yaml
ok "applied"

# --- 5b. istiod, which the churn above can knock over ------------------------
# Steps 3-5 write the route twice in quick succession, and several routes
# merging on one gateway is the shape that trips istio's mergeHTTPRoutes data
# race (concurrent map writes at route_collections.go:868). istiod
# crash-loops, its validating webhook stops answering, and the next apply fails
# with "connection refused" -- which looks like a cluster problem rather than a
# known bug that a restart clears.
istiod_ready() {
    kubectl get pod -n istio-system -l app=istiod \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true
}
info "checking istiod"
if ! istiod_ready; then
    warn "istiod is not ready (likely the mergeHTTPRoutes race); restarting"
    kubectl rollout restart deploy/istiod -n istio-system >/dev/null 2>&1 || true
    kubectl rollout status deploy/istiod -n istio-system --timeout=300s >/dev/null 2>&1 || true
fi
for _ in $(seq 30); do istiod_ready && break; sleep 10; done
istiod_ready || { echo -e "${RED}istiod will not stay up; cannot continue${NC}"; exit 1; }
ok "istiod ready"

# --- 6. the DestinationRule everyone forgets --------------------------------
info "DestinationRule for the endpoint picker"
# Istio originates mTLS to mesh workloads; the EPP serves plaintext gRPC on
# 9002. Without this the ext_proc stream is reset and every pool-bound request
# returns 500 while the route, the pool and the EPP all report healthy.
kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: ${SVC}-epp-service-tls
spec:
  host: ${SVC}-epp-service
  trafficPolicy:
    tls:
      mode: SIMPLE
      insecureSkipVerify: true
EOF
ok "${SVC}-epp-service-tls"

# --- 7. wait on a request, not a sleep --------------------------------------
info "waiting for the workload"
kubectl wait --for=condition=Ready pod \
    -l "app.kubernetes.io/name=${SVC}" -n "$NS" --timeout=900s >/dev/null 2>&1 || true

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
[[ "$code" == "200" ]] || { echo -e "${RED}canary returned ${code}, not 200${NC}"; exit 1; }
ok "serving"

n=$(curl -sS --max-time 20 "${BASE_URL}/v1/models" 2>/dev/null | python3 -c '
import json,sys
print(sum(1 for m in json.load(sys.stdin).get("data",[]) if m.get("parent")))' 2>/dev/null || echo "?")

cat <<EOF

$(printf "%b" "${BOLD}")ready$(printf "%b" "${NC}")

  route indexes   model-dyn + ${ADAPTERS[*]}
  adapters loaded ${n}   (nothing preloaded -- that is the point)

  export B=${BASE_URL}

  curl -s \$B/v1/models | jq -r '.data[] | select(.parent) | .id'
  curl -s -X POST \$B/v1/load_lora_adapter -H 'Content-Type: application/json' \\
    -d '{"lora_name":"adapter-1","lora_path":"/mnt/lora/adapter-1"}'

  $(printf "%b" "${BOLD}")./probe-listing.sh$(printf "%b" "${NC}")   the three checks
  $(printf "%b" "${BOLD}")./adapterctl.sh list$(printf "%b" "${NC}") load/unload treating both names as one adapter
EOF
