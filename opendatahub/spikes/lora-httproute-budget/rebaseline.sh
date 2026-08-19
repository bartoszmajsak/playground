#!/usr/bin/env bash
# Re-record every shape's behaviour table against the current probes.tsv.
#
# Adding a probe invalidates every golden file at once -- the tables are only
# comparable if every shape answered the same questions. This applies each
# shape's route in turn and re-records it, so the whole set moves together.
#
# Usage:
#   ./rebaseline.sh                    # every shape
#   ./rebaseline.sh prefix collapse    # just these

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"
NS="${NS:-lora-budget}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SHAPES=("$@")
[[ ${#SHAPES[@]} -eq 0 ]] && SHAPES=(current split split-noslash prefix split-prefix nested collapse collapse-dedup)

# "current" is the captured route with only its backendRefs swapped; every other
# shape is derived from that same capture by make-shape.py, so the single
# difference between any two tables is the transformation under test.
manifest_for() {
    if [[ "$1" == "current" ]]; then
        ./swap-backends.sh golden/route-current.yaml > "manifests/route-current-swapped.yaml"
        echo "manifests/route-current-swapped.yaml"
    else
        ./make-shape.py "$1" > "manifests/route-$1.yaml" 2>/dev/null
        echo "manifests/route-$1.yaml"
    fi
}

if [[ "$(kubectl get deploy llmisvc-controller-manager -n kserve \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)" != "0" ]]; then
    echo "scaling the llmisvc controller down so it stops recreating the originals"
    kubectl scale deploy/llmisvc-controller-manager -n kserve --replicas=0
    kubectl rollout status deploy/llmisvc-controller-manager -n kserve --timeout=120s >/dev/null 2>&1 || true
fi

# Scaling the controller down does not remove routes it already created. Leaving
# them live means two route sets compete for the same matches and the recorded
# backend depends on which one Istio programmed last -- every table becomes
# noise. Remove them once, up front.
kubectl get httproute -n "$NS" -o name 2>/dev/null \
    | grep -- '-kserve-route$' | xargs -r kubectl delete -n "$NS" >/dev/null 2>&1 || true

for shape in "${SHAPES[@]}"; do
    echo -e "\n${BOLD}== ${shape} ==${NC}"
    manifest=$(manifest_for "$shape")

    # Delete before apply: shapes differ in rule count, and a stale rule left
    # behind by a merge would silently serve traffic the new shape never
    # declared.
    kubectl get httproute -n "$NS" -o name 2>/dev/null \
        | grep -- '-characterize$' | xargs -r kubectl delete -n "$NS" >/dev/null 2>&1 || true
    kubectl apply -f "$manifest" >/dev/null

    for _ in $(seq 1 30); do
        ready=$(kubectl get httproute -n "$NS" -o json \
            | python3 -c '
import json,sys
items=[i for i in json.load(sys.stdin)["items"] if i["metadata"]["name"].endswith("-characterize")]
ok=all(any(c["type"]=="Accepted" and c["status"]=="True"
           for p in i.get("status",{}).get("parents",[]) for c in p.get("conditions",[]))
       for i in items)
print("yes" if items and ok else "no")')
        [[ "$ready" == "yes" ]] && break
        sleep 2
    done

    # Routes reporting Accepted is not the same as the gateway serving them.
    # Swapping between shapes that do and do not reference an InferencePool
    # makes Istio rebuild the listener filter chain (adding/removing ext_proc),
    # and until that lands, POSTs are sent to a stale ext_proc cluster and 500.
    # Wait on an actual request instead of on a fixed sleep.
    gw="${GATEWAY_URL:-http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)}"
    for _ in $(seq 1 45); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
            -H 'Content-Type: application/json' -d '{"model":"canary"}' \
            "${gw}/lora-budget/svc-a/v1/chat/completions" 2>/dev/null || echo 000)
        [[ "$code" == "200" ]] && break
        sleep 2
    done
    [[ "$code" == "200" ]] || echo "  WARN: canary still $code -- table may be noisy"

    ./characterize.sh --shape "$shape" --update >/dev/null 2>&1
    n=$(grep -vc '^#' "golden/${shape}.tsv")
    moved=$(diff <(tail -n +2 golden/current.tsv) <(tail -n +2 "golden/${shape}.tsv") 2>/dev/null \
        | grep -c '^<' || true)
    printf "  ${GREEN}recorded${NC} %s probes, %s moved vs current\n" "$n" "$moved"
done

echo -e "\n${BOLD}Summary (probes moved vs current)${NC}"
for shape in "${SHAPES[@]}"; do
    [[ -f "golden/${shape}.tsv" ]] || continue
    moved=$(diff <(tail -n +2 golden/current.tsv) <(tail -n +2 "golden/${shape}.tsv") 2>/dev/null \
        | grep -c '^<' || true)
    printf '  %-16s %s\n' "$shape" "$moved"
done
