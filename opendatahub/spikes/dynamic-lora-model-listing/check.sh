#!/usr/bin/env bash
# Checks /v1/models against dynamically loaded adapters.
#
#   1. does the listing follow every load and unload?
#   2. does it agree with what the server actually serves?
#
# Both matter: a listing can be internally consistent and still not match what
# an inference request will do.
#
# Exits non-zero if the two disagree.
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

listed() { ./lora.sh list 2>/dev/null | paste -sd, - ; }

# Sends a real inference request. In verbose mode prints the payload and the
# body, since the status code alone does not say which adapter answered.
serves() {
    local body tmp code
    body="{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}"
    # stderr, not stdout: this runs inside $( ) and would otherwise be captured
    [[ "$V" == 1 ]] && printf "${C}  > POST %s/v1/chat/completions${N}\n${DIM}    %s${N}\n" "$B" "$body" >&2
    tmp=$(mktemp)
    code=$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 60 -X POST \
        "$B/v1/chat/completions" -H 'Content-Type: application/json' -d "$body")
    if [[ "$V" == 1 ]]; then
        printf "${DIM}    < %s  %s${N}\n" "$code" >&2 \
            "$(python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print(raw[:80]); raise SystemExit
if "model" in d: print("served " + d["model"])
else: print(str(d.get("error") or d.get("detail") or raw)[:80])' < "$tmp")"
    fi
    rm -f "$tmp"
    printf '%s' "$code"
}

echo -e "${BD}1. does the listing follow every call?${N}"

# Each step declares the set it expects, sorted, and compares. Printing the
# listing without an expectation shows a trace, not a check.
step() {  # label, expected (comma-separated, sorted)
    local got
    got=$(./lora.sh list 2>/dev/null | sort | paste -sd, -)
    [[ "$got" == "(none)" || -z "$got" ]] && got="-"
    if [[ "$got" == "$2" ]]; then
        printf '  %-22s %-34s %bok%b\n' "$1" "$got" "$G" "$N"
    else
        printf '  %-22s %-34s %bexpected %s%b\n' "$1" "$got" "$R" "$2" "$N"
        fail=1
    fi
}

fail=0
for a in adapter-1 adapter-2 adapter-3 adapter-4; do ./lora.sh unload "$a" >/dev/null 2>&1 || true; done
[[ "$V" == 1 ]] && echo -e "${DIM}  (reset: removed any adapters left by a previous run)${N}"
step "start (reset)"     "-"

./lora.sh load adapter-1 >/dev/null; step "load adapter-1"    "adapter-1"
./lora.sh load adapter-2 >/dev/null; step "load adapter-2"    "adapter-1,adapter-2"
./lora.sh load adapter-3 >/dev/null; step "load adapter-3"    "adapter-1,adapter-2,adapter-3"
./lora.sh unload adapter-2 >/dev/null; step "unload adapter-2"  "adapter-1,adapter-3"
./lora.sh load adapter-2 >/dev/null; step "re-load adapter-2" "adapter-1,adapter-2,adapter-3"

# Verbose shows the second unload returning 404 for runtime-loaded adapters.
# That is correct: they register under one name. The second call exists for
# spec-declared adapters, which register under two.
[[ "$V" == 1 ]] && echo -e "${DIM}  (unload sends two requests: bare and fully qualified;${N}"
[[ "$V" == 1 ]] && echo -e "${DIM}   a 404 on the second is expected for runtime-loaded adapters)${N}"

echo
echo -e "${BD}2. does the list agree with what serves?${N}"
now="$(listed)"
for a in adapter-1 adapter-2 adapter-3 adapter-4; do
    in_list=$(grep -q "\b${a}\b" <<<"$now" && echo yes || echo no)
    code=$(serves "$a")
    if   [[ "$in_list" == yes && "$code" == 200 ]]; then v="${G}agrees${N}"
    elif [[ "$in_list" == no  && "$code" == 404 ]]; then v="${G}agrees${N}"
    else v="${R}DISAGREES${N}"; fail=1; fi
    printf '  %-12s listed=%-4s serves=%-4s %b\n' "$a" "$in_list" "$code" "$v"
done

echo
[[ "$fail" -eq 0 ]] && echo -e "${G}the listing matches the runtime in every state tested${N}" \
                    || echo -e "${R}the listing does not match the runtime${N}"
echo -e "${C}note${N}: adapter-4 is indexed by the route but never loaded -- the gateway"
echo "      matches and forwards, the runtime 404s."
exit "$fail"
