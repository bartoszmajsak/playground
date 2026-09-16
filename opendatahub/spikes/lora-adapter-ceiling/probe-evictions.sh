#!/usr/bin/env bash
# Tier 2: show the eviction, do not infer it.
#
# Adapter size makes latency useless as a signal here - these are rank-8 no-ops
# measured in kilobytes, and a 1.2 MB adapter already had no visible load time
# (lora-fleet Q5). So this counts events instead of timing them, which works at
# any adapter size:
#
#   AdapterLRUCache._on_remove  -> "Removing adapter int id: N"   (model_manager.py:58)
#   LoRAModelManager.add_adapter -> "Adding lora. Model id: N"    (model_manager.py:811,878)
#
# Both are DEBUG, so the services set VLLM_LOGGING_LEVEL=DEBUG. A second add for
# an id that was already added can only follow an eviction of that id, so the
# pair is the proof.
#
# Two arms differing in one variable:
#   ceiling-explicit  8 registrations, maxCpuAdapters 4  -> must evict
#   ceiling-headroom  8 registrations, maxCpuAdapters 8  -> must not
#
# Environment:
#   NS      namespace (default: lora-ceiling)
#   PASSES  round-robin passes over the four adapters (default: 3)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-lora-ceiling}"
PASSES="${PASSES:-3}"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${YELLOW}INFO${NC}: $*"; }
ok()     { echo -e "${GREEN}  OK${NC}: $*"; }
fail()   { echo -e "${RED}FAIL${NC}: $*"; FAILURES=$((FAILURES+1)); }
header() { echo -e "\n${BOLD}$*${NC}"; }
FAILURES=0

pod_of() { kubectl get pods -n "$NS" \
    -l "app.kubernetes.io/name=${1},kserve.io/component=workload" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true; }

# Resolved budget, straight from vLLM's own start-up banner. This is what
# settles whether the no-flags case runs on a one-slot cache.
resolved_budget() {
    kubectl logs -n "$NS" "$1" -c main 2>/dev/null \
        | grep -oE "max_cpu_loras=[0-9]+|'max_cpu_loras': [0-9]+" | tail -1
}

# Traffic must span both public names of each adapter, which is the realistic
# case: KServe advertises both, so some clients use the bare name and some the
# publisher-qualified one. They are two cache entries for identical weights, so
# they evict each other whenever the budget cannot hold both.
#
# Requesting only the bare names would prove nothing: four distinct names fit a
# four-slot cache and never evict, while the four qualified registrations sit
# dead until something asks for them.
drive_traffic() {
    local pod="$1" prefix="$2" pass i name
    for pass in $(seq 1 "$PASSES"); do
        for i in 1 2 3 4; do
            for name in "${prefix}${i}" "publishers/${NS}/models/${prefix}${i}"; do
                kubectl exec -n "$NS" "$pod" -c main -- \
                    curl -s --max-time 30 -o /dev/null \
                    -X POST localhost:8000/v1/completions \
                    -H 'Content-Type: application/json' \
                    -d "{\"model\":\"${name}\",\"prompt\":\"hi\",\"max_tokens\":4}" || true
            done
        done
    done
}

# Only adds AFTER traffic starts are cache misses. init_static_loras legitimately
# adds every static module at boot, so a boot-time add proves nothing.
#
# And only "Adding lora" counts. Both LoRA caches are AdapterLRUCache and both log
# the same "Removing adapter int id" line from _on_remove, but they mean different
# things: _registered_adapters (capacity max_cpu_loras) evicting forces a disk
# reload, while _active_adapters (capacity max_loras) evicting is ordinary batch
# rotation. Only the former forces a re-add, so the add is the unambiguous signal.
adds_since() {
    kubectl logs -n "$NS" "$1" -c main --since-time="$2" 2>/dev/null \
        | grep -c "Adding lora" || true
}

run_arm() {
    local svc="$1" prefix="$2" expect="$3" pod mark adds
    pod="$(pod_of "$svc")"
    header "${svc} (expect: ${expect})"
    if [[ -z "$pod" ]]; then fail "no pod for ${svc}"; return; fi

    local budget; budget="$(resolved_budget "$pod")"
    echo "    pod:             ${pod}"
    echo "    resolved budget: ${budget:-not found in log}"
    echo "    registrations:   $(kubectl exec -n "$NS" "$pod" -c main -- \
        curl -s --max-time 10 localhost:8000/v1/models 2>/dev/null \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))' 2>/dev/null || echo '?')"

    mark="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sleep 1
    drive_traffic "$pod" "$prefix"
    sleep 2
    adds="$(adds_since "$pod" "$mark")"
    echo "    reloads during traffic: ${adds}"

    if [[ "$expect" == "evicts" ]]; then
        if [[ "$adds" -gt 0 ]]; then
            ok "${adds} request-path reloads: the registrations do not fit the budget"
        else
            fail "expected request-path reloads, saw none"
        fi
    else
        if [[ "$adds" -eq 0 ]]; then
            ok "no request-path reloads: the same registrations fit"
        else
            fail "expected no reloads, saw ${adds}"
        fi
    fi
}

header "Waiting for workload pods"
for svc in ceiling-explicit ceiling-headroom; do
    kubectl wait --for=condition=Ready pod -n "$NS" \
        -l "app.kubernetes.io/name=${svc},kserve.io/component=workload" \
        --timeout=600s >/dev/null 2>&1 || true
done
ok "workload pods settled"

run_arm ceiling-explicit ceil-b evicts
run_arm ceiling-headroom ceil-c "no evictions"

header "Summary"
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}Both arms behaved as predicted${NC}"
    echo "The only difference between them is the budget against an identical"
    echo "eight registrations, so the duplication is what causes the thrash."
else
    echo -e "${RED}${FAILURES} arm(s) did not${NC}"
fi
exit $FAILURES
