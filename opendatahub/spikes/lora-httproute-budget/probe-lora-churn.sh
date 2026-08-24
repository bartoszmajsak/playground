#!/usr/bin/env bash
# What happens when adapters come and go WHILE traffic is flowing?
#
# probe-model-list.sh does load/unload as isolated steps with nothing else in
# flight, which answers "is it possible" and nothing about "is it safe". This
# asks the operational question: if adapters are loaded and unloaded at runtime,
# what do concurrent callers see, and does the HTTPRoute index have to change
# at all?
#
# That last part matters to the budget. Runtime loading decouples the RUNTIME's
# adapter set from the ROUTE's, so the tempting conclusion is that the route
# ceiling stops mattering: register a few names, swap the weights underneath.
# The measurement below is what that actually buys, and where it stops.
#
# THREE different limits are in play and they are easy to conflate:
#
#   registered   how many --lora-modules entries vLLM holds       (unbounded-ish)
#   indexed      how many names the HTTPRoute matches on          (the 7 ceiling)
#   concurrent   how many adapters vLLM keeps resident at once    (--max-loras)
#
# kserve only emits --max-loras when LoRASpec.MaxAdapters is explicitly set
# (#280), so vLLM's own default applies -- and that default is 1. Measured on
# the fixture: `LoRAConfig.max_loras` default = 1, no --max-loras in the pod's
# argv. So the fixture serves N registered adapters through ONE resident slot.
#
# Usage:
#   ./probe-lora-churn.sh                 # all phases
#   ./probe-lora-churn.sh --phase 2       # just one
#
# Environment:
#   REQS      requests per traffic burst (default 30)
#   CYCLES    load/unload cycles under traffic (default 5)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"
NS="${NS:-lora-budget}"
SVC="${SVC:-svc-a}"
REQS="${REQS:-30}"
CYCLES="${CYCLES:-5}"
OUT="${SCRIPT_DIR}/golden/lora-churn.tsv"
QUAL="publishers/${NS}/models"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PHASE="${2:-all}"
[[ "${1:-}" == "--phase" ]] || PHASE=all

GATEWAY_URL="${GATEWAY_URL:-http://$(kubectl get gateway kserve-ingress-gateway -n "kserve" \
    -o jsonpath='{.status.addresses[0].value}')}"

pod() {
    kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SVC}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null | awk '$2=="True"{print $1; exit}'
}
P="$(pod)"
[[ -n "$P" ]] || { echo "no ready ${SVC} pod" >&2; exit 1; }

# Refuse to measure on a broken control plane. istiod crash-looping under route
# churn (#285) turns every pool-bound request into a 500 or a timeout, and those
# read exactly like a finding about the adapter that was being swapped.
healthy() {
    kubectl get pod -n istio-system -l app=istiod \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true
}
canary() {
    curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X POST \
        -H 'Content-Type: application/json' \
        -d '{"model":"adapter-a1","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
        "${GATEWAY_URL}/${NS}/${SVC}/v1/chat/completions" 2>/dev/null
}
preflight() {
    healthy || { echo -e "${RED}istiod is not ready -- restart it before measuring (see DEV.md)${NC}"; exit 1; }
    local c; c="$(canary)"
    [[ "$c" == "200" ]] || { echo -e "${RED}pool path returns ${c}, not 200 -- not measuring${NC}"; exit 1; }
}

lora() {  # verb, name, [path]
    local body
    if [[ "$1" == "load" ]]; then
        body="{\"lora_name\":\"$2\",\"lora_path\":\"${3:-/mnt/lora/adapter-a1}\"}"
    else
        body="{\"lora_name\":\"$2\"}"
    fi
    kubectl exec -n "$NS" "$P" -c main -- curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 30 -X POST -H 'Content-Type: application/json' -d "$body" \
        "localhost:8000/v1/${1}_lora_adapter" 2>/dev/null
}

# One request, reporting who answered rather than just a status code.
ask() {  # model, path, [header]
    local model="$1" path="$2" hdr="${3:-}" tmp code
    tmp="$(mktemp)"
    local args=(-sS --max-time 40 -o "$tmp" -w '%{http_code}' -X POST
                -H 'Content-Type: application/json'
                -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}")
    [[ -n "$hdr" ]] && args+=(-H "X-Gateway-Model-Name: ${hdr}")
    code=$(curl "${args[@]}" "${GATEWAY_URL}${path}" 2>/dev/null || echo 000)
    local who
    who=$(python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print("-"); raise SystemExit
if "headers" in d and "path" in d and "model" not in d: print("echo")
elif "model" in d: print(d["model"])
else: print(str(d.get("error") or d.get("detail") or "?")[:40])
' < "$tmp" 2>/dev/null || echo "-")
    rm -f "$tmp"
    echo "${code}|${who}"
}

# A deliberately slower request, so one call spans a meaningful slice of the
# unload window instead of finishing before it opens.
ask_slow() {  # model, path
    local tmp code
    tmp="$(mktemp)"
    code=$(curl -sS --max-time 60 -o "$tmp" -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":64}" \
        "${GATEWAY_URL}$2" 2>/dev/null || echo 000)
    rm -f "$tmp"
    echo "$code"
}

hr() { printf "${CYAN}%s${NC}\n" "-------------------------------------------------------------------"; }

preflight
: > "$OUT"
{
  echo "# Adapters coming and going WHILE traffic flows."
  echo "#"
  echo "# Three limits, easy to conflate:"
  echo "#   registered  --lora-modules entries vLLM holds"
  echo "#   indexed     names the HTTPRoute matches on   <- the 7 ceiling"
  echo "#   concurrent  adapters resident at once        <- --max-loras, DEFAULT 1"
  echo "#"
  echo "# kserve emits --max-loras only when MaxAdapters is set (#280), so the"
  echo "# fixture runs on vLLM's default of 1: measured LoRAConfig.max_loras=1 and"
  echo "# no --max-loras in the pod argv."
  echo "#"
  echo "# gateway ${GATEWAY_URL}  pod ${P}  reqs/burst ${REQS}  cycles ${CYCLES}"
} >> "$OUT"

# ===========================================================================
# Phase 1 -- concurrency against a single resident slot
# ===========================================================================
if [[ "$PHASE" == "all" || "$PHASE" == 1 ]]; then
echo -e "${BOLD}Phase 1: concurrent requests to different adapters, max_loras=1${NC}"
hr
{ echo ""; echo "# --- phase 1: concurrency vs one resident slot ---"
  printf 'scenario\trequests\tok\tnon-200\twall-seconds\n'; } >> "$OUT"

burst() {  # label, model-a, model-b
    local label="$1" m1="$2" m2="$3" ok=0 bad=0 t0 t1
    t0=$(date +%s)
    local pids=() results
    results="$(mktemp -d)"
    for i in $(seq "$REQS"); do
        local m; [[ $((i % 2)) -eq 0 ]] && m="$m2" || m="$m1"
        ( ask "$m" "/${NS}/${SVC}/v1/chat/completions" > "${results}/${i}" ) &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
    t1=$(date +%s)
    for f in "${results}"/*; do
        [[ "$(cut -d'|' -f1 < "$f")" == "200" ]] && ok=$((ok+1)) || bad=$((bad+1))
    done
    rm -rf "$results"
    printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$REQS" "$ok" "$bad" "$((t1-t0))" >> "$OUT"
    printf '  %-34s %3s/%-3s ok   %ss\n' "$label" "$ok" "$REQS" "$((t1-t0))"
}

burst "same adapter throughout"      "adapter-a1" "adapter-a1"
burst "alternating two adapters"     "adapter-a1" "adapter-a2"
burst "alternating base and adapter" "model-a"    "adapter-a1"
fi

# ===========================================================================
# Phase 2 -- unload and reload the adapter traffic is using
# ===========================================================================
if [[ "$PHASE" == "all" || "$PHASE" == 2 ]]; then
echo ""
echo -e "${BOLD}Phase 2: unload/reload adapter-a1 with traffic in flight${NC}"
hr
{ echo ""; echo "# --- phase 2: churn the adapter that traffic is using ---"
  echo "# Traffic runs continuously against adapter-a1 on the service-scoped path"
  echo "# while the adapter is unloaded and reloaded underneath it."
  echo "# in-window = requests that STARTED while adapter-a1 was unloaded."
  echo "# Without that column the phase reports a clean run while measuring nothing."
  printf 'cycle\tunload-http\treload-http\ttotal\tok\tnotfound\tother\tin-window\twindow-404\twindow-200\n'; } >> "$OUT"

# The first version of this fired REQS requests, slept 1s, then unloaded -- and
# reported a clean 0/404 five cycles running. It was measuring nothing: phase 1
# had already shown 12 requests complete in under a second, so every request was
# finished before the unload landed. The window has to be forced open.
#
# So: traffic runs CONTINUOUSLY for the whole cycle, each request asks for more
# tokens so it takes real time, and every result is stamped with when it started
# relative to the unload. A 404 is only meaningful if a request was in flight
# while the adapter was gone.
for c in $(seq "$CYCLES"); do
    TR="$(mktemp -d)"
    STOP="${TR}/.stop"

    # continuous traffic: keep firing until told to stop
    for w in 1 2 3; do
        (
            local_i=0
            while [[ ! -f "$STOP" ]]; do
                local_i=$((local_i+1))
                t=$(($(date +%s%N)/1000000))
                r="$(ask_slow "adapter-a1" "/${NS}/${SVC}/v1/chat/completions")"
                echo "${t}|${r}" > "${TR}/w${w}-${local_i}"
            done
        ) &
    done

    sleep 2
    T_UNLOAD=$(($(date +%s%N)/1000000))
    U=$(lora unload adapter-a1)
    sleep 3
    T_RELOAD=$(($(date +%s%N)/1000000))
    L=$(lora load adapter-a1 /mnt/lora/adapter-a1)
    sleep 2
    touch "$STOP"
    wait 2>/dev/null || true

    ok=0; nf=0; other=0; win_ok=0; win_nf=0; win_other=0
    for f in "${TR}"/w*; do
        [[ -f "$f" ]] || continue
        line="$(cat "$f")"
        t="${line%%|*}"; rest="${line#*|}"
        code="${rest%%|*}"
        case "$code" in
            200) ok=$((ok+1)) ;;
            404) nf=$((nf+1)) ;;
            *)   other=$((other+1)) ;;
        esac
        # started while the adapter was unloaded
        if [[ "$t" -ge "$T_UNLOAD" && "$t" -lt "$T_RELOAD" ]]; then
            case "$code" in
                200) win_ok=$((win_ok+1)) ;;
                404) win_nf=$((win_nf+1)) ;;
                *)   win_other=$((win_other+1)) ;;
            esac
        fi
    done
    rm -rf "$TR"
    total=$((ok+nf+other)); wtotal=$((win_ok+win_nf+win_other))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$c" "$U" "$L" "$total" "$ok" "$nf" "$other" "$wtotal" "$win_nf" "$win_ok" >> "$OUT"
    printf '  cycle %-3s unload=%-4s reload=%-4s  total %3s (%3s ok %3s 404)   in-window %3s (%3s 404 %3s ok)\n' \
        "$c" "$U" "$L" "$total" "$ok" "$nf" "$wtotal" "$win_nf" "$win_ok"
done
fi

# ===========================================================================
# Phase 3 -- an adapter the route has never heard of
# ===========================================================================
if [[ "$PHASE" == "all" || "$PHASE" == 3 ]]; then
echo ""
echo -e "${BOLD}Phase 3: does a runtime-loaded adapter need a route entry?${NC}"
hr
{ echo ""; echo "# --- phase 3: runtime-only adapter, no route entry, no restart ---"
  printf 'step\tservice-path\tshared-endpoint\tnote\n'; } >> "$OUT"

record() {  # label, note
    local sp se
    sp="$(ask "ghost-dyn" "/${NS}/${SVC}/v1/chat/completions")"
    se="$(ask "ghost-dyn" "/v1/chat/completions" "${QUAL}/ghost-dyn")"
    printf '%s\t%s\t%s\t%s\n' "$1" "$sp" "$se" "$2" >> "$OUT"
    printf '  %-22s service=%-22s shared=%-22s %s\n' "$1" "$sp" "$se" "$2"
}

record "before load" "not registered anywhere"
echo -e "  ${CYAN}loading ghost-dyn at runtime (no restart, no route change)${NC}"
lora load ghost-dyn /mnt/lora/adapter-a2 >/dev/null
record "after load" "runtime yes, route no"
echo -e "  ${CYAN}unloading${NC}"
lora unload ghost-dyn >/dev/null
record "after unload" "back to neither"
fi

echo ""
healthy || echo -e "${YEL}warning: istiod is no longer ready -- re-check before trusting this run${NC}"
echo -e "${GREEN}recorded${NC} ${OUT}"
