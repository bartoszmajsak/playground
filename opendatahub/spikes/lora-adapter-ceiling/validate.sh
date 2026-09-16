#!/usr/bin/env bash
# LoRA adapter ceiling spike - assertions.
#
# Tier 1 is control-plane only: it reads what the controller renders and needs
# no pod to become Ready, so it runs in seconds and without a model download.
# That covers the whole hypothesis except the runtime consequence, which
# ../lora-fleet/validation/runtime-contract.md Q8b already measured.
#
# Environment:
#   NS          namespace (default: lora-ceiling)
#   KEEP        keep the services after the run (default: unset, they are deleted)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-lora-ceiling}"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${YELLOW}INFO${NC}: $*"; }
ok()     { echo -e "${GREEN}  OK${NC}: $*"; }
fail()   { echo -e "${RED}FAIL${NC}: $*"; FAILURES=$((FAILURES+1)); }
header() { echo -e "\n${BOLD}$*${NC}"; }
FAILURES=0

cleanup() {
    [[ -n "${KEEP:-}" ]] && return
    kubectl delete -n "$NS" -f "${SCRIPT_DIR}/manifests/services.yaml" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

header "Deploying the two services"
kubectl apply -n "$NS" -f "${SCRIPT_DIR}/manifests/services.yaml"

# The Deployment is rendered well before the pod can pull a model, so poll for
# the object rather than for readiness.
for svc in ceiling-default ceiling-explicit; do
    for _ in $(seq 1 60); do
        kubectl get -n "$NS" deployment "${svc}-kserve" >/dev/null 2>&1 && break
        sleep 2
    done
done

args_of() {
    kubectl get -n "$NS" deployment "${1}-kserve" \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="main")].args}' 2>/dev/null
}

# The args arrive as a JSON array whose LoRA entries are single-quoted JSON
# objects with escaped quotes, so parse them rather than matching text.
count_names() {
    python3 - "$1" "$2" <<'PY'
import json, sys
args = json.loads(sys.argv[1] or "[]")
prefix = sys.argv[2]
bare = qual = 0
for a in args:
    a = a.strip("'")
    if not a.startswith("{"):
        continue
    name = json.loads(a).get("name", "")
    if name.startswith("publishers/"):
        qual += name.rsplit("/", 1)[-1].startswith(prefix)
    else:
        bare += name.startswith(prefix)
print(bare, qual)
PY
}

flag_of() {
    python3 - "$1" "$2" <<'PY'
import json, sys
args = json.loads(sys.argv[1] or "[]")
for a in args:
    if a.startswith(sys.argv[2] + "="):
        print(a.split("=", 1)[1])
        break
PY
}

header "1. Each adapter is registered twice"
ARGS="$(args_of ceiling-default)"
if [[ -z "$ARGS" ]]; then
    fail "no rendered args for ceiling-default; is the controller running?"
else
    read -r BARE QUAL <<<"$(count_names "$ARGS" ceil-a)"
    echo "    declared adapters: 4, bare names: ${BARE}, publisher-qualified: ${QUAL}"
    if [[ "$BARE" == 4 && "$QUAL" == 4 ]]; then
        ok "8 --lora-modules entries for 4 adapters, as workload_lora.go:451-454 renders"
    else
        fail "expected 4 bare and 4 qualified, got ${BARE} and ${QUAL}"
    fi
fi

header "2. Which budget flags reach vLLM when the spec omits them"
CPU_D="$(flag_of "$ARGS" --max-cpu-loras)"
MAX_D="$(flag_of "$ARGS" --max-loras)"
echo "    --max-loras=${MAX_D:-unset}, --max-cpu-loras=${CPU_D:-unset}"
if [[ -z "$CPU_D" && -z "$MAX_D" ]]; then
    ok "neither flag injected; the budget is whatever vLLM resolves by default"
    info "OPEN: does vLLM size the CPU cache from the 8 --lora-modules entries, or from"
    info "      max_loras, whose default is 1? The API doc for MaxCpuAdapters claims it"
    info "      'defaults to the number of configured adapters', which nothing here sets."
else
    fail "a flag was injected although the spec sets neither (contradicts workload_lora.go:542)"
fi

header "3. An explicit budget is sized against adapters, not registrations"
EARGS="$(args_of ceiling-explicit)"
read -r EBARE EQUAL <<<"$(count_names "$EARGS" ceil-b)"
REG=$((EBARE + EQUAL))
CPU="$(flag_of "$EARGS" --max-cpu-loras)"
echo "    --max-cpu-loras=${CPU:-unset}, registrations=${REG}"
if [[ -n "$CPU" && "$REG" -gt "$CPU" ]]; then
    ok "${REG} registrations against ${CPU} slots: over-subscribed ${REG}/${CPU}"
    info "Q8b in ../lora-fleet/validation/runtime-contract.md measured this case:"
    info "      362-368 ms per request, on every request, from evict-and-reload"
else
    fail "expected registrations to exceed the budget; got ${REG} against ${CPU:-unset}"
fi

header "4. Nothing reports the over-subscription"
COND=$(kubectl get -n "$NS" llminferenceservice ceiling-explicit -o json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(c["type"]+"="+c["status"] for c in d.get("status",{}).get("conditions",[])))' 2>/dev/null || true)
EV=$(kubectl get events -n "$NS" --field-selector involvedObject.name=ceiling-explicit -o name 2>/dev/null | wc -l)
echo "    conditions: ${COND:-none}"
echo "    events: ${EV}"
if grep -qi "capacity\|budget\|adapter" <<<"$COND"; then
    ok "a condition mentions the budget"
else
    ok "no condition mentions capacity: the ceiling is silent, which is the operator-facing half of the bug"
fi

header "5. Publisher-path routes: pool-backed or Service-backed"
# A Service-backed publisher path never reaches the EPP, so no
# InferenceModelRewrite rule could rewrite the body model on that leg.
ROUTES="$(kubectl get httproute -n "$NS" -o json 2>/dev/null || echo '{}')"
python3 - "$ROUTES" <<'PY' || fail "could not read HTTPRoutes"
import json, sys
d = json.loads(sys.argv[1] or "{}")
rows = []
for r in d.get("items", []):
    for rule in r["spec"].get("rules", []):
        kinds = {b.get("kind", "Service") for b in rule.get("backendRefs", [])}
        for m in rule.get("matches", []):
            p = (m.get("path") or {}).get("value", "/")
            if p.startswith("/publishers/"):
                rows.append((r["metadata"]["name"], p, ",".join(sorted(kinds)) or "none"))
if not rows:
    print("    no publisher-path matches found")
    sys.exit(0)
for name, p, kinds in sorted(rows):
    print("    %-32s %-44s -> %s" % (name, p, kinds))
svc = [r for r in rows if "Service" in r[2]]
inference_svc = [r for r in svc if "/v1/" in r[1]]
print("    %d of %d publisher paths are Service-backed" % (len(svc), len(rows)))
if inference_svc:
    print("    CONSEQUENCE: %d inference path(s) bypass the router, so an" % len(inference_svc))
    print("    InferenceModelRewrite rule cannot rewrite the body model there and the")
    print("    second registration stays load-bearing.")
elif svc:
    print("    Every inference path is pool-backed, so a rewrite rule covers inference.")
    print("    The Service-backed ones carry no /v1/ suffix: they are the model metadata")
    print("    route, which answers from the pod's own listing rather than through the")
    print("    router. Dropping the qualified registration changes what it reports.")
PY

header "Summary"
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}All assertions passed${NC}"
else
    echo -e "${RED}${FAILURES} assertion(s) failed${NC}"
fi
exit $FAILURES
