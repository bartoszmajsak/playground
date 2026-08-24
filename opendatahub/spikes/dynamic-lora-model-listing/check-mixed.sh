#!/usr/bin/env bash
# Can spec-declared and runtime-loaded adapters coexist on one server?
#
# The main check runs against a service with no declared adapters. This one
# declares some, so both kinds are live at once, and asks what separates them:
#
#   1. do declared adapters appear after the controller rolls the workload?
#   2. can adapters still be loaded at runtime while declared ones are present?
#   3. do both kinds serve?
#   4. what survives a restart?
#
# Slow: declaring adapters rewrites the workload, so this waits out two vLLM
# starts. Kept separate from check.sh for that reason.
#
# While declared adapters are present the workload carries --enable-lora twice:
# once from the fixture's own arguments and once injected by the controller.
# vLLM accepts the duplicate, which is what lets this fixture hold both kinds
# without special handling.
#
# -v echoes every request and response.

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
Q="publishers/${NS}/models"
PASSED=0; FAILED=0

section() {
    printf '\n%b%s  %s%b\n' "$BD" "$1" "$2" "$N"
    printf '%b   %s%b\n' "$DIM" "$(printf '%.0s-' {1..66})" "$N"
}
case_result() {  # ok(0/1), action, actual, expected
    if [[ "$1" -eq 0 ]]; then PASSED=$((PASSED+1))
        printf '   %bPASS%b  %-26s %s\n' "$G" "$N" "$2" "$3"
    else FAILED=$((FAILED+1))
        printf '   %bFAIL%b  %-26s %s\n' "$R" "$N" "$2" "$3"
        printf '         %-26s %bexpected: %s%b\n' "" "$R" "$4" "$N"
    fi
}
expect() {  # action, actual, expected
    [[ "$2" == "$3" ]] && case_result 0 "$1" "$2" || case_result 1 "$1" "$2" "$3"
}

ids() {
    if [[ "$V" == 1 ]]; then ./lora.sh list; else ./lora.sh list 2>/dev/null; fi
}
count_named() { ids | grep -c "$1" || true; }

serves() {
    local body code tmp
    body="{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}"
    [[ "$V" == 1 ]] && printf "${C}   > POST %s/v1/chat/completions${N}\n${DIM}     %s${N}\n" "$B" "$body" >&2
    tmp=$(mktemp)
    code=$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 60 -X POST \
        "$B/v1/chat/completions" -H 'Content-Type: application/json' -d "$body")
    [[ "$V" == 1 ]] && printf "${DIM}     < %s${N}\n" "$code" >&2
    rm -f "$tmp"; printf '%s' "$code"
}

pod_name() {
    kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SVC}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null | awk '$2=="True"{print $1; exit}'
}
wait_new_pod() {  # previous pod name
    local p
    for _ in $(seq 120); do
        p="$(pod_name)"
        [[ -n "$p" && "$p" != "$1" ]] && { echo "$p"; return 0; }
        sleep 10
    done
    return 1
}
wait_serving() {
    for _ in $(seq 60); do [[ "$(serves model-dyn 2>/dev/null)" == 200 ]] && return 0; sleep 10; done
    return 1
}

restore() {
    kubectl patch llminferenceservice "$SVC" -n "$NS" --type=json \
        -p '[{"op":"remove","path":"/spec/model/lora"}]' >/dev/null 2>&1 || true
}
trap restore EXIT

# ---------------------------------------------------------------------------
section "1" "declared adapters appear once the workload rolls"
OLD_POD="$(pod_name)"
printf '%b   declaring adapter-1 in the spec (rewrites the workload)%b\n' "$DIM" "$N"
kubectl patch llminferenceservice "$SVC" -n "$NS" --type=merge -p \
    '{"spec":{"model":{"lora":{"adapters":[{"name":"adapter-1","uri":"pvc://dynlora-models/adapter-1"}]}}}}' >/dev/null
NEW_POD="$(wait_new_pod "$OLD_POD")" || { echo "workload never rolled"; exit 1; }
wait_serving || { echo "workload never served"; exit 1; }

# kserve registers each declared adapter under two names: bare and qualified.
expect "declared adapter listed" "$(count_named 'adapter-1$')" "2"

# ---------------------------------------------------------------------------
section "2" "runtime loading still works alongside them"
./lora.sh load adapter-2 >/dev/null 2>&1 || true
expect "runtime adapter listed"  "$(count_named 'adapter-2$')" "1"
expect "declared still listed"   "$(count_named 'adapter-1$')" "2"

# ---------------------------------------------------------------------------
section "3" "both kinds serve"
expect "declared, bare name"      "$(serves adapter-1)"        "200"
expect "declared, qualified name" "$(serves "${Q}/adapter-1")" "200"
expect "runtime-loaded"           "$(serves adapter-2)"        "200"

# ---------------------------------------------------------------------------
section "4" "a restart keeps the declared set and drops the rest"
printf '%b   deleting the pod%b\n' "$DIM" "$N"
kubectl delete pod "$NEW_POD" -n "$NS" --wait=false >/dev/null 2>&1
POST_POD="$(wait_new_pod "$NEW_POD")" || { echo "pod never came back"; exit 1; }
wait_serving || { echo "workload never served"; exit 1; }
expect "declared survives"    "$(count_named 'adapter-1$')" "2"
expect "runtime one does not" "$(count_named 'adapter-2$')" "0"

# ---------------------------------------------------------------------------
printf '\n'
if [[ "$FAILED" -eq 0 ]]; then
    printf '%b%d passed%b -- both kinds coexist; only the declared set survives a restart\n' "$G" "$PASSED" "$N"
else
    printf '%b%d failed%b, %d passed\n' "$R" "$FAILED" "$N" "$PASSED"
fi
printf '%b   The route is derived from the spec, so it never indexes a runtime\n   adapter. Anything loaded at runtime is service-path only, and gone on\n   restart with nothing recording that it existed.%b\n' "$DIM" "$N"
[[ "$FAILED" -eq 0 ]]
