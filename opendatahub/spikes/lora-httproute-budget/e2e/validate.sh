#!/usr/bin/env bash
# Thin, stable CLI over the pytest suite. Owns nothing but scenario/case
# selection, the two-phase serialization contract, and the exit-code contract:
#   0 all selected assertions passed
#   1 harness ran, one or more product assertions failed
#   2 setup/dependency/harness failure — no valid verdict
#
# Usage:
#   ./validate.sh --scenario smoke|shape|transitions|budget|capacity|all
#   ./validate.sh --case <pytest -k expression or node id>
#   ./validate.sh --scenario all --run <run-id>
#
# Phase contract: tests marked routing_strategy_mutation run first and strictly
# serially (they mutate the cluster-global strategy); routing_strategy_readonly
# tests run afterwards. A mutation-phase harness error stops the run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

SCENARIO=""
CASE_EXPR=""
RUN_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario) SCENARIO="$2"; shift 2 ;;
        --case)     CASE_EXPR="$2"; shift 2 ;;
        --run)      RUN_ARG="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -n "$SCENARIO" || -n "$CASE_EXPR" ]] || die "pass --scenario or --case"

require_bins python3
load_run "$RUN_ARG"
guard_cluster

VENV="${E2E_DIR}/.venv"
if [[ ! -x "${VENV}/bin/pytest" ]]; then
    info "creating python venv"
    python3 -m venv "$VENV" || die "venv creation failed"
    "${VENV}/bin/pip" install -q -r "${E2E_DIR}/requirements.txt" || die "pip install failed"
fi

LORA_E2E_GATEWAY_URL="$(meta_get "$RUN_DIR" gatewayURL)"
LORA_E2E_FIXTURE_NS="$(meta_get "$RUN_DIR" fixtureNamespace)"
LORA_E2E_FIXTURE_PVC="$(meta_get "$RUN_DIR" fixturePVC)"
LORA_E2E_ADAPTER_COUNT="$(meta_get "$RUN_DIR" adapterCount)"
export LORA_E2E_RUN_DIR="$RUN_DIR"
export LORA_E2E_KUBECONFIG="$KUBECONFIG_PATH"
export LORA_E2E_GATEWAY_URL LORA_E2E_FIXTURE_NS LORA_E2E_FIXTURE_PVC LORA_E2E_ADAPTER_COUNT

# Scenario -> pytest -m / -k selection. "smoke" is the fast development
# profile; "all" is the complete local qualification.
select_args() { # select_args <phase-marker>
    local phase="$1"
    local m="$phase"
    case "$SCENARIO" in
        "" )          ;;
        smoke)        m="${phase} and smoke" ;;
        shape)        m="${phase} and shape" ;;
        transitions)  m="${phase} and transitions" ;;
        budget)       m="${phase} and budget" ;;
        capacity)     m="${phase} and capacity" ;;
        all)          ;;
        *) die "unknown scenario '${SCENARIO}'" ;;
    esac
    echo "$m"
}

run_phase() { # run_phase <marker> <report-suffix>
    local marker="$1" suffix="$2" rc=0
    local -a args=(
        -m "$marker"
        --json-report "--json-report-file=${RUN_DIR}/pytest-${suffix}.json"
        "--junitxml=${RUN_DIR}/junit-${suffix}.xml"
        -o cache_dir="${E2E_DIR}/.pytest_cache"
        -q -rA --color=yes
    )
    if [[ -n "$CASE_EXPR" ]]; then args+=(-k "$CASE_EXPR"); fi
    info "pytest phase: ${suffix} (-m '${marker}')"
    ( cd "$E2E_DIR" && "${VENV}/bin/pytest" tests "${args[@]}" ) || rc=$?
    # pytest exit 5 = no tests collected for this phase; that is fine.
    if [[ $rc -eq 5 ]]; then rc=0; fi
    return $rc
}

overall=0
run_phase "$(select_args routing_strategy_mutation)" mutation || overall=$?
if [[ $overall -gt 1 ]]; then
    die "mutation phase aborted with pytest exit ${overall}; cluster retained for diagnosis"
fi

run_phase "$(select_args routing_strategy_readonly)" readonly || rc2=$?
if [[ "${rc2:-0}" -gt 1 ]]; then die "readonly phase aborted with pytest exit ${rc2}"; fi
if [[ "${rc2:-0}" -ne 0 ]]; then overall=1; fi

# Aggregate an enforceable results.json from both phase reports. Success is
# never inferred from console text.
python3 - "$RUN_DIR" <<'PY' || die "failed to aggregate results.json"
import json, sys, glob, os
run_dir = sys.argv[1]
cases, counts = [], {"passed": 0, "failed": 0, "error": 0, "skipped": 0, "xfailed_expected_gap": 0}
for report in sorted(glob.glob(os.path.join(run_dir, "pytest-*.json"))):
    with open(report) as fh:
        data = json.load(fh)
    for t in data.get("tests", []):
        outcome = t["outcome"]
        if outcome in ("passed",):
            counts["passed"] += 1
        elif outcome in ("xfailed",):
            counts["xfailed_expected_gap"] += 1
        elif outcome in ("skipped",):
            counts["skipped"] += 1
        elif outcome in ("failed", "xpassed"):
            counts["failed"] += 1
        else:
            counts["error"] += 1
        cases.append({
            "nodeid": t["nodeid"],
            "outcome": outcome,
            "duration": round(t.get("call", {}).get("duration", 0.0), 3),
            "message": (t.get("call", {}).get("crash") or {}).get("message", "")[:2000],
        })
result = {"counts": counts, "cases": cases,
          "verdict": "pass" if counts["failed"] == 0 and counts["error"] == 0 and counts["passed"] > 0 else "fail"}
with open(os.path.join(run_dir, "results.json"), "w") as fh:
    json.dump(result, fh, indent=2)
print(json.dumps(counts))
PY

verdict="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "${RUN_DIR}/results.json")"
{
    echo "run:      ${RUN_ID}"
    echo "scenario: ${SCENARIO:-case:${CASE_EXPR}}"
    echo "verdict:  ${verdict}"
    python3 -c 'import json,sys; print("counts:  ", json.load(open(sys.argv[1]))["counts"])' "${RUN_DIR}/results.json"
    echo "artifacts: ${RUN_DIR}"
} | tee "${RUN_DIR}/summary.txt"

if [[ "$verdict" == "pass" && $overall -eq 0 ]]; then
    ok "all selected assertions passed"
    exit 0
fi
echo -e "${RED}assertion failures${NC} — see ${RUN_DIR}/results.json and observe.sh --run ${RUN_ID}"
exit 1
