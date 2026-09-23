# Shared configuration and helpers for the maas-epp-filter-order spike.
# Sourced by setup.sh, validate.sh, fix.sh and the scripts under scripts/.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${YELLOW}INFO${NC}: $1"; }
ok()      { echo -e "${GREEN}  OK${NC}: $1"; }
warn()    { echo -e "${CYAN}WARN${NC}: $1"; }
fail()    { echo -e "${RED}FAIL${NC}: $1"; }
# With STATUS_ON_ERR=1 (setup.sh, validate.sh) a fatal error prints the
# dashboard first, so the failure arrives with the state that produced it.
err() {
    echo -e "${RED}FAIL${NC}: $1"
    if [[ "${STATUS_ON_ERR:-0}" == 1 && -x "$SCRIPT_DIR/scripts/status.sh" ]]; then
        STATUS_ON_ERR=0 "$SCRIPT_DIR/scripts/status.sh" 2>/dev/null || true
    fi
    exit 1
}
step()    { echo -e "${CYAN}==>${NC} $1"; }
substep() { echo "    $1"; }
header()  { echo -e "\n${BOLD}$1${NC}"; }

# A stale DOCKER_HOST pointing at a dead rootless socket breaks docker and kind
# even when the rootful daemon is healthy. `:=` does not help: the variable IS
# set, it just points at a socket that no longer exists.
docker_socket_guard() {
    if [[ -n "${DOCKER_HOST:-}" ]]; then
        local sock="${DOCKER_HOST#unix://}"
        if [[ ! -S "$sock" && -S /var/run/docker.sock ]]; then
            unset DOCKER_HOST
        fi
    fi
}

CLUSTER_NAME="${CLUSTER_NAME:-maas-epp-spike}"
# The model namespace. Everything else (gateway, MaaS, Kuadrant) lives where
# the vendored MaaS installer puts it.
NS="${NS:-maas-epp-spike}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-istio-system}"
GATEWAY_NAME="${GATEWAY_NAME:-maas-default-gateway}"
MAAS_NAMESPACE="${MAAS_NAMESPACE:-maas-system}"
SUBSCRIPTION_NAMESPACE="${SUBSCRIPTION_NAMESPACE:-models-as-a-service}"

# Scoped so the other kind clusters on this host cannot be reached by accident.
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"

# The MaaS checkout is read, never written: the vendored installer sources
# scripts/deployment-helpers.sh and builds kustomize from deployment/ there.
MAAS_REPO="${MAAS_REPO:-/home/bartek/code/work/model-serving/maas-billing/models-as-a-service}"

# Versions. Istio 1.29.x is the intersection of what the MaaS installer pins,
# what Kuadrant 1.5 tests against, and what KServe needs for InferencePool v1.
ISTIO_VERSION="${ISTIO_VERSION:-1.29.2}"
# 1.5.x injects the wasm-shim through an EnvoyFilter INSERT_BEFORE the router,
# which is the RHCL 1.4 behaviour under test. 1.4.x (WasmPlugin CR) is the
# control, where the EPP is invoked without any fix.
KUADRANT_VERSION="${KUADRANT_VERSION:-1.5.3}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-1.3.0}"
CERTMANAGER_VERSION="${CERTMANAGER_VERSION:-1.17.2}"
# MetalLB pool 172.18.<slot>.200-250 on the shared kind docker network, so two
# spike clusters can coexist.
METALLB_SLOT="${METALLB_SLOT:-0}"

# The ODH kserve fork supplies the llmisvc controller manifests, its CRDs and
# the GIE CRD bundle. Empty ref = the fork's default branch; setup records the
# SHA it resolved to.
KSERVE_CLONE="${KSERVE_CLONE:-/tmp/opendatahub-kserve}"
KSERVE_ODH_REF="${KSERVE_ODH_REF:-}"

# The model server behind the pool. `sim` answers instantly and keeps a run at
# two minutes; `vllm-cpu` is real vLLM with a real KV cache, so the EPP scores
# on real queue and cache metrics. The chain and the verdicts are the same.
MODEL_BACKEND="${MODEL_BACKEND:-vllm-cpu}"
SIM_IMAGE="${SIM_IMAGE:-ghcr.io/llm-d/llm-d-inference-sim:v0.7.1}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai-cpu:v0.19.0}"
REPLICAS="${REPLICAS:-${SIM_REPLICAS:-3}}"
SIM_REPLICAS="$REPLICAS"
case "$MODEL_BACKEND" in
    vllm-cpu)
        LLMISVC_NAME="${LLMISVC_NAME:-vllm-pool}"
        # The same tiny model the LoRA spikes run: real vLLM, a few MB of
        # weights, seconds to load.
        MODEL_NAME="${MODEL_NAME:-tiny-llama}"
        MODEL_URI="${MODEL_URI:-hf://hmellor/tiny-random-LlamaForCausalLM}"
        ;;
    sim)
        LLMISVC_NAME="${LLMISVC_NAME:-sim-pool}"
        MODEL_NAME="${MODEL_NAME:-facebook/opt-125m}"
        MODEL_URI="${MODEL_URI:-hf://placeholder/no-model}"
        ;;
    *) echo "unknown MODEL_BACKEND=$MODEL_BACKEND (vllm-cpu|sim)" >&2; exit 2 ;;
esac
# The body value ipp-pre copies verbatim into X-Gateway-Model-Name. KServe's
# generated model-routing rule matches the publisher form exactly.
MODEL_ID="${MODEL_ID:-publishers/${NS}/models/${MODEL_NAME}}"

# Move native EPP after IPP so both request routing and TRLP response processing
# work. The earlier pre-only/first variants reproduce the response defect.
FIX_VARIANT="${FIX_VARIANT:-epp-after-ipp}"
FIX_EF_NAME="payload-processing-epp-order"
REQUESTS="${REQUESTS:-20}"

MANIFESTS="${SCRIPT_DIR}/manifests"
results_slug() {
    printf 'kuadrant-%s+istio-%s+%s' "$KUADRANT_VERSION" "$ISTIO_VERSION" "$MODEL_BACKEND"
}
RESULTS="${RESULTS:-${SCRIPT_DIR}/results/$(results_slug)}"

# oc where present, kubectl otherwise, so the diagnostic runs unchanged on
# OpenShift.
if [[ -z "${KUBECTL:-}" ]]; then
    if command -v oc >/dev/null 2>&1; then KUBECTL=oc; else KUBECTL=kubectl; fi
fi
kc() { "$KUBECTL" "$@"; }
# scripts/check-filter-order.sh is standalone and reads these from the
# environment.
export KUBECTL GATEWAY_NAME GATEWAY_NAMESPACE

# A bare istioctl on this host resolves to whatever mise's global default is.
# The vendored installer only downloads istioctl when none is on PATH, so it
# has to be run under the pinned one.
istioctl_pinned() {
    mise x "istioctl@${ISTIO_VERSION}" -- istioctl "$@"
}

# Longer placeholders first: NAMESPACE_ is a suffix of several of them.
render_manifest() {
    local file="${1:?manifest required}"
    sed -e "s|SUBSCRIPTIONNAMESPACE_|${SUBSCRIPTION_NAMESPACE}|g" \
        -e "s|GATEWAYNAMESPACE_|${GATEWAY_NAMESPACE}|g" \
        -e "s|MAASNAMESPACE_|${MAAS_NAMESPACE}|g" \
        -e "s|GATEWAYNAME_|${GATEWAY_NAME}|g" \
        -e "s|LLMISVCNAME_|${LLMISVC_NAME}|g" \
        -e "s|MODELNAME_|${MODEL_NAME}|g" \
        -e "s|SIMIMAGE_|${SIM_IMAGE}|g" \
        -e "s|VLLMIMAGE_|${VLLM_IMAGE}|g" \
        -e "s|MODELURI_|${MODEL_URI}|g" \
        -e "s|SIMREPLICAS_|${REPLICAS}|g" \
        -e "s|REPLICAS_|${REPLICAS}|g" \
        -e "s|NAMESPACE_|${NS}|g" \
        "$file"
}

# The newest Running and Ready gateway pod. `.items[0]` can be a Terminating
# pod during a rollout, and a capture taken through it describes the previous
# configuration while the run is stamped with the new one.
gateway_pod() {
    kc get pod -n "$GATEWAY_NAMESPACE" -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
        -o json 2>/dev/null | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except ValueError:
    raise SystemExit
best = None
for pod in payload.get("items", []):
    if pod["status"].get("phase") != "Running":
        continue
    if pod["metadata"].get("deletionTimestamp"):
        continue
    if not any(c["type"] == "Ready" and c["status"] == "True"
               for c in pod["status"].get("conditions", [])):
        continue
    stamp = pod["metadata"]["creationTimestamp"]
    if best is None or stamp >= best[0]:
        best = (stamp, pod["metadata"]["name"])
if best:
    print(best[1])
'
}

gateway_pod_image() {
    local pod
    pod="$(gateway_pod)"
    [[ -n "$pod" ]] || return 1
    kc get pod -n "$GATEWAY_NAMESPACE" "$pod" \
        -o jsonpath='{.spec.containers[?(@.name=="istio-proxy")].image}' 2>/dev/null
}

# Envoy's admin API read from inside the gateway pod. istioctl proxy-config is
# not used: a client skewed from istiod returns empty JSON with exit 0.
envoy_admin() {
    local path="${1:?path required}" pod
    pod="$(gateway_pod)"
    [[ -n "$pod" ]] || { echo ""; return 1; }
    kc exec -n "$GATEWAY_NAMESPACE" "$pod" -c istio-proxy -- \
        curl -s --max-time 20 "localhost:15000/${path}" 2>/dev/null
}

# Captures to a file and refuses to return an empty one; every assertion reads
# these files and an empty capture would make each of them vacuously true.
capture() {
    local path="${1:?path required}" out="${2:?out file required}"
    mkdir -p "$(dirname "$out")"
    envoy_admin "$path" > "$out" || true
    [[ -s "$out" ]] || return 1
    return 0
}

gateway_url() {
    if [[ -n "${GATEWAY_URL:-}" ]]; then echo "$GATEWAY_URL"; return; fi
    local addr
    addr=$(kc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    [[ -n "$addr" ]] && echo "http://$addr"
}

wait_for_gateway() {
    local timeout="${1:-180}" deadline
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        local p
        p=$(kc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
        if [[ "$p" == "True" && -n "$(gateway_url)" ]]; then
            return 0
        fi
        sleep 3
    done
    return 1
}

wait_llmisvc_ready() {
    local name="$1" ns="$2" timeout="${3:-600}"
    if ! kc wait llmisvc "$name" -n "$ns" --for=condition=Ready --timeout="${timeout}s" >/dev/null 2>&1; then
        kc get llmisvc "$name" -n "$ns" \
            -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}: {.message}){"\n"}{end}' 2>/dev/null || true
        return 1
    fi
}

# Polls a jsonpath on an object until it equals the wanted value, reporting
# what it sees every WAIT_REPORT seconds so a stuck wait says what is stuck.
wait_for_field() {
    local what="${1:?kind/name required}" ns="${2:?ns required}" path="${3:?jsonpath required}" \
          want="${4:?value required}" timeout="${5:-180}" deadline got last_report=0 now
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        got=$(kc get "$what" -n "$ns" -o jsonpath="$path" 2>/dev/null || true)
        [[ "$got" == "$want" ]] && return 0
        now=$(date +%s)
        if (( now - last_report >= ${WAIT_REPORT:-15} )); then
            substep "waiting for ${ns}/${what} ${path} == ${want} (now: '${got:-<empty>}', $(( deadline - now ))s left)" >&2
            last_report=$now
        fi
        sleep 3
    done
    echo "$got"
    return 1
}

# Prints the dashboard when a script dies mid-step, so the failure comes with
# the state that produced it.
on_error() {
    local rc=$?
    echo -e "\n${RED}FAIL${NC}: ${BASH_SOURCE[1]##*/} failed at line ${BASH_LINENO[0]} (exit ${rc}); state at failure:" >&2
    "$SCRIPT_DIR/scripts/status.sh" 2>/dev/null || true
    exit "$rc"
}

# ---------------------------------------------------------------------------
# EPP metrics. Port 9090 is plain HTTP but authenticated, and the API-server
# pod proxy strips the credentials, so a port-forward to the POD is the only
# way in.
# ---------------------------------------------------------------------------
epp_pod() {
    kc get pod -n "$NS" \
        -l "app.kubernetes.io/component=llminferenceservice-router-scheduler,app.kubernetes.io/name=${LLMISVC_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# 29090, not 19090: the vendored MaaS installer forwards the gateway on 19090
# and a leftover forward there would be mistaken for the EPP.
epp_scrape() {
    local out="${1:?out file required}" port="${EPP_METRICS_PORT:-29090}" pod token pf rc=1
    pod=$(epp_pod)
    [[ -n "$pod" ]] || { warn "no EPP pod for $NS/$LLMISVC_NAME" >&2; return 1; }
    if ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port"; then
        warn "local port $port is already bound; another port-forward would read the wrong EPP" >&2
        return 1
    fi
    token=$(kc create token metrics-reader -n "$NS" --duration=1h 2>/dev/null) \
        || { warn "cannot mint metrics-reader token in $NS" >&2; return 1; }
    # The binary, not the kc wrapper: backgrounding a function makes $! a
    # subshell, and killing that leaves the real port-forward holding the port.
    "$KUBECTL" port-forward -n "$NS" "pod/$pod" "${port}:9090" >/dev/null 2>&1 &
    pf=$!
    for _ in $(seq 1 60); do
        if curl -sf -o /dev/null --max-time 5 -H "Authorization: Bearer $token" \
               "http://127.0.0.1:${port}/metrics"; then rc=0; break; fi
        sleep 0.5
    done
    if [[ $rc -eq 0 ]]; then
        mkdir -p "$(dirname "$out")"
        curl -sf --max-time 20 -H "Authorization: Bearer $token" \
            "http://127.0.0.1:${port}/metrics" > "$out" || rc=1
    fi
    kill "$pf" 2>/dev/null || true
    wait "$pf" 2>/dev/null || true
    [[ $rc -eq 0 ]] || { warn "EPP metrics scrape failed" >&2; return 1; }
    echo "$pod"
}

# Picker invocations. Both the metric name and the label token are anchored:
# the family also carries extension_point="ProfilePicker".
epp_picker_total() {
    awk '/^inference_extension_plugin_duration_seconds_count\{/ && /extension_point="Picker"[,}]/ {s+=$NF}
         END {printf "%d", s+0}' "$1"
}

epp_sched_total() {
    awk '/^llm_d_epp_scheduler_attempts_total\{/ {s+=$NF} END {printf "%d", s+0}' "$1"
}

# NA when the family is absent, so a renamed metric cannot read as zero.
epp_ready_endpoints() {
    awk '/^llm_d_epp_ready_endpoints\{/ {s+=$NF; n++}
         END {if (n) printf "%d", s+0; else printf "NA"}' "$1"
}

epp_picks_by_pod() {
    sed -nE 's/^llm_d_epp_scheduler_attempts_total\{.*endpoint_name="([^"]+)".*\} ([0-9.e+-]+)$/\1\t\2/p' "$1" \
        | awk -F'\t' '{s[$1]+=$2} END {for (k in s) printf "%s\t%d\n", k, s[k]}' | sort
}

model_pods() {
    kc get pod -n "$NS" -l "app.kubernetes.io/name=${LLMISVC_NAME},kserve.io/component=workload" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}

# vLLM's own /metrics from every model pod, through the API server proxy
# (plain HTTP, no auth on that port). Files: <dir>/vllm-<pod>-<tag>.prom.
vllm_scrape_all() {
    local dir="${1:?dir required}" tag="${2:?tag required}" pod
    for pod in $(model_pods); do
        kc get --raw "/api/v1/namespaces/${NS}/pods/${pod}:8000/proxy/metrics" \
            > "$dir/vllm-${pod}-${tag}.prom" 2>/dev/null || rm -f "$dir/vllm-${pod}-${tag}.prom"
    done
}

# A MaaS API key, minted the way the MaaS installer's own --validate does:
# through maas-api's pod, with the identity headers the gateway would set.
# A key is bound to one MaaSSubscription; name the pool's, or maas-api picks
# the highest-priority one the user can see, which may cover another pool.
maas_api_key() {
    local user="${1:-epp-spike}" sub="${2:-epp-spike-${LLMISVC_NAME}}"
    kc exec -n "$MAAS_NAMESPACE" deployment/maas-api -- curl -sk --max-time 20 \
        "https://localhost:8443/v1/api-keys" \
        -H "X-MaaS-Username: ${user}" \
        -H 'X-MaaS-Group: ["system:authenticated"]' \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${user}\",\"subscription\":\"${sub}\"}" 2>/dev/null | jq -r '.key // empty'
}

# The diagnostic's verdict for EPP_ENGAGED: OK, BROKEN, N/A or empty on error.
chain_verdict() {
    "$SCRIPT_DIR/scripts/check-filter-order.sh" --json 2>/dev/null \
        | jq -r '.verdicts.EPP_ENGAGED // empty'
}

# Polls the live chain until the diagnostic reports the wanted verdict. xDS
# convergence has no readiness condition, but it has an observable end state.
wait_for_chain() {
    local want="${1:?verdict required}" timeout="${2:-120}" deadline got
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        got="$(chain_verdict || true)"
        [[ "$got" == "$want" ]] && return 0
        sleep 2
    done
    echo "$got"
    return 1
}

image_digest() {
    local ns="$1" selector="$2"
    kc get pod -n "$ns" -l "$selector" -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null
}
