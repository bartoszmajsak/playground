#!/usr/bin/env bash
# Validate routing, complete responses, and the TRLP response defect on the spike.
# Usage: ./validate.sh [--scenario all|defect|trlp|fix|auth|auth-order|control]
#                     [--smoke] [--requests N] [--keep-fix]
# Default: all. TRLP tests briefly pause MaaS reconciliation and remove the
# model and inherited gateway token policies. Use a disposable kind cluster.
# Every run has a separate results directory; policies are restored on exit.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

SCENARIOS=()
KEEP_FIX=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario) SCENARIOS+=("$2"); shift ;;
        --smoke) REQUESTS=5 ;;
        --requests) REQUESTS="$2"; shift ;;
        --keep-fix) KEEP_FIX=1 ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) err "unknown flag: $1" ;;
    esac
    shift
done
[[ "$REQUESTS" =~ ^[1-9][0-9]*$ ]] || err "REQUESTS must be positive"
[[ ${#SCENARIOS[@]} -gt 0 ]] || SCENARIOS=(all)
if [[ " ${SCENARIOS[*]} " == *" all "* ]]; then SCENARIOS=(defect trlp fix auth); fi
for scenario in "${SCENARIOS[@]}"; do
    case "$scenario" in defect|trlp|fix|auth|auth-order|control) ;; *) err "unknown scenario: $scenario" ;; esac
done

# Re-enter with one tee pipeline so strict error handling and EXIT cleanup
# execute in the process doing the mutations, and the log is fully drained.
if [[ "${VALIDATE_LOGGED:-0}" != 1 ]]; then
    RESULTS="$RESULTS/validation-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    export RESULTS
    mkdir -p "$RESULTS"
    export VALIDATE_LOGGED=1
    flags=(--requests "$REQUESTS")
    for scenario in "${SCENARIOS[@]}"; do flags+=(--scenario "$scenario"); done
    [[ "$KEEP_FIX" == 0 ]] || flags+=(--keep-fix)
    set +e
    bash "$0" "${flags[@]}" 2>&1 | tee "$RESULTS/validate.out"
    exit "${PIPESTATUS[0]}"
fi

FAILURES=0
FIX_TOUCHED=0
POLICIES_REMOVED=0
CONTROLLER_PAUSED=0
CONTROLLER_REPLICAS=0
POLICY_DIR="$RESULTS/policies"
MAAS_CONTROLLER="${MAAS_CONTROLLER:-maas-controller}"
HEADLINES=()

wait_policies() {
    local state="$1"
    for _ in $(seq 1 60); do
        capture config_dump "$POLICY_DIR/convergence.json"
        if python3 "$SCRIPT_DIR/scripts/policy-state.py" check "$POLICY_DIR/restore.json" "$POLICY_DIR/convergence.json" "$state"; then return 0; fi
        sleep 1
    done
    return 1
}

restore_policies() {
    if (( POLICIES_REMOVED )); then
        kc apply -f "$POLICY_DIR/restore.json" || return 1
        wait_policies present || return 1
        POLICIES_REMOVED=0
    fi
    if (( CONTROLLER_PAUSED )); then
        kc scale deployment "$MAAS_CONTROLLER" -n "$MAAS_NAMESPACE" --replicas="$CONTROLLER_REPLICAS" || return 1
        if (( CONTROLLER_REPLICAS > 0 )); then
            kc rollout status "deployment/$MAAS_CONTROLLER" -n "$MAAS_NAMESPACE" --timeout=60s || return 1
        fi
        CONTROLLER_PAUSED=0
    fi
}

cleanup() {
    local rc=$? cleanup_failed=0
    trap - EXIT
    set +e
    restore_policies || cleanup_failed=1
    if (( FIX_TOUCHED )) && { (( KEEP_FIX == 0 )) || (( rc != 0 )); }; then
        "$SCRIPT_DIR/fix.sh" revert || cleanup_failed=1
    fi
    if (( cleanup_failed )); then
        echo "Restoration failed; saved policies: $POLICY_DIR/restore.json; original controller replicas: $CONTROLLER_REPLICAS" >&2
        rc=1
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

apply_fix() { FIX_TOUCHED=1; FIX_VARIANT="$1" "$SCRIPT_DIR/fix.sh" apply; }
revert_fix() { FIX_TOUCHED=1; "$SCRIPT_DIR/fix.sh" revert; }

limitador_scrape() {
    kc exec -n "$GATEWAY_NAMESPACE" "$(gateway_pod)" -c istio-proxy -- curl -fsS --max-time 20 \
        "http://${LIMITADOR_SERVICE:-limitador-limitador.kuadrant-system.svc.cluster.local}:8080/metrics" > "$1"
}

capture_state() {
    local dir="$1"
    capture config_dump "$dir/config_dump.json"
    "$SCRIPT_DIR/scripts/check-filter-order.sh" --dump "$dir/config_dump.json" --json > "$dir/diag.json" || true
    jq -e '.chain | length > 0' "$dir/diag.json" >/dev/null
    kc get envoyfilters -n "$GATEWAY_NAMESPACE" -o yaml > "$dir/envoyfilters.yaml"
    kc get httproutes -n "$NS" -o yaml > "$dir/httproutes.yaml"
    kc get tokenratelimitpolicies -A -o json > "$dir/policies.json"
    kc get pods -n "$NS" -o json > "$dir/pods-before.json"
    kc get deploy "${LLMISVC_NAME}-kserve-router-scheduler" -n "$NS" -o json > "$dir/epp-deployment.json"
}

run_phase() {
    local phase="$1" chain="$2" picks="$3" response="$4" auth="$5"; shift 5
    local dir="$RESULTS/$phase" since epp n="$REQUESTS" burst="${PREFIX_REQUESTS:-12}" streams=1 fragments=1
    local -a score_args=(--chain "$chain" --responses "$response")
    [[ "$picks" == no ]] || score_args+=(--picks)
    [[ "$auth" == valid ]] || { streams=0; fragments=0; burst=0; score_args+=(--status 401); }
    # The expected defect only needs a few completions and one stream. All
    # positive phases still exercise the full traffic mix, including bursts.
    if [[ "$response" == empty ]]; then n=3; burst=0; fi
    score_args+=("$@")
    [[ ! -e "$dir" ]] || err "phase directory already exists: $dir"
    mkdir -p "$dir"
    header "Scenario: $phase"
    capture_state "$dir"
    epp=$(epp_scrape "$dir/epp-before.prom")
    vllm_scrape_all "$dir" before
    if [[ " ${score_args[*]} " == *" --accounting "* ]]; then limitador_scrape "$dir/limitador-before.prom"; fi
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sleep 1
    python3 "$SCRIPT_DIR/scripts/traffic.py" "$phase" "$dir" --requests "$n" --streams "$streams" \
        --fragments "$fragments" --burst "$burst" --concurrency "${PREFIX_CONCURRENCY:-6}" --auth "$auth"
    vllm_scrape_all "$dir" after
    epp=$(epp_scrape "$dir/epp-after.prom")
    sleep 3
    if [[ " ${score_args[*]} " == *" --accounting "* ]]; then limitador_scrape "$dir/limitador-after.prom"; fi
    kc logs -n "$GATEWAY_NAMESPACE" "$(gateway_pod)" -c istio-proxy --since-time="$since" > "$dir/gateway.log"
    kc logs -n "$NS" "$epp" --since-time="$since" > "$dir/epp.log"
    kc get pods -n "$NS" -o json > "$dir/pods-after.json"
    local rc=0
    python3 "$SCRIPT_DIR/score.py" "$phase" "$dir" --model-id "$MODEL_ID" --model-name "$MODEL_NAME" \
        --route-prefix "${NS}.${LLMISVC_NAME}-kserve-route." "${score_args[@]}" > "$dir/score.txt" 2>&1 || rc=$?
    cat "$dir/score.txt"
    FAILURES=$((FAILURES + (rc != 0)))
    HEADLINES+=("$(cat "$dir/headline" 2>/dev/null || echo "$phase: scorer failed")")
}

trlp_scenario() {
    [[ "$(kc config current-context)" == "kind-$CLUSTER_NAME" ]] || err "TRLP deletion requires this spike's disposable kind context: kind-$CLUSTER_NAME"
    mkdir -p "$POLICY_DIR"
    kc get tokenratelimitpolicies -A -o json > "$POLICY_DIR/before.json"
    python3 "$SCRIPT_DIR/scripts/policy-state.py" snapshot "$POLICY_DIR/before.json" "$POLICY_DIR/restore.json" \
        --model-namespace "$NS" --route "${LLMISVC_NAME}-kserve-route" --gateway-namespace "$GATEWAY_NAMESPACE" --gateway "$GATEWAY_NAME"
    wait_policies present
    apply_fix pre-only
    run_phase trlp-present OK yes empty valid
    kc get deployment "$MAAS_CONTROLLER" -n "$MAAS_NAMESPACE" -o json > "$POLICY_DIR/controller-before.json"
    CONTROLLER_REPLICAS=$(jq -er '.spec.replicas' "$POLICY_DIR/controller-before.json")
    CONTROLLER_PAUSED=1
    kc scale deployment "$MAAS_CONTROLLER" -n "$MAAS_NAMESPACE" --replicas=0
    local selector
    selector=$(jq -r '.spec.selector.matchLabels | to_entries | map(.key + "=" + .value) | join(",")' "$POLICY_DIR/controller-before.json")
    [[ -n "$selector" ]] || err "controller has no pod selector"
    kc wait pod -n "$MAAS_NAMESPACE" -l "$selector" --for=delete --timeout=60s
    POLICIES_REMOVED=1
    kc delete -f "$POLICY_DIR/restore.json"
    wait_policies absent
    run_phase trlp-absent OK yes complete valid
    python3 "$SCRIPT_DIR/scripts/compare-config.py" "$RESULTS/trlp-present/config_dump.json" "$RESULTS/trlp-absent/config_dump.json" policies > "$POLICY_DIR/removed-comparison.json"
    revert_fix
    run_phase trlp-absent-original BROKEN no complete valid
    wait_policies absent
    kc get tokenratelimitpolicies -A -o json > "$POLICY_DIR/absent-after.json"
    restore_policies
    apply_fix pre-only
    run_phase trlp-restored OK yes empty valid
    python3 "$SCRIPT_DIR/scripts/compare-config.py" "$RESULTS/trlp-present/config_dump.json" "$RESULTS/trlp-restored/config_dump.json" policies > "$POLICY_DIR/restored-comparison.json"
    revert_fix
    kc get tokenratelimitpolicies -A -o json > "$POLICY_DIR/restored.json"
}

header "Preflight"
echo "Evidence: $RESULTS"
kc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" >/dev/null
[[ -n "$(gateway_pod)" ]] || err "no Ready gateway pod"
kc wait llmisvc "$LLMISVC_NAME" -n "$NS" --for=condition=Ready --timeout=30s
[[ -n "$(epp_pod)" ]] || err "no EPP pod"
export GW_URL MODEL_ID MODEL_NAME API_KEY
GW_URL=$(gateway_url)
API_KEY=$(maas_api_key epp-spike-validate)
[[ -n "$API_KEY" && -n "$GW_URL" ]] || err "gateway address or API key missing"
kc get pods -A -o json | jq '[.items[] | {namespace:.metadata.namespace,name:.metadata.name,containers:[.status.containerStatuses[]? | {name,image,imageID}]}]' > "$RESULTS/images.json"
envoy_admin server_info > "$RESULTS/server-info.json"
if [[ " ${SCENARIOS[*]} " == *" control "* ]]; then export FIX_REVERT_EXPECT=OK; fi
if kc get envoyfilter "$FIX_EF_NAME" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1; then revert_fix; fi
for scenario in "${SCENARIOS[@]}"; do
    case "$scenario" in
        defect) revert_fix; run_phase defect BROKEN no complete valid ;;
        control) run_phase control OK yes complete valid ;;
        trlp) trlp_scenario ;;
        fix)
            apply_fix epp-after-ipp
            run_phase fix OK yes complete valid --after-ipp --accounting
            revert_fix
            run_phase reverted BROKEN no complete valid
            python3 "$SCRIPT_DIR/scripts/compare-config.py" "$RESULTS/reverted/config_dump.json" "$RESULTS/fix/config_dump.json" order > "$RESULTS/fix/config-comparison.json"
            ;;
        auth)
            apply_fix epp-after-ipp
            run_phase no-auth OK no complete none --after-ipp
            run_phase invalid-auth OK no complete invalid --after-ipp
            revert_fix
            ;;
        auth-order)
            apply_fix pre-only
            run_phase auth-order OK yes complete none
            revert_fix
            ;;
    esac
done
header "Summary"
printf '%s\n' "${HEADLINES[@]}"
if (( FAILURES )); then fail "$FAILURES phase(s) failed"; exit 1; fi
if (( KEEP_FIX )); then apply_fix epp-after-ipp; fi
ok "all requested scenarios passed; see each phase's response expectation"
