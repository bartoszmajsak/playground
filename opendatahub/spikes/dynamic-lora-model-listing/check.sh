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

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"
NS="${NS:-dynamic-lora}"; SVC="${SVC:-svc-dyn}"
B="${B:-http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
    -o jsonpath='{.status.addresses[0].value}')/${NS}/${SVC}}"
export B
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; BD='\033[1m'; N='\033[0m'

listed() { ./lora.sh list | paste -sd, - ; }
serves() {
    curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
        "$B/v1/chat/completions" -H 'Content-Type: application/json' \
        -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}"
}

echo -e "${BD}1. does the list follow every call?${N}"
for a in adapter-1 adapter-2 adapter-3 adapter-4; do ./lora.sh unload "$a" >/dev/null 2>&1 || true; done
printf '  %-22s %s\n' "start (reset)" "$(listed)"
for a in adapter-1 adapter-2 adapter-3; do
    ./lora.sh load "$a" >/dev/null; printf '  %-22s %s\n' "load ${a}" "$(listed)"
done
./lora.sh unload adapter-2 >/dev/null; printf '  %-22s %s\n' "unload adapter-2" "$(listed)"
./lora.sh load adapter-2 >/dev/null;   printf '  %-22s %s\n' "re-load adapter-2" "$(listed)"

echo
echo -e "${BD}2. does the list agree with what serves?${N}"
now="$(listed)"
fail=0
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
