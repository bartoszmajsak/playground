#!/usr/bin/env bash
# Tier 1: capture the HTTPRoutes the controller generates, and the budget
# arithmetic behind them.
#
# Two jobs:
#
#   1. Freeze the generated route shape as golden/route-<shape>.yaml. That file
#      is tier 2's input -- swap-backends.sh rewrites its backendRefs and
#      characterize.sh replays probes against it. It is also a golden in its
#      own right: a rule rename or a match-count change shows up here first,
#      before any traffic is sent.
#
#   2. Report rules / matches-per-rule / total matches per route, and sweep the
#      adapter count to find where the apiserver actually refuses. That is the
#      budget number, measured rather than derived.
#
# Needs the kserve llmisvc controller. Tier 2 does not -- once golden/ is
# populated, characterize.sh runs against a bare gateway.
#
# Usage:
#   ./capture-routes.sh                    # apply fixtures, capture, report
#   ./capture-routes.sh --shape current    # name the golden file
#   ./capture-routes.sh --sweep 0,3,6,7,8,12,13   # find the real ceiling
#
# Environment:
#   NS            fixture namespace (default: lora-budget)
#   CLUSTER_NAME  kind cluster name (default: lora-budget-spike)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-lora-budget-spike}"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"

NS="${NS:-lora-budget}"
GOLDEN_DIR="${SCRIPT_DIR}/golden"
SHAPE="current"
SWEEP=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "  ${CYAN}INFO${NC}: $1"; }
pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC}: $1"; }
header() { echo -e "\n${BOLD}$1${NC}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shape) SHAPE="$2"; shift 2 ;;
        --sweep) SWEEP="$2"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$GOLDEN_DIR"

# ---------------------------------------------------------------------------
# Budget arithmetic, read off a live route
# ---------------------------------------------------------------------------

budget_report() {
    header "Budget"
    printf '  %-28s %-7s %-9s %-9s\n' 'route' 'rules' 'max/rule' 'total'
    printf '  %-28s %-7s %-9s %-9s\n' '----------------------------' '-----' '--------' '-----'

    local route rules maxrule total
    for route in $(kubectl get httproute -n "$NS" -o name 2>/dev/null); do
        read -r rules maxrule total < <(
            kubectl get "$route" -n "$NS" -o json |
            jq -r '[(.spec.rules // [] | length),
                    ([.spec.rules[]? | (.matches // []) | length] | max // 0),
                    ([.spec.rules[]? | (.matches // []) | length] | add // 0)]
                   | @tsv'
        )
        printf '  %-28s %-7s %-9s %-9s\n' "${route#httproute.gateway.networking.k8s.io/}" \
            "$rules" "$maxrule" "$total"
    done

    echo
    # Read the caps off the CRD the cluster actually installed, not off a
    # constant. Older Gateway API CRDs cap matches at 8 per rule, not 64 --
    # a budget check against vendored constants passes at 40 and the apiserver
    # still refuses. Every run should record which numbers it was judged by.
    kubectl get crd httproutes.gateway.networking.k8s.io -o json 2>/dev/null | python3 -c '
import json, sys
crd = json.load(sys.stdin)
ver = next(x for x in crd["spec"]["versions"] if x.get("storage"))
rules = ver["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["rules"]
matches = rules["items"]["properties"]["matches"]
cel = [r for r in rules.get("x-kubernetes-validations", [])
       if "total number of matches" in r.get("message", "")]
print("  INFO: installed CRD (%s) caps: %s rules, %s matches/rule, %s matches/route"
      % (ver["name"], rules.get("maxItems", "?"), matches.get("maxItems", "?"),
         "128" if cel else "no CEL total rule"))
' || info "installed CRD caps: unreadable"
}

# Per-rule breakdown -- shows which rule is the one that grows.
rule_breakdown() {
    local route="$1"
    header "Rule breakdown: ${route}"
    kubectl get httproute "$route" -n "$NS" -o json |
        jq -r '.spec.rules[] |
               "  \(.name // "(unnamed)")\t\((.matches // []) | length)\t\(
                  (.backendRefs // [])[0] | "\(.kind // "Service")/\(.name)")"' |
        column -t -s $'\t'
}

# ---------------------------------------------------------------------------
# Adapter sweep -- where does the apiserver actually say no?
# ---------------------------------------------------------------------------

set_adapters() {
    local n="$1" adapters
    if [[ "$n" -eq 0 ]]; then
        kubectl patch llminferenceservice svc-a -n "$NS" --type merge \
            -p '{"spec":{"model":{"lora":null}}}' >/dev/null
        return
    fi
    adapters=$(seq -f 'adapter-a%g' 1 "$n" |
        jq -R -s -c 'split("\n") | map(select(length>0)) |
                     map({name: ., uri: ("pvc://lora-budget-models/" + .)})')
    kubectl patch llminferenceservice svc-a -n "$NS" --type merge \
        -p "{\"spec\":{\"model\":{\"lora\":{\"adapters\":${adapters}}}}}" >/dev/null
}

sweep() {
    header "Adapter sweep (svc-a)"
    printf '  %-4s %-9s %-9s %-10s %s\n' 'A' 'max/rule' 'total' 'route' 'controller says'
    printf '  %-4s %-9s %-9s %-10s %s\n' '----' '--------' '-----' '--------' '---------------'

    local n maxrule total verdict msg gen observed
    for n in ${SWEEP//,/ }; do
        set_adapters "$n"

        # Wait for the controller to act on this generation, not just for time
        # to pass -- otherwise a slow reconcile reads as "accepted".
        gen=$(kubectl get llminferenceservice svc-a -n "$NS" -o jsonpath='{.metadata.generation}')
        for _ in $(seq 1 30); do
            observed=$(kubectl get llminferenceservice svc-a -n "$NS" \
                -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "")
            [[ "$observed" == "$gen" ]] && break
            sleep 1
        done

        read -r maxrule total < <(
            kubectl get httproute svc-a-kserve-route -n "$NS" -o json 2>/dev/null |
            jq -r '[([.spec.rules[]? | (.matches // []) | length] | max // 0),
                    ([.spec.rules[]? | (.matches // []) | length] | add // 0)] | @tsv'
        ) || { maxrule="-"; total="-"; }

        # The route is only "applied" if it reflects this adapter count.
        # A stale route that still serves the previous count is a rejection.
        if [[ "$maxrule" == "-" ]]; then
            verdict="absent"
        else
            verdict="applied"
        fi

        msg=$(kubectl get llminferenceservice svc-a -n "$NS" -o json 2>/dev/null |
              jq -r '[.status.conditions[]? | select(.status=="False")
                      | "\(.type)=\(.reason)"] | join(",") // "-"')
        [[ -z "$msg" ]] && msg="-"

        printf '  %-4s %-9s %-9s %-10s %s\n' "$n" "$maxrule" "$total" "$verdict" "${msg:0:60}"
    done

    echo
    info "'applied' with a stale max/rule means the apiserver refused the update"
    info "controller logs: kubectl logs -n kserve -l control-plane=llmisvc-controller-manager --tail=40 | grep -i 'matches\\|rules'"
}

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

kubectl create namespace "$NS" >/dev/null 2>&1 || true

header "Applying fixtures"
kubectl apply -f "${SCRIPT_DIR}/manifests/fixtures.yaml"

info "waiting for generated HTTPRoutes"
for _ in $(seq 1 60); do
    n=$(kubectl get httproute -n "$NS" -o name 2>/dev/null | grep -c kserve-route || true)
    [[ "${n:-0}" -ge 3 ]] && break
    sleep 2
done
[[ "${n:-0}" -ge 3 ]] || warn "only ${n:-0}/3 routes appeared -- capturing what exists"

if [[ -n "$SWEEP" ]]; then
    sweep
    info "restoring svc-a to 2 adapters"
    set_adapters 2
    sleep 5
fi

header "Capturing route shape -> golden/route-${SHAPE}.yaml"
# Only the controller-generated routes. The neighbour tenant is fixture, not
# artifact -- capturing it would produce a duplicate copy that competes with the
# real one for the same root-path matches.
kubectl get httproute -n "$NS" -o json |
    jq '.items | map(select(.metadata.name | endswith("-kserve-route"))) | sort_by(.metadata.name) | .[]
        | del(.status, .metadata.managedFields, .metadata.resourceVersion,
              .metadata.uid, .metadata.generation, .metadata.creationTimestamp,
              .metadata.ownerReferences, .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")' |
    python3 -c '
import json, sys, yaml
docs = []
dec = json.JSONDecoder()
buf = sys.stdin.read()
i = 0
while i < len(buf):
    while i < len(buf) and buf[i].isspace():
        i += 1
    if i >= len(buf):
        break
    obj, j = dec.raw_decode(buf, i)
    docs.append(obj)
    i = j
yaml.safe_dump_all(docs, sys.stdout, sort_keys=False, default_flow_style=False)
' > "${GOLDEN_DIR}/route-${SHAPE}.yaml"

pass "captured $(grep -c '^kind: HTTPRoute' "${GOLDEN_DIR}/route-${SHAPE}.yaml" || echo 0) routes"

budget_report

for r in svc-a-kserve-route svc-c-kserve-route; do
    kubectl get httproute "$r" -n "$NS" >/dev/null 2>&1 && rule_breakdown "$r"
done

# svc-c is the strip case. Assert it rather than assume it -- if the CR
# annotation did not override the preset, the header rules will still be here
# and the "disabled" probe family in probes.tsv is characterizing nothing.
header "Model-based routing strip (svc-c)"
if kubectl get httproute svc-c-kserve-route -n "$NS" >/dev/null 2>&1; then
    hdr_rules=$(kubectl get httproute svc-c-kserve-route -n "$NS" -o json |
        jq '[.spec.rules[]? | select((.matches // []) | any(.headers != null))] | length')
    if [[ "$hdr_rules" -eq 0 ]]; then
        pass "header rules stripped -- CR annotation overrode the preset"
    else
        warn "${hdr_rules} header rule(s) still present -- the CR annotation did NOT take effect"
        warn "the 'disabled' probe family will characterize the enabled shape; fix the fixture"
    fi
else
    warn "svc-c route absent"
fi

header "Next"
echo "  ./swap-backends.sh golden/route-${SHAPE}.yaml | kubectl apply -f -"
echo "  ./characterize.sh --shape ${SHAPE} --update"
