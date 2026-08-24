#!/usr/bin/env bash
# list / load / unload LoRA adapters via the gateway.
#
# unload removes BOTH registered names, not just the one passed.
#
# vLLM keys its adapter table by name and unload takes one lora_name, so two
# names for the same weights are two independent entries. kserve registers each
# spec-declared adapter twice (workload_lora.go:166-167): bare and fully
# qualified. Unloading the bare name returns 200 and leaves
# publishers/{ns}/models/{name} loaded - and that is the name HTTPRoute matches
# on, so gateway traffic is unaffected.
#
# Adapters loaded here register once, so they do not hit this. unload still
# clears both, since the pod may also carry spec-declared adapters.
#
# Usage:  ./lora.sh [-v] list | load NAME | unload NAME
#
# -v (or V=1) echoes each request and response.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"
NS="${NS:-dynamic-lora}"; SVC="${SVC:-svc-dyn}"
B="${B:-http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
    -o jsonpath='{.status.addresses[0].value}')/${NS}/${SVC}}"
Q="publishers/${NS}/models"
[[ "${1:-}" == "-v" ]] && { V=1; shift; }
V="${V:-0}"
DIM='\033[2m'; CY='\033[0;36m'; NC='\033[0m'

# In verbose mode print the request as a runnable curl, then the response.
post() {
    [[ "$V" == 1 ]] && printf "${CY}  > POST %s${NC}\n${DIM}    %s${NC}\n" "$1" "$2" >&2
    local out; out=$(curl -sS --max-time 60 -X POST "$B$1" \
        -H 'Content-Type: application/json' -d "$2")
    [[ "$V" == 1 ]] && printf "${DIM}    < %s${NC}\n" "${out:-(empty)}" >&2
    printf '%s' "$out"
}

case "${1:-}" in
  list)
    [[ "$V" == 1 ]] && printf "${CY}  > GET %s/v1/models${NC}\n" "$B" >&2
    curl -sS --max-time 20 "$B/v1/models" |
      python3 -c 'import json,sys
d=json.load(sys.stdin)
a=[m["id"] for m in d["data"] if m.get("parent")]
print("\n".join(a) if a else "(none)")' ;;
  load)
    [[ -n "${2:-}" ]] || { echo "usage: $0 load NAME" >&2; exit 2; }
    post /v1/load_lora_adapter "{\"lora_name\":\"$2\",\"lora_path\":\"/mnt/lora/$2\"}"; echo ;;
  unload)
    [[ -n "${2:-}" ]] || { echo "usage: $0 unload NAME" >&2; exit 2; }
    # both names, then confirm nothing survived
    post /v1/unload_lora_adapter "{\"lora_name\":\"$2\"}" >/dev/null || true
    post /v1/unload_lora_adapter "{\"lora_name\":\"${Q}/$2\"}" >/dev/null || true
    left=$("$0" list | grep -Fx -e "$2" -e "${Q}/$2" || true)
    [[ -z "$left" ]] && echo "removed $2 (both names)" || { echo "STILL LOADED: $left"; exit 1; } ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 2 ;;
esac
