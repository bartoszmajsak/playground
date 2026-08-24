#!/usr/bin/env bash
# Checks /v1/models against dynamically loaded adapters.
#
#   1. does the listing follow every load and removal?
#   2. does it agree with what the server actually serves?
#
# Both matter: a listing can be internally consistent and still not match what
# an inference request will do.
#
# Exits non-zero if any case fails.
#
# -v echoes every request and response, so the summary can be checked against
# the wire rather than taken on trust.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"
NS="${NS:-dynamic-lora}"; SVC="${SVC:-svc-dyn}"
B="${B:-http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
    -o jsonpath='{.status.addresses[0].value}')/${NS}/${SVC}}"
export B
[[ "${1:-}" == "-v" ]] && { V=1; shift; }
V="${V:-0}"; export V
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; BD='\033[1m'; N='\033[0m'; DIM='\033[2m'

PASSED=0; FAILED=0

section() {  # number, title
    printf '\n%b%s  %s%b\n' "$BD" "$1" "$2" "$N"
    printf '%b   %s%b\n' "$DIM" "$(printf '%.0s-' {1..66})" "$N"
}

# One verdict formatter for both checks, so a case reads the same either way.
case_result() {  # ok(0/1), action, actual, expected
    if [[ "$1" -eq 0 ]]; then
        PASSED=$((PASSED+1))
        printf '   %bPASS%b  %-22s %s\n' "$G" "$N" "$2" "$3"
    else
        FAILED=$((FAILED+1))
        printf '   %bFAIL%b  %-22s %s\n' "$R" "$N" "$2" "$3"
        printf '         %-22s %bexpected: %s%b\n' "" "$R" "$4" "$N"
    fi
}

subtotal() {
    printf '%b   %s%b\n' "$DIM" "$(printf '%.0s-' {1..66})" "$N"
    printf '   %d passed' "$1"
    [[ "$2" -gt 0 ]] && printf ', %b%d failed%b' "$R" "$2" "$N"
    printf '\n'
}

# The read that every assertion in check 1 is made against, so verbose must
# show it: discarding stderr here hid the request that produces the value.
#
# paste -d takes a delimiter LIST and cycles through its characters, so
# -d', ' alternates comma and space between fields. Join explicitly.
listed() {
    local raw
    if [[ "$V" == 1 ]]; then raw=$(./lora.sh list)
    else                     raw=$(./lora.sh list 2>/dev/null); fi
    sort <<<"$raw" | paste -sd, - | sed 's/,/, /g'
}

# Sends a real inference request. In verbose mode prints the payload and body:
# a status code alone does not say which adapter answered.
serves() {
    local body tmp code
    body="{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}"
    # stderr, not stdout: this runs inside $( ) and would otherwise be captured
    [[ "$V" == 1 ]] && printf "${C}   > POST %s/v1/chat/completions${N}\n${DIM}     %s${N}\n" "$B" "$body" >&2
    tmp=$(mktemp)
    code=$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 60 -X POST \
        "$B/v1/chat/completions" -H 'Content-Type: application/json' -d "$body")
    [[ "$V" == 1 ]] && printf "${DIM}     < %s  %s${N}\n" "$code" "$(python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print(raw[:70]); raise SystemExit
if "model" in d: print("served " + d["model"])
else: print(str(d.get("error") or d.get("detail") or raw)[:70])' < "$tmp")" >&2
    rm -f "$tmp"
    printf '%s' "$code"
}

# ---------------------------------------------------------------------------
section "1" "the listing follows every load and removal"
p1=0; f1=0

step() {  # action, expected
    local got; got=$(listed)
    [[ -z "$got" || "$got" == "(none)" ]] && got="-"
    if [[ "$got" == "$2" ]]; then case_result 0 "$1" "$got"; p1=$((p1+1))
    else                          case_result 1 "$1" "$got" "$2"; f1=$((f1+1)); fi
}

for a in adapter-1 adapter-2 adapter-3 adapter-4; do ./lora.sh unload "$a" >/dev/null 2>&1 || true; done
[[ "$V" == 1 ]] && printf "%b   (reset: removed adapters left by a previous run)%b\n" "$DIM" "$N"
step "reset"              "-"
./lora.sh load   adapter-1 >/dev/null; step "load adapter-1"   "adapter-1"
./lora.sh load   adapter-2 >/dev/null; step "load adapter-2"   "adapter-1, adapter-2"
./lora.sh load   adapter-3 >/dev/null; step "load adapter-3"   "adapter-1, adapter-2, adapter-3"
./lora.sh unload adapter-2 >/dev/null; step "unload adapter-2" "adapter-1, adapter-3"
./lora.sh load   adapter-2 >/dev/null; step "reload adapter-2" "adapter-1, adapter-2, adapter-3"
subtotal "$p1" "$f1"

# Verbose shows the second unload returning 404 for runtime-loaded adapters.
# Correct: they register under one name. The second call covers spec-declared
# adapters, which register under two.
[[ "$V" == 1 ]] && printf "%b   (unload sends two requests, bare and qualified; a 404 on the%b\n%b    second is expected for runtime-loaded adapters)%b\n" "$DIM" "$N" "$DIM" "$N"

# ---------------------------------------------------------------------------
section "2" "the listing agrees with what the server serves"
p2=0; f2=0
now="$(listed)"

for a in adapter-1 adapter-2 adapter-3 adapter-4; do
    in_list=$(grep -q "\b${a}\b" <<<"$now" && echo listed || echo "not listed")
    code=$(serves "$a")
    if   [[ "$in_list" == listed      && "$code" == 200 ]]; then want=""
    elif [[ "$in_list" == "not listed" && "$code" == 404 ]]; then want=""
    else want="listed and 200, or absent and 404"; fi

    if [[ -z "$want" ]]; then case_result 0 "$a" "${in_list}, serves ${code}"; p2=$((p2+1))
    else                      case_result 1 "$a" "${in_list}, serves ${code}" "$want"; f2=$((f2+1)); fi
done
subtotal "$p2" "$f2"

# ---------------------------------------------------------------------------
printf '\n'
if [[ "$FAILED" -eq 0 ]]; then
    printf '%b%d passed%b -- the listing matches the runtime in every state tested\n' "$G" "$PASSED" "$N"
else
    printf '%b%d failed%b, %d passed\n' "$R" "$FAILED" "$N" "$PASSED"
fi
printf '%b   adapter-4 is indexed by the route but never loaded: the route matches\n   and forwards, the runtime 404s.%b\n' "$DIM" "$N"
[[ "$FAILED" -eq 0 ]]
