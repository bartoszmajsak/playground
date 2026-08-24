#!/usr/bin/env bash
# Does /v1/models tell the truth about dynamically loaded adapters?
#
# The route indexes four adapters and never changes. The runtime's adapter set
# moves underneath it. That gives four states per adapter, and the interesting
# question is whether /v1/models reports the runtime's state accurately in all
# of them -- and whether "accurately" survives kserve's dual registration.
#
#                    | loaded in vLLM      | not loaded
#   -----------------+---------------------+----------------------------------
#   indexed in route | serves              | route matches, runtime 404s
#   not indexed      | service-path only   | 404
#
# Nothing here asserts an expectation. It records what /v1/models returns and
# cross-checks it against what actually serves, because a list can be perfectly
# self-consistent and still not describe reality.
#
# Usage:
#   ./probe-listing.sh              # all phases
#   ./probe-listing.sh --phase 3
#
# Environment: NS, SVC, CYCLES

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"
NS="${NS:-dynamic-lora}"
SVC="${SVC:-svc-dyn}"
BASE="${BASE:-model-dyn}"
CYCLES="${CYCLES:-4}"
OUT="${SCRIPT_DIR}/golden/listing.tsv"
CTL="${SCRIPT_DIR}/adapterctl.sh"
QUAL="publishers/${NS}/models"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PHASE=all
[[ "${1:-}" == "--phase" ]] && PHASE="${2:-all}"

pod() {
    kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SVC}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null | awk '$2=="True"{print $1; exit}'
}
P="$(pod)"; [[ -n "$P" ]] || { echo "no ready ${SVC} pod" >&2; exit 1; }

GATEWAY_URL="${GATEWAY_URL:-http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
    -o jsonpath='{.status.addresses[0].value}')}"

# Do not measure on a degraded control plane. istiod crash-looping under route
# churn turns every pool-bound request into a 500 or a timeout, and those read
# exactly like a finding about the adapter being swapped.
istiod_ready() {
    kubectl get pod -n istio-system -l app=istiod \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true
}

ex() { kubectl exec -n "$NS" "$P" -c main -- "$@" 2>/dev/null; }

listed() {  # -> comma-separated adapter ids, or (none)
    ex curl -sf --max-time 15 localhost:8000/v1/models | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("UNREADABLE"); raise SystemExit
a=sorted(m["id"] for m in d.get("data",[]) if m.get("parent"))
print(",".join(a) if a else "(none)")
'
}
count() { local l; l="$(listed)"; [[ "$l" == "(none)" ]] && echo 0 || awk -F, '{print NF}' <<<"$l"; }

# serve directly on the pod: no gateway, no route, no EPP -- ground truth
serves_direct() {
    ex curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
        localhost:8000/v1/chat/completions
}

# through the gateway on the shared endpoint, addressed by the header index
serves_gateway() {
    local tmp code who
    tmp="$(mktemp)"
    code=$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 60 -X POST \
        -H 'Content-Type: application/json' \
        -H "X-Gateway-Model-Name: ${QUAL}/${1}" \
        -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
        "${GATEWAY_URL}/v1/chat/completions" 2>/dev/null || echo 000)
    who=$(python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print("-"); raise SystemExit
if "headers" in d and "path" in d and "model" not in d: print("echo/no-rule")
elif "model" in d: print(d["model"])
else: print(str(d.get("error") or d.get("detail") or "?")[:34])
' < "$tmp" 2>/dev/null || echo "-")
    rm -f "$tmp"
    echo "${code}|${who}"
}

# Same as serves_gateway but the BODY carries the fully qualified name, which is
# what kserve registers as the second entry and what the route matches on.
serves_gateway_qualified() {
    local tmp code who
    tmp="$(mktemp)"
    code=$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 60 -X POST \
        -H 'Content-Type: application/json' \
        -H "X-Gateway-Model-Name: ${QUAL}/${1}" \
        -d "{\"model\":\"${QUAL}/$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
        "${GATEWAY_URL}/v1/chat/completions" 2>/dev/null || echo 000)
    who=$(python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print("-"); raise SystemExit
if "headers" in d and "path" in d and "model" not in d: print("echo/no-rule")
elif "model" in d: print(d["model"])
else: print(str(d.get("error") or d.get("detail") or "?")[:34])
' < "$tmp" 2>/dev/null || echo "-")
    rm -f "$tmp"
    echo "${code}|${who}"
}

hr() { printf "${CYAN}%s${NC}\n" "------------------------------------------------------------------"; }

istiod_ready || echo -e "${YEL}warning: istiod not ready; gateway columns will be unreliable${NC}"

: > "$OUT"
{
  echo "# Does /v1/models report the real state of dynamically loaded adapters?"
  echo "#"
  echo "# Route: dynlora-route, static, indexes ${BASE} + adapter-1..4 and never changes."
  echo "# Runtime: nothing preloaded; every adapter arrives via an admin call."
  echo "#"
  echo "# gateway ${GATEWAY_URL}  ns ${NS}  pod ${P}"
} >> "$OUT"

# ===========================================================================
# Phase 1 -- the list tracks every admin call
# ===========================================================================
if [[ "$PHASE" == all || "$PHASE" == 1 ]]; then
echo -e "${BOLD}Phase 1: does the list follow every load and unload?${NC}"
hr
{ echo ""; echo "# --- phase 1: list vs admin calls (adapterctl loads BOTH names) ---"
  printf 'operation\tentries\tadapters listed\n'; } >> "$OUT"

step() {  # label
    local n l; n="$(count)"; l="$(listed)"
    printf '%s\t%s\t%s\n' "$1" "$n" "$l" >> "$OUT"
    printf '  %-26s %2s  %s\n' "$1" "$n" "$l"
}

step "start"
for a in adapter-1 adapter-2 adapter-3 adapter-4; do
    "$CTL" load "$a" >/dev/null 2>&1 || true
    step "load ${a}"
done
for a in adapter-2 adapter-4; do
    "$CTL" unload "$a" >/dev/null 2>&1 || true
    step "unload ${a}"
done
"$CTL" load adapter-2 >/dev/null 2>&1 || true; step "re-load adapter-2"
fi

# ===========================================================================
# Phase 2 -- the list vs what actually serves
# ===========================================================================
if [[ "$PHASE" == all || "$PHASE" == 2 ]]; then
echo ""
echo -e "${BOLD}Phase 2: does the list agree with reality?${NC}"
hr
{ echo ""; echo "# --- phase 2: listed? vs serves? for every indexed adapter ---"
  echo "# direct = on the pod, no gateway. gateway = shared endpoint via the header index."
  printf 'adapter\tlisted\tdirect\tgateway\tverdict\n'; } >> "$OUT"

for a in adapter-1 adapter-2 adapter-3 adapter-4; do
    l=$(listed | tr ',' '\n' | grep -Fxq "$a" && echo yes || echo no)
    d=$(serves_direct "$a")
    g=$(serves_gateway "$a")
    gc="${g%%|*}"
    if   [[ "$l" == yes && "$d" == 200 ]]; then v="agrees"
    elif [[ "$l" == no  && "$d" == 404 ]]; then v="agrees"
    else v="DISAGREES"; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$a" "$l" "$d" "$g" "$v" >> "$OUT"
    printf '  %-12s listed=%-4s direct=%-5s gateway=%-24s %s\n' "$a" "$l" "$d" "$g" "$v"
done
fi

# ===========================================================================
# Phase 3 -- the dual-registration trap, and adapterctl closing it
# ===========================================================================
if [[ "$PHASE" == all || "$PHASE" == 3 ]]; then
echo ""
echo -e "${BOLD}Phase 3: half-unload, and the fix${NC}"
hr
{ echo ""; echo "# --- phase 3: unloading ONE name of a dual-registered adapter ---"
  echo "# vLLM keys its adapter table by name, so two names for one set of weights"
  echo "# are two independent entries. Unload takes a single lora_name."
  printf 'step\tbare listed\tqualified listed\tbare serves direct\tQUALIFIED via gateway\n'; } >> "$OUT"

pair_state() {  # label
    local ids b q sb sg
    ids="$(ex curl -sf --max-time 15 localhost:8000/v1/models | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("\n".join(m["id"] for m in d.get("data",[])))
')"
    b=$(grep -Fxq "adapter-1" <<<"$ids" && echo yes || echo no)
    q=$(grep -Fxq "${QUAL}/adapter-1" <<<"$ids" && echo yes || echo no)
    sb=$(serves_direct adapter-1)
    # Probe the gateway with the QUALIFIED name in the body, not the bare one.
    # The bare name is the one a naive unload removes; the qualified name is the
    # one that survives AND the only one the route indexes, so sending the bare
    # name here would report a 404 and hide the trap entirely.
    sg=$(serves_gateway_qualified adapter-1)
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$b" "$q" "$sb" "$sg" >> "$OUT"
    printf '  %-28s bare-listed=%-4s qual-listed=%-4s bare-serves=%-5s gateway=%s\n' \
        "$1" "$b" "$q" "$sb" "$sg"
}

"$CTL" load adapter-1 >/dev/null 2>&1 || true
pair_state "both names registered"

echo -e "  ${YEL}naive unload: one name only${NC}"
ex curl -sS -o /dev/null -w '' --max-time 60 -X POST -H 'Content-Type: application/json' \
    -d '{"lora_name":"adapter-1"}' localhost:8000/v1/unload_lora_adapter
pair_state "after naive unload"

echo -e "  ${CYAN}adapterctl unload: both names${NC}"
"$CTL" unload adapter-1 >/dev/null 2>&1 || true
pair_state "after adapterctl unload"

"$CTL" load adapter-1 >/dev/null 2>&1 || true
pair_state "restored"
fi

echo ""
istiod_ready || echo -e "${YEL}warning: istiod went unready during the run${NC}"
echo -e "${GREEN}recorded${NC} ${OUT}"
