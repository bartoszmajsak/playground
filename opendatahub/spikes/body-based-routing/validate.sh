#!/usr/bin/env bash
# Body-Based Routing - validation
#
# One test matrix, two backends:
#
#   --cluster (default)  through kind + Istio, exercising the rendered EnvoyFilter
#                        Istio's EnvoyFilter translation. Needs ./setup.sh.
#   --docker             the same filter chain as a plain Envoy bootstrap on the
#                        Istio proxy image, in Docker. ~20s, no cluster, and the
#                        only mode that can compare filter-chain designs.
#
# If --docker fails, the Envoy config is wrong and there is no point booting
# kind. If --docker passes but --cluster fails, the problem is Istio's
# EnvoyFilter translation, not the filters.
#
# Profiles (both modes, see profiles/<name>.yaml):
#   metadata-filter   json_to_metadata + header_mutation - the shipped design
#   lua               pure Lua, handle:body()
#   lua-body-chunks   pure Lua, handle:bodyChunks() - streams, cannot set headers
#   wasm              compiled proxy-wasm module (needs ./build-wasm.sh first)
#
# Usage:
#   ./validate.sh                                 # in-cluster, shipped design
#   ./validate.sh --size 8,30,40                  # prove the 32MiB limit
#   ./validate.sh --docker                        # fast loop, no cluster
#   ./validate.sh --docker --all --buffer 1       # compare every design
#   ./validate.sh --profile wasm             # wasm module, in-cluster
#
# Options:
#   --cluster            run against the kind cluster (default)
#   --docker             run against Envoy in Docker
#   --profile <name>     filter chain to test, in either mode
#   --all                run every profile and print a comparison table (--docker)
#   --buffer <MiB>       listener buffer limit, in either mode (default 32)
#   --size <a,b,c>       MiB payload sizes for the buffer-limit test
#   -v, --verbose        print every request and response
#   -h, --help           this text
#
# Environment:
#   NS, SETTLE, PROXY_IMAGE, ECHO_IMAGE, PORT, GATEWAY_URL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-bbr-spike}"
SETTLE="${SETTLE:-8}"
PROXY_IMAGE="${PROXY_IMAGE:-docker.io/istio/proxyv2:1.28.1}"
ECHO_IMAGE="${ECHO_IMAGE:-mendhak/http-https-echo:37}"
PORT="${PORT:-10000}"
MODEL_HEADER="x-gateway-model-name"

TARGET=cluster
PROFILE=metadata-filter
VERBOSE="${VERBOSE:-false}"
SIZES="${SIZES:-2}"
BUFFER_MIB=""
RUN_ALL=false
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster)    TARGET=cluster ;;
        --docker)     TARGET=docker ;;
        --profile)    PROFILE="$2"; shift ;;
        --profile=*)  PROFILE="${1#*=}" ;;
        --all)        RUN_ALL=true; TARGET=docker ;;
        --buffer)     BUFFER_MIB="$2"; shift ;;
        --buffer=*)   BUFFER_MIB="${1#*=}" ;;
        --size)       SIZES="$2"; shift ;;
        --size=*)     SIZES="${1#*=}" ;;
        -v|--verbose) VERBOSE=true ;;
        -h|--help)    sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)           echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
        *)            POSITIONAL+=("$1") ;;
    esac
    shift
done
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

# Default the buffer limit to whatever the committed EnvoyFilter uses, so the
# two do not silently drift apart.
CONFIGURED_MIB=$(( $(grep -o 'per_connection_buffer_limit_bytes: [0-9]*' \
    "${SCRIPT_DIR}/manifests/envoyfilter.yaml" | awk '{print $2}') / 1024 / 1024 ))
[[ -z "$BUFFER_MIB" ]] && BUFFER_MIB="$CONFIGURED_MIB"

[[ "$TARGET" == "cluster" ]] && export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FAILURES=0
pass()   { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail()   { echo -e "  ${RED}FAIL${NC}: $1"; FAILURES=$((FAILURES + 1)); }
info()   { echo -e "  ${CYAN}INFO${NC}: $1"; }
warn()   { echo -e "  ${YELLOW}WARN${NC}: $1"; }
header() { echo -e "\n${BOLD}$1${NC}"; }

RESP=$(mktemp)
HDRS=$(mktemp)
CONF=$(mktemp)
cleanup() {
    rm -f "$RESP" "$HDRS" "$CONF"
    [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true
    if [[ "$TARGET" == "docker" ]]; then
        docker rm -f bbr-sa-echo bbr-sa-envoy >/dev/null 2>&1 || true
        docker network rm bbr-standalone >/dev/null 2>&1 || true
    fi
    return 0
}
trap cleanup EXIT

# --- request helpers ------------------------------------------------------

# Istio stuffs a base64 blob into every request; it drowns everything else.
ECHO_JQ='{method, path, headers: (.headers | del(.["x-envoy-peer-metadata"], .["x-envoy-peer-metadata-id"]))}'

dump_exchange() {
    [[ "$VERBOSE" == "true" ]] || return 0
    echo -e "  ${BOLD}>${NC} ${LAST_METHOD} ${LAST_URL}"
    [[ -n "$LAST_CTYPE" ]] && echo "  > Content-Type: ${LAST_CTYPE}"
    local i
    for i in ${LAST_EXTRA[@]+"${LAST_EXTRA[@]}"}; do
        [[ "$i" == -* ]] || echo "  > $i"
    done
    [[ -n "$LAST_BODY" ]] && echo "  > ${LAST_BODY:0:160}"
    echo -e "  ${BOLD}<${NC} HTTP ${HTTP_CODE}"
    grep -iE '^x-served-by:' "$HDRS" | tr -d '\r' | sed 's/^/  < /' || true
    echo "  < $(jq -c "$ECHO_JQ" "$RESP" 2>/dev/null | head -c 420 || head -c 160 "$RESP")"
    echo ""
}

# req <method> <path> <content-type> <body> [extra curl args...]
req() {
    local method="$1" path="$2" ctype="$3" body="$4"; shift 4
    LAST_METHOD="$method"; LAST_URL="${GATEWAY_URL}${path}"
    LAST_CTYPE="$ctype"; LAST_BODY="$body"; LAST_EXTRA=("$@")
    local args=(-s -o "$RESP" -D "$HDRS" -w '%{http_code}' --max-time 180 -X "$method")
    [[ -n "$ctype" ]] && args+=(-H "Content-Type: ${ctype}")
    [[ -n "$body" ]] && args+=(--data-binary "$body")
    args+=("$@" "${GATEWAY_URL}${path}")
    HTTP_CODE=$(curl "${args[@]}" || echo "000")
    dump_exchange
}

got_header() { jq -r --arg h "$MODEL_HEADER" '.headers[$h] // ""' "$RESP" 2>/dev/null || echo ""; }
served_by()  { grep -i '^x-served-by:' "$HDRS" | awk '{print $2}' | tr -d '\r'; }

check() {
    local label="$1" want_header="$2" want_backend="$3"
    local got backend
    got=$(got_header); backend=$(served_by)
    if [[ "$got" == "$want_header" && "$backend" == "$want_backend" && "$HTTP_CODE" == "200" ]]; then
        pass "$label (${MODEL_HEADER}='${got:-<absent>}', served by ${backend})"
    else
        fail "$label: HTTP ${HTTP_CODE}, ${MODEL_HEADER}='${got:-<absent>}' (want '${want_header:-<absent>}'), served by '${backend:-?}' (want ${want_backend})"
    fi
}

# --- backends -------------------------------------------------------------

start_docker() {
    local profile="$1"
    local frag="${SCRIPT_DIR}/profiles/${profile}.yaml"
    [[ -f "$frag" ]] || { echo "no such profile: $profile" >&2; exit 2; }

    python3 - "${SCRIPT_DIR}/profiles/_base.yaml" "$frag" "$CONF" \
        "$((BUFFER_MIB * 1024 * 1024))" <<'PY'
import sys
base, frag, out, limit = sys.argv[1:5]
cfg = open(base).read().replace("__BUFFER_LIMIT__", limit)
cfg = cfg.replace("__FILTERS__\n", open(frag).read())
open(out, "w").write(cfg)
PY

    local mounts=(-v "${CONF}:/etc/envoy/envoy.yaml:ro")
    if [[ "$profile" == "wasm" ]]; then
        local wasm="${SCRIPT_DIR}/profiles/wasm-module/target/wasm32-wasip1/release/model_router.wasm"
        [[ -f "$wasm" ]] || { warn "wasm module not built - run ./build-wasm.sh"; return 1; }
        mounts+=(-v "${wasm}:/etc/envoy/model_router.wasm:ro")
    fi

    docker network create bbr-standalone >/dev/null 2>&1 || true
    docker inspect bbr-sa-echo >/dev/null 2>&1 || docker run -d --name bbr-sa-echo \
        --network bbr-standalone --network-alias echo -e HTTP_PORT=8080 "$ECHO_IMAGE" >/dev/null
    docker rm -f bbr-sa-envoy >/dev/null 2>&1 || true
    docker run -d --name bbr-sa-envoy --network bbr-standalone -p "${PORT}:10000" \
        "${mounts[@]}" --entrypoint /usr/local/bin/envoy "$PROXY_IMAGE" \
        -c /etc/envoy/envoy.yaml --log-level warn --component-log-level wasm:info >/dev/null

    GATEWAY_URL="http://localhost:${PORT}"
    local i
    for i in $(seq 1 30); do
        req POST /v1/chat/completions application/json '{"model":"warmup","messages":[]}'
        [[ "$HTTP_CODE" == "200" ]] && {
            info "Envoy: $(docker exec bbr-sa-envoy /usr/local/bin/envoy --version 2>&1 | grep -o 'version:.*' || echo unknown)"
            return 0
        }
        sleep 1
    done
    docker logs bbr-sa-envoy 2>&1 | tail -15
    fail "Envoy did not serve traffic for profile '$profile' (last HTTP ${HTTP_CODE})"
    warn "A missing extension shows as: Didn't find a registered implementation for name"
    return 1
}

start_cluster() {
    local profile="$1"
    header "Setup"
    kubectl apply -f "${SCRIPT_DIR}/manifests/workloads.yaml" >/dev/null
    kubectl wait -n "$NS" --for=condition=Available deploy/echo-a deploy/echo-b --timeout=180s >/dev/null
    info "Echo backends ready"

    # The module lives outside the proxy image, so it has to reach the gateway
    # pod somehow. A ConfigMap plus a volume patch keeps it to kubectl - no
    # registry, no custom image. 96KiB fits a ConfigMap's 1MiB ceiling; use
    # oci:// via WasmPlugin if the module ever outgrows it.
    #
    # Note the annotations route does NOT work here: sidecar.istio.io/userVolume
    # reaches the pod template but Istio's Gateway-API deployment ignores it,
    # that is a sidecar-injection-template feature. Patching the Deployment
    # directly does work, and survives Istio's reconciliation.
    if [[ "$profile" == "wasm" ]]; then
        local wasm="${SCRIPT_DIR}/profiles/wasm-module/target/wasm32-wasip1/release/model_router.wasm"
        [[ -f "$wasm" ]] || { fail "wasm module not built - run ./build-wasm.sh"; return 1; }
        kubectl create configmap model-router-wasm -n "$NS" \
            --from-file=model_router.wasm="$wasm" --dry-run=client -o yaml \
            | kubectl apply -f - >/dev/null
        # Envoy loads the module once at startup, and updating a ConfigMap does
        # not restart anything - so without this the proxy happily keeps running
        # a stale build and you debug a bug you already fixed. Stamping the
        # module's hash on the pod template makes any rebuild roll the pod.
        local sum
        sum=$(sha256sum "$wasm" | cut -c1-16)
        kubectl patch deploy spike-gateway-istio -n "$NS" --type=strategic -p '{
          "spec":{"template":{
            "metadata":{"annotations":{"bbr-spike/wasm-sha256":"'"$sum"'"}},
            "spec":{
              "volumes":[{"name":"wasm","configMap":{"name":"model-router-wasm"}}],
              "containers":[{"name":"istio-proxy","volumeMounts":[
                {"name":"wasm","mountPath":"/var/local/lib/wasm","readOnly":true}]}]
          }}}}' >/dev/null
        info "Mounting the wasm module into the gateway pod (sha ${sum})"
        kubectl rollout status deploy/spike-gateway-istio -n "$NS" --timeout=180s >/dev/null 2>&1 || true
    fi

    info "Rendering EnvoyFilter from profiles/${profile}.yaml"
    NS="$NS" "${SCRIPT_DIR}/render-envoyfilter.sh" "$profile" "$BUFFER_MIB" \
        | sed 's|/etc/envoy/model_router.wasm|/var/local/lib/wasm/model_router.wasm|' \
        | kubectl apply -f - >/dev/null
    info "EnvoyFilter applied, waiting ${SETTLE}s for xDS push"
    sleep "$SETTLE"

    if [[ -z "${GATEWAY_URL:-}" ]]; then
        local addr i
        for i in $(seq 1 30); do
            addr=$(kubectl get gateway spike-gateway -n "$NS" \
                -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
            [[ -n "$addr" ]] && { GATEWAY_URL="http://${addr}"; break; }
            sleep 2
        done
        if [[ -z "${GATEWAY_URL:-}" ]]; then
            warn "No gateway address, falling back to port-forward"
            kubectl port-forward -n "$NS" svc/spike-gateway-istio 8888:80 >/dev/null 2>&1 &
            PF_PID=$!; sleep 3; GATEWAY_URL="http://localhost:8888"
        fi
    fi
    info "Gateway: $GATEWAY_URL"

    local i
    for i in $(seq 1 30); do
        req POST /v1/chat/completions application/json '{"model":"warmup","messages":[]}'
        [[ "$HTTP_CODE" == "200" ]] && { info "Gateway serving traffic"; return 0; }
        sleep 2
    done
    fail "Gateway not serving traffic (last HTTP ${HTTP_CODE})"
    return 1
}

# Only meaningful in cluster mode - proves Istio actually translated the patches
# into the running proxy, rather than just accepting the EnvoyFilter resource.
test_filters_loaded() {
    local profile="$1"
    header "0. Filter chain present in the gateway's Envoy config"
    local pod dump
    pod=$(kubectl get pod -n "$NS" -l gateway.networking.k8s.io/gateway-name=spike-gateway \
        -o jsonpath='{.items[0].metadata.name}')
    info "Gateway pod: $pod"
    dump=$(kubectl exec -n "$NS" "$pod" -c istio-proxy -- \
        pilot-agent request GET config_dump 2>/dev/null || echo "")

    local f
    for f in $(python3 -c "
import yaml,sys
print(' '.join(x['name'] for x in yaml.safe_load(open('${SCRIPT_DIR}/profiles/${profile}.yaml'))))"); do
        grep -q "$f" <<<"$dump" \
            && pass "$f is in the proxy build and configured" \
            || fail "$f not found (unsupported extension, or the patch did not match)"
    done

    grep -q "$((BUFFER_MIB * 1024 * 1024))" <<<"$dump" \
        && pass "Listener buffer limit set to ${BUFFER_MIB}MiB" \
        || fail "per_connection_buffer_limit_bytes patch did not apply"
}

# --- the matrix -----------------------------------------------------------

run_matrix() {
    local tag="$1"

    header "${tag}1. Model name extracted from the JSON payload"
    req POST /v1/chat/completions application/json \
        '{"model":"llama-3-8b-instruct","messages":[{"role":"user","content":"hi"}]}'
    check "chat/completions payload" "llama-3-8b-instruct" "echo-a"
    EXTRACTS=$([[ $(got_header) == "llama-3-8b-instruct" ]] && echo yes || echo no)

    req POST /v1/completions application/json '{"stream":true,"model":"mistral-7b","prompt":"hi"}'
    check "different model, same request path" "mistral-7b" "echo-a"

    header "${tag}2. Body-based routing (route matches on the injected header)"
    info "No headers sent - only the filter chain can produce this match"
    req POST /v1/chat/completions application/json '{"model":"model-b","messages":[]}'
    check "payload alone steers the route" "model-b" "echo-b"
    ROUTES=$([[ $(served_by) == "echo-b" ]] && echo yes || echo no)

    header "${tag}3. Client cannot spoof the header"
    req POST /v1/chat/completions application/json '{"model":"model-a","messages":[]}' \
        -H "${MODEL_HEADER}: model-b"
    check "body wins over client header" "model-a" "echo-a"
    local s1 s2
    s1=$([[ $(served_by) == "echo-a" ]] && echo yes || echo no)

    # The nasty one: pick a content-type the JSON filter skips, so nothing
    # overwrites the client header - and the route was already resolved.
    req POST /v1/chat/completions text/plain 'not json' -H "${MODEL_HEADER}: model-b"
    check "non-JSON request cannot inject or steer" "" "echo-a"
    s2=$([[ $(served_by) == "echo-a" && -z $(got_header) ]] && echo yes || echo no)
    SPOOFPROOF=$([[ "$s1" == yes && "$s2" == yes ]] && echo yes || echo no)

    req POST /v1/chat/completions application/json '{"messages":[]}' -H "${MODEL_HEADER}: model-b"
    check "JSON without a model field cannot inject or steer" "" "echo-a"

    # The client owns the whole body, so it can put a decoy object in front of
    # the real key. Anything matching on substrings rather than JSON structure
    # reads the decoy and routes on it.
    req POST /v1/chat/completions application/json '{"x":{"model":"model-b"},"model":"model-a"}'
    check "nested decoy key cannot steer the route" "model-a" "echo-a"
    NESTED=$([[ $(served_by) == "echo-a" && $(got_header) == "model-a" ]] && echo yes || echo no)

    header "${tag}4. Requests the filter skips still work"
    req GET /healthz "" ""
    check "GET with no body" "" "echo-a"
    req POST /v1/chat/completions text/plain 'not json at all'
    [[ "$HTTP_CODE" == "200" ]] && pass "text/plain POST returned 200" \
                                || fail "text/plain POST returned ${HTTP_CODE}"
    req POST /v1/chat/completions application/json '{"model":'
    check "truncated JSON forwarded untouched" "" "echo-a"

    header "${tag}5. Payload size vs the ${BUFFER_MIB}MiB buffer limit"
    info "\"model\" is the FIRST key in these payloads - if a filter could stop"
    info "early, size would not matter. Sizes: ${SIZES//,/ }MiB"
    BIGOK=""
    local mb body
    for mb in ${SIZES//,/ }; do
        body=$(mktemp)
        python3 -c "import json,sys;sys.stdout.write(json.dumps(
            {'model':'big-${mb}','messages':[{'role':'user','content':'x'*(${mb}*1024*1024 - 200)}]}))" > "$body"
        # A gateway pod that has just rolled will 503 a multi-megabyte upload
        # once before it settles. Retry only 5xx - a 413 or a 200 is the answer
        # we came for and must never be retried away.
        local attempt
        for attempt in 1 2; do
            HTTP_CODE=$(curl -s -o "$RESP" -D "$HDRS" -w '%{http_code}' --max-time 180 \
                -X POST -H 'Content-Type: application/json' --data-binary "@${body}" \
                "${GATEWAY_URL}/v1/chat/completions" || echo "000")
            [[ "$HTTP_CODE" =~ ^5|^000$ ]] || break
            [[ $attempt == 1 ]] && warn "${mb}MiB got ${HTTP_CODE}, retrying once"
            sleep 3
        done
        rm -f "$body"
        LAST_METHOD=POST; LAST_URL="${GATEWAY_URL}/v1/chat/completions"
        LAST_CTYPE=application/json; LAST_BODY="{\"model\":\"big-${mb}\", ... ${mb}MiB ...}"
        LAST_EXTRA=(); dump_exchange

        if [[ $mb -lt $BUFFER_MIB ]]; then
            [[ "$HTTP_CODE" == "413" ]] \
                && fail "${mb}MiB got 413 under a ${BUFFER_MIB}MiB limit - the limit is not in effect" \
                || check "${mb}MiB payload (under limit)" "big-${mb}" "echo-a"
        elif [[ $mb -gt $BUFFER_MIB ]]; then
            # Above the limit a buffering chain MUST refuse; a streaming chain
            # legitimately serves it. Which one happened is the measurement, so
            # only assert the case we actually configured for.
            if [[ "$HTTP_CODE" == "413" ]]; then
                pass "${mb}MiB refused with 413 - limit enforced exactly where configured"
            elif [[ "$HTTP_CODE" == "200" ]]; then
                info "${mb}MiB served (200) - this chain does not buffer the whole body"
            else
                fail "${mb}MiB returned ${HTTP_CODE}"
            fi
        else
            warn "${mb}MiB is exactly the limit - ambiguous, no assertion"
        fi
        # Record the first size's outcome for the comparison table. Guard the
        # assignment with an if, not &&: a false && as the loop body's last
        # command makes the whole function return non-zero under set -e.
        if [[ -z "$BIGOK" ]]; then
            BIGOK=$([[ "$HTTP_CODE" == "200" ]] && echo yes || echo "HTTP $HTTP_CODE")
        fi
    done
}

# --- main -----------------------------------------------------------------

echo ""
echo "============================================================"
echo "  Body-Based Routing Spike - ${TARGET}"
[[ "$TARGET" == "docker" ]] && echo "  proxy: ${PROXY_IMAGE}"
echo "  buffer limit: ${BUFFER_MIB}MiB   payload sizes: ${SIZES}MiB"
echo "============================================================"

if [[ "$TARGET" == "cluster" ]]; then
    start_cluster "$PROFILE" || exit 1
    test_filters_loaded "$PROFILE"
    run_matrix ""
else
    if [[ "$RUN_ALL" == "true" ]]; then
        PROFILES=(metadata-filter lua lua-body-chunks wasm)
    else
        PROFILES=("$PROFILE")
    fi
    SUMMARY=()
    for p in "${PROFILES[@]}"; do
        header "=== profile: ${p} ==="
        EXTRACTS="-"; ROUTES="-"; SPOOFPROOF="-"; NESTED="-"; BIGOK="-"
        if start_docker "$p"; then
            run_matrix "[$p] "
        else
            EXTRACTS="skipped"; ROUTES="skipped"; SPOOFPROOF="skipped"; NESTED="skipped"; BIGOK="skipped"
        fi
        SUMMARY+=("$(printf '%-16s %-9s %-7s %-11s %-7s %s' "$p" "$EXTRACTS" "$ROUTES" "$SPOOFPROOF" "$NESTED" "$BIGOK")")
    done
    if [[ "$RUN_ALL" == "true" ]]; then
        header "Comparison (buffer ${BUFFER_MIB}MiB, largest payload $(echo "$SIZES" | tr ',' ' ' | awk '{print $NF}')MiB)"
        printf '  %-16s %-9s %-7s %-11s %-7s %s\n' profile injects routes spoofproof nested "big payload"
        printf '  %s\n' "$(printf '%.0s-' {1..70})"
        printf '  %s\n' "${SUMMARY[@]}"
    fi
fi

echo ""
echo "============================================================"
if [[ $FAILURES -eq 0 ]]; then
    echo -e "  ${GREEN}All checks passed${NC}"
else
    echo -e "  ${RED}${FAILURES} check(s) failed${NC}"
    [[ "$RUN_ALL" == "true" ]] && echo "  (expected for profiles that cannot do the job - see the table)"
fi
echo "============================================================"
exit "$FAILURES"
