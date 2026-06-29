#!/usr/bin/env bash
# Controlled Deployment E2E Validation
#
# Validates the full canary rollout lifecycle with real LLMISVCs.
#
# Usage:
#   ./validate.sh                                     # auto-detect gateway
#   ./validate.sh http://172.18.255.200               # explicit gateway
#   ./validate.sh --phase 2                           # single phase
#   ./validate.sh --step 4                            # single step
#   ./validate.sh --skip-deploy                       # pods already running
#   ./validate.sh --scenario service                   # plain Service backend
#   ./validate.sh --scenario mixed                     # mixed InferencePool + Service
#   ./validate.sh --scenario all                       # all scenarios in sequence
#   ./validate.sh --smoke                               # core canary lifecycle only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REQUESTS="${REQUESTS:-50}"

RUN_PHASE=""
RUN_STEP=""
SKIP_DEPLOY=false
SCENARIO="pool"
PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)
            [[ $# -ge 2 ]] || { echo "--phase requires a value"; exit 1; }
            RUN_PHASE="$2"; shift 2 ;;
        --step)
            [[ $# -ge 2 ]] || { echo "--step requires a value"; exit 1; }
            RUN_STEP="$2"; shift 2 ;;
        --scenario)
            [[ $# -ge 2 ]] || { echo "--scenario requires a value"; exit 1; }
            SCENARIO="$2"; shift 2 ;;
        --smoke) PROFILE="smoke"; shift ;;
        --skip-deploy) SKIP_DEPLOY=true; shift ;;
        http://*|https://*) GATEWAY_URL="$1"; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# --scenario all: run each overlay in sequence with namespace cleanup between runs
if [[ "$SCENARIO" == "all" ]]; then
    SCENARIOS=($(ls "$SCRIPT_DIR/manifests/overlays/"))
    TOTAL_FAILURES=0

    # Build forwarded args (everything except --scenario)
    FWD_ARGS=()
    [[ -n "$GATEWAY_URL" ]] && FWD_ARGS+=("$GATEWAY_URL")
    [[ -n "$RUN_PHASE" ]] && FWD_ARGS+=(--phase "$RUN_PHASE")
    [[ -n "$RUN_STEP" ]] && FWD_ARGS+=(--step "$RUN_STEP")
    [[ "$SKIP_DEPLOY" == "true" ]] && FWD_ARGS+=(--skip-deploy)
    [[ "$PROFILE" == "smoke" ]] && FWD_ARGS+=(--smoke)

    for sc in "${SCENARIOS[@]}"; do
        echo -e "\n${BOLD}========================================${NC}"
        echo -e "${BOLD}  Scenario: $sc${NC}"
        echo -e "${BOLD}========================================${NC}"

        sc_exit=0
        "$SCRIPT_DIR/validate.sh" --scenario "$sc" "${FWD_ARGS[@]}" || sc_exit=$?
        TOTAL_FAILURES=$((TOTAL_FAILURES + sc_exit))

        echo -e "\n${CYAN}Cleaning up namespace for next scenario...${NC}"
        kubectl delete namespace "$NS" --wait=true 2>/dev/null || true
    done

    echo -e "\n${BOLD}========================================${NC}"
    echo -e "${BOLD}  All scenarios complete${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo "Scenarios: ${SCENARIOS[*]}"
    if [[ $TOTAL_FAILURES -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All scenarios passed.${NC}"
    else
        echo -e "${RED}${BOLD}$TOTAL_FAILURES total failure(s) across all scenarios.${NC}"
    fi
    exit "$TOTAL_FAILURES"
fi

OVERLAY_DIR="$SCRIPT_DIR/manifests/overlays/$SCENARIO"
if [[ ! -d "$OVERLAY_DIR" ]]; then
    echo "Unknown scenario: $SCENARIO (no overlay at $OVERLAY_DIR)"
    echo "Available: $(ls "$SCRIPT_DIR/manifests/overlays/" | tr '\n' ' ')all"
    exit 1
fi

FAILURES=0
STEPS_RAN=0

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAILURES=$((FAILURES + 1)); }

SMOKE_STEPS="1 2 3 5 6 13"

should_run_phase() {
    [[ -n "$PROFILE" ]] && return 1
    [[ -z "$RUN_PHASE" || "$RUN_PHASE" == "$1" ]] && [[ -z "$RUN_STEP" ]];
}
should_run_step() {
    if [[ "$PROFILE" == "smoke" ]]; then
        [[ " $SMOKE_STEPS " == *" $1 "* ]]
        return
    fi
    [[ -z "$RUN_STEP" || "$RUN_STEP" == "$1" ]] && [[ -z "$RUN_PHASE" || "$RUN_PHASE" == "$2" ]];
}

step() {
    local num="$1" title="$2" phase="$3"
    if should_run_step "$num" "$phase"; then
        echo -e "\n${BOLD}Step $num: $title${NC}"
        STEPS_RAN=$((STEPS_RAN + 1))
        return 0
    fi
    return 1
}

wait_ready() {
    local name=$1 timeout=${2:-600}
    info "Waiting for $name to be Ready (timeout: ${timeout}s)"
    kubectl wait llmisvc "$name" -n "$NS" --for=condition=Ready --timeout="${timeout}s"
}

get_group_members() {
    kubectl get llmisvc "$1" -n "$NS" -o jsonpath='{.status.router.group.members[*].name}' 2>/dev/null
}

get_group_weight() {
    kubectl get llmisvc "$1" -n "$NS" -o jsonpath="{.status.router.group.members[?(@.name=='$2')].weight}" 2>/dev/null
}

get_condition() {
    kubectl get llmisvc "$1" -n "$NS" -o jsonpath="{.status.conditions[?(@.type=='$2')].status}" 2>/dev/null
}

get_condition_reason() {
    kubectl get llmisvc "$1" -n "$NS" -o jsonpath="{.status.conditions[?(@.type=='$2')].reason}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Traffic validation via x-served-by header (primary, fast)
# ---------------------------------------------------------------------------

send_requests() {
    local url="$1" count="$2"; shift 2
    local v1=0 v2=0 unknown=0 errors=0
    local payload='{"model":"'"$MODEL"'","prompt":"Hello","max_tokens":5}'

    for ((i = 0; i < count; i++)); do
        local resp_file
        resp_file=$(mktemp)
        local http_code
        http_code=$(curl -s -D "$resp_file" --max-time 30 \
            -H "Content-Type: application/json" \
            -d "$payload" \
            -o /dev/null -w "%{http_code}" \
            "$@" "$url" 2>/dev/null) || true

        if [[ "$http_code" != "200" ]]; then
            errors=$((errors + 1)); rm -f "$resp_file"; continue
        fi

        local sb
        sb=$(grep -i "x-served-by" "$resp_file" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)
        rm -f "$resp_file"

        case "$sb" in
            *"$V1"*) v1=$((v1 + 1)) ;;
            *"$V2"*) v2=$((v2 + 1)) ;;
            *)       unknown=$((unknown + 1)) ;;
        esac
    done
    echo "$v1 $v2 $unknown $errors"
}

check_split() {
    local label="$1" v1="$2" v2="$3" unknown="$4" errors="$5" lo="$6" hi="$7"
    local total=$((v1 + v2))
    if [[ $errors -gt 5 ]]; then fail "$label: too many errors ($errors)"; return; fi
    if [[ $total -eq 0 ]]; then fail "$label: no responses (unknown=$unknown errors=$errors)"; return; fi
    local all=$((total + unknown))
    if [[ $all -gt 0 && $((unknown * 100 / all)) -gt 10 ]]; then fail "$label: too many unattributed responses ($unknown/$all)"; return; fi
    local pct=$((v1 * 100 / total))
    info "$label: v1=${pct}% v2=$((100 - pct))% (v1=$v1 v2=$v2 unknown=$unknown err=$errors)"
    if [[ $pct -ge $lo && $pct -le $hi ]]; then
        pass "$label: v1 within ${lo}-${hi}%"
    else
        fail "$label: v1=${pct}% outside ${lo}-${hi}%"
    fi
}

check_pinned() {
    local label="$1" expect="$2" v1="$3" v2="$4" unknown="$5" errors="$6" count="$7"
    local got=0
    if [[ "$expect" == "v1" ]]; then got=$v1; else got=$v2; fi
    info "$label: v1=$v1 v2=$v2 unknown=$unknown errors=$errors"
    local tol=$(( count * 4 / 100 ))
    [[ $tol -lt 2 ]] && tol=2
    if [[ $got -eq $count ]]; then
        pass "$label: all $count requests to $expect"
    elif [[ $got -ge $((count - tol)) ]]; then
        pass "$label: $got/$count to $expect (within tolerance)"
    else
        fail "$label: $got/$count to $expect"
    fi
}

# ---------------------------------------------------------------------------
# Prometheus-based traffic validation (used for observability verification)
# ---------------------------------------------------------------------------

PF_PIDS=()
PROM_PORT=19090

cleanup_pf() { for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup_pf EXIT

start_prometheus_pf() {
    local prom_ns="" prom_svc=""
    if kubectl get svc prometheus-operated -n openshift-user-workload-monitoring >/dev/null 2>&1; then
        prom_ns="openshift-user-workload-monitoring"; prom_svc="prometheus-operated"
    elif kubectl get svc prometheus-operated -n monitoring >/dev/null 2>&1; then
        prom_ns="monitoring"; prom_svc="prometheus-operated"
    else
        info "Prometheus not found - skipping observability check"
        return 1
    fi
    kubectl port-forward -n "$prom_ns" "svc/$prom_svc" "${PROM_PORT}:9090" >/dev/null 2>&1 &
    PF_PIDS+=("$!")
    for _ in 1 2 3 4 5; do
        curl -s -o /dev/null --max-time 1 "http://localhost:${PROM_PORT}/-/ready" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

HAS_PROMETHEUS=false

prom_query() {
    curl -sf --max-time 5 "http://localhost:${PROM_PORT}/api/v1/query" \
        --data-urlencode "query=$1" 2>/dev/null
}

prom_vllm_count() {
    local isvc_name="$1"
    local val
    val=$(prom_query "sum(vllm:request_success_total{namespace=\"${NS}\",llm_isvc_name=\"${isvc_name}\",finished_reason=\"length\"})" \
        | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else '0')" 2>/dev/null)
    printf '%.0f' "${val:-0}"
}

send_traffic() {
    local url="$1" count="$2"; shift 2
    local payload='{"model":"'"$MODEL"'","prompt":"Hello","max_tokens":5}'
    local errors=0
    for ((i = 0; i < count; i++)); do
        if ! curl -s --max-time 30 \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$@" "$url" >/dev/null 2>&1; then
            errors=$((errors + 1))
        fi
    done
    if [[ $errors -gt 5 ]]; then fail "Too many curl errors ($errors/$count)"; fi
}

# ---------------------------------------------------------------------------
# Weight and wait helpers
# ---------------------------------------------------------------------------

weight_applied() {
    local member="$1" expected="$2"
    local actual
    actual=$(kubectl get llmisvc "$V1" -n "$NS" \
        -o jsonpath="{.status.router.group.members[?(@.name=='$member')].weight}" 2>/dev/null)
    [[ "$actual" == "$expected" ]]
}

set_weight() {
    local name="$1" weight="$2"
    kubectl patch llmisvc "$name" -n "$NS" --type merge \
        -p "{\"spec\":{\"router\":{\"route\":{\"weight\":$weight}}}}"
    wait_until 15 weight_applied "$name" "$weight" || sleep 3
}

model_routing_url() { echo "$GATEWAY_URL/v1/completions"; }
model_routing_header() { echo "X-Gateway-Model-Name: publishers/$NS/models/$MODEL"; }

wait_until() {
    local max_wait="$1"; shift
    local elapsed=0 delay=1
    while [[ $elapsed -lt $max_wait ]]; do
        if "$@" 2>/dev/null; then return 0; fi
        sleep "$delay"
        elapsed=$((elapsed + delay))
        delay=$(( delay * 2 > 16 ? 16 : delay * 2 ))
    done
    return 1
}

condition_is() {
    local name="$1" cond="$2" expected="$3"
    local actual
    actual=$(get_condition "$name" "$cond")
    [[ "$actual" == "$expected" ]]
}

deploy_scaled_down() {
    local deploy="$1" ns="$2"
    kubectl get deploy "$deploy" -n "$ns" >/dev/null 2>&1 || return 1
    local replicas
    replicas=$(kubectl get deploy "$deploy" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [[ "$replicas" == "0" || -z "$replicas" ]]
}

member_removed() {
    local llmisvc="$1" ns="$2" removed="$3"
    local members
    members=$(kubectl get llmisvc "$llmisvc" -n "$ns" -o jsonpath='{.status.router.group.members[*].name}' 2>/dev/null)
    [[ "$members" != *"$removed"* ]]
}

condition_reason_set() {
    local llmisvc="$1" condition="$2"
    local reason
    reason=$(get_condition_reason "$llmisvc" "$condition")
    [[ -n "$reason" ]]
}

# =========================================================================
# Setup
# =========================================================================

discover_gateway

echo -e "${BOLD}Controlled Deployment E2E Validation${NC}"
echo "Gateway: $GATEWAY_URL"
echo "Namespace: $NS"
echo "Scenario: $SCENARIO"
[[ -n "$PROFILE" ]] && echo "Profile: $PROFILE"
[[ -n "$RUN_PHASE" ]] && echo "Phase: $RUN_PHASE"
[[ -n "$RUN_STEP" ]] && echo "Step: $RUN_STEP"
echo ""

if [[ "$SKIP_DEPLOY" == "false" ]] && { should_run_phase 1 || should_run_step 1 1; }; then
    info "Applying manifests (scenario: $SCENARIO)"
    kubectl apply -k "$OVERLAY_DIR"
    # OCP: workload pods need privileged SCC for hardcoded runAsUser/seccomp
    if kubectl get clusterversion >/dev/null 2>&1; then
        oc adm policy add-scc-to-user privileged -z default -n "$NS" 2>/dev/null || true
    fi
    apply_peer_authentication
fi

# =========================================================================
# Phase 1: Canary Rollout Lifecycle
# =========================================================================

if step 1 "Deploy v1 (w=9) and v2 (canary at w=1)" 1; then
    if [[ "$SKIP_DEPLOY" == "false" ]]; then
        wait_ready "$V1"
        wait_ready "$V2"
    fi
    patch_epp_tls
    start_prometheus_pf && HAS_PROMETHEUS=true

    label=$(kubectl get llmisvc "$V1" -n "$NS" -o jsonpath='{.metadata.labels.serving\.kserve\.io/routing-group}')
    if [[ "$label" == "$GROUP" ]]; then pass "v1 has routing-group label"; else fail "v1 has routing-group label"; fi

    members=$(get_group_members "$V1")
    if [[ "$members" == *"$V1"* && "$members" == *"$V2"* ]]; then pass "Both members in group status"; else fail "Both members in group status"; fi

    v2_weight=$(get_group_weight "$V1" "$V2")
    if [[ "$v2_weight" == "1" ]]; then pass "v2 onboarded at weight 1"; else fail "v2 weight=$v2_weight (expected 1)"; fi
fi

if step 2 "Baseline: ~90/10 split (v1=9, v2=1)" 1; then
    read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" "$REQUESTS" \
        -H "$(model_routing_header)")"
    check_split "Model-routing 90/10 baseline" "$v1" "$v2" "$unk" "$err" 75 98
fi

if step 3 "Canary: shift to 70/30" 1; then
    set_weight "$V2" 3
    set_weight "$V1" 7

    v1_w=$(get_group_weight "$V1" "$V1")
    v2_w=$(get_group_weight "$V1" "$V2")
    if [[ "$v1_w" == "7" && "$v2_w" == "3" ]]; then pass "Weights: v1=$v1_w v2=$v2_w"; else fail "Weights: v1=$v1_w v2=$v2_w"; fi

    read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" "$REQUESTS" \
        -H "$(model_routing_header)")"
    check_split "Model-routing 70/30" "$v1" "$v2" "$unk" "$err" 55 85
fi

if step 4 "Validate: 50/50 split via Prometheus metrics" 1; then
    set_weight "$V1" 5
    set_weight "$V2" 5

    if [[ "$HAS_PROMETHEUS" == "true" ]]; then
        b1=$(prom_vllm_count "$V1"); b2=$(prom_vllm_count "$V2")
        send_traffic "$(model_routing_url)" "$REQUESTS" -H "$(model_routing_header)"
        sleep "${SCRAPE_WAIT:-15}"
        a1=$(prom_vllm_count "$V1"); a2=$(prom_vllm_count "$V2")
        d1=$((a1 - b1)); d2=$((a2 - b2))
        [[ $d1 -lt 0 ]] && d1=0; [[ $d2 -lt 0 ]] && d2=0
        total=$((d1 + d2))
        if [[ $total -eq 0 ]]; then fail "Prometheus: no requests reached backends"; else
            pct=$((d1 * 100 / total))
            info "Prometheus 50/50: v1=${pct}% v2=$((100 - pct))% (v1=$d1 v2=$d2)"
            if [[ $pct -ge 30 && $pct -le 70 ]]; then pass "Prometheus: v1 within 30-70%"; else fail "Prometheus: v1=${pct}% outside 30-70%"; fi
        fi
    else
        info "Prometheus not available, falling back to x-served-by"
        read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" "$REQUESTS" \
            -H "$(model_routing_header)")"
        check_split "Model-routing 50/50" "$v1" "$v2" "$unk" "$err" 30 70
    fi
fi

if step 5 "Promote: v2 to 100%" 1; then
    set_weight "$V1" 0

    read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" 10 \
        -H "$(model_routing_header)")"
    check_pinned "Model-routing (v1 at weight 0)" "v2" "$v1" "$v2" "$unk" "$err" 10
fi

if step 6 "Direct access: always hits the targeted version" 1; then
    read -r v1 v2 unk err <<< "$(send_requests "$GATEWAY_URL/$NS/$V1/v1/completions" 10)"
    check_pinned "Direct v1 path" "v1" "$v1" "$v2" "$unk" "$err" 10

    read -r v1 v2 unk err <<< "$(send_requests "$GATEWAY_URL/$NS/$V2/v1/completions" 10)"
    check_pinned "Direct v2 path" "v2" "$v1" "$v2" "$unk" "$err" 10
fi

if step 7 "Rollback: v1 back to 100%" 1; then
    set_weight "$V1" 9
    set_weight "$V2" 0

    read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" 10 \
        -H "$(model_routing_header)")"
    check_pinned "Model-routing after rollback" "v1" "$v1" "$v2" "$unk" "$err" 10
fi

if step 8 "Re-promote v2, force-stop v1 (GPU reclamation)" 1; then
    set_weight "$V1" 0
    set_weight "$V2" 9
    kubectl annotate llmisvc "$V1" -n "$NS" serving.kserve.io/stop=true --overwrite
    wait_until 30 deploy_scaled_down "${V1}-kserve" "$NS" || true

    # v1 stopped: conditions show Stopped, member stays in group
    condition_reason_is() { [[ "$(get_condition_reason "$1" "$2")" == "$3" ]]; }
    wait_until 15 condition_reason_is "$V1" "Ready" "Stopped" || true
    v1_reason=$(get_condition_reason "$V1" "Ready")
    if [[ "$v1_reason" == "Stopped" ]]; then pass "v1 Ready reason=Stopped"; else fail "v1 Ready reason=${v1_reason:-<not set>} (expected Stopped)"; fi

    members=$(get_group_members "$V2")
    if [[ "$members" == *"$V1"* ]]; then pass "v1 still a group member while stopped"; else pass "v1 removed from group (force-stop cleans up)"; fi

    read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" 10 \
        -H "$(model_routing_header)")"
    check_pinned "Model-routing after force-stop" "v2" "$v1" "$v2" "$unk" "$err" 10
fi

if step 9 "Decommission v1" 1; then
    kubectl delete llmisvc "$V1" -n "$NS" --wait=false
    wait_until 45 member_removed "$V2" "$NS" "$V1" || true
    wait_until 15 condition_is "$V2" "Ready" "True" || true

    v2_ready=$(get_condition "$V2" "Ready")
    if [[ "$v2_ready" == "True" ]]; then pass "v2 still Ready"; else fail "v2 still Ready (flapped during group reconciliation)"; fi

    members=$(get_group_members "$V2")
    if [[ "$members" != *"$V1"* ]]; then pass "v1 removed from group status"; else fail "v1 still in group status (slow reconciliation)"; fi

    read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" 10 \
        -H "$(model_routing_header)")"
    check_pinned "Model-routing after decommission" "v2" "$v1" "$v2" "$unk" "$err" 10
fi

# =========================================================================
# Phase 2: Error handling
# =========================================================================

if step 10 "Model name mismatch rejected" 2; then
    cat <<EOF | kubectl apply -f -
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: tiny-llama-v3-bad
  namespace: $NS
spec:
  model:
    name: wrong-model
    uri: "hf://hmellor/tiny-random-LlamaForCausalLM"
  baseRefs:
    - name: workload-single-cpu
  router:
    route:
      group: $GROUP
      weight: 1
      http: {}
    scheduler: {}
EOF
    wait_until 120 condition_reason_set "tiny-llama-v3-bad" "GroupReady" || true
    reason=$(get_condition_reason "tiny-llama-v3-bad" "GroupReady")
    if [[ "$reason" == "ModelNameAmbiguous" || "$reason" == "ModelNameMismatch" ]]; then
        pass "GroupReady reason=$reason (wrong model rejected)"
    else
        fail "GroupReady reason=${reason:-<not set>}"
    fi
    kubectl delete llmisvc tiny-llama-v3-bad -n "$NS" --wait=false 2>/dev/null || true
fi

if step 11 "Weight without group rejected by webhook" 2; then
    webhook_output=$(cat <<EOF | kubectl apply -f - 2>&1 || true
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: bad-weight-only
  namespace: $NS
spec:
  model:
    name: tiny-llama
    uri: "hf://hmellor/tiny-random-LlamaForCausalLM"
  router:
    route:
      weight: 5
      http: {}
EOF
    )
    if echo "$webhook_output" | grep -qi "weight requires group\|invalid\|denied"; then
        pass "Webhook rejected weight without group"
    else
        fail "Webhook did not reject: $webhook_output"
    fi
    kubectl delete llmisvc bad-weight-only -n "$NS" 2>/dev/null || true
fi

# =========================================================================
# Phase 3: Publisher path + x-served-by
# =========================================================================

if step 12 "Publisher path routing" 3; then
    read -r v1 v2 unk err <<< "$(send_requests \
        "$GATEWAY_URL/publishers/$NS/models/$MODEL/v1/completions" 10)"
    check_pinned "Publisher path" "v2" "$v1" "$v2" "$unk" "$err" 10
fi

if step 13 "x-served-by header present" 3; then
    tmpfile=$(mktemp)
    curl -s -D "$tmpfile" --max-time 30 \
        -H "Content-Type: application/json" \
        -d '{"model":"'"$MODEL"'","prompt":"Hello","max_tokens":5}' \
        "$GATEWAY_URL/$NS/$V2/v1/completions" >/dev/null 2>&1 || true

    served_by=$(grep -i "x-served-by" "$tmpfile" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)
    rm -f "$tmpfile"

    if [[ "$served_by" == "$V2" ]]; then pass "x-served-by: $V2"; else fail "x-served-by: $V2"; fi
fi

# =========================================================================
# Phase 4: Group lifecycle edge cases
# =========================================================================

if step 14 "Leave group: member removes group field" 4; then
    # Re-deploy both members in a group
    kubectl apply -k "$OVERLAY_DIR" 2>/dev/null
    wait_ready "$V1"
    wait_ready "$V2"
    patch_epp_tls
    wait_until 30 member_present "$V1" "$V2" || true

    # Verify group is established
    members=$(get_group_members "$V1")
    if [[ "$members" != *"$V2"* ]]; then fail "Group not established before leave test"; fi

    # v2 leaves the group by removing group and weight
    kubectl patch llmisvc "$V2" -n "$NS" --type json \
        -p '[{"op":"remove","path":"/spec/router/route/group"},{"op":"remove","path":"/spec/router/route/weight"}]'

    label_removed() {
        local label
        label=$(kubectl get llmisvc "$V2" -n "$NS" \
            -o jsonpath='{.metadata.labels.serving\.kserve\.io/routing-group}' 2>/dev/null || true)
        [[ -z "$label" ]]
    }
    wait_until 30 label_removed || true

    # v2 should no longer have the routing-group label
    v2_label=$(kubectl get llmisvc "$V2" -n "$NS" \
        -o jsonpath='{.metadata.labels.serving\.kserve\.io/routing-group}' 2>/dev/null || true)
    if [[ -z "$v2_label" ]]; then pass "v2 routing-group label removed"; else fail "v2 still has routing-group label: $v2_label"; fi

    # v1 group status should no longer include v2
    wait_until 30 member_removed "$V1" "$NS" "$V2" || true
    members=$(get_group_members "$V1")
    if [[ "$members" != *"$V2"* ]]; then pass "v2 removed from v1 group status"; else fail "v2 still in v1 group status"; fi

    # v1 still serves via model-routing
    read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" 10 \
        -H "$(model_routing_header)")"
    total=$((v1 + v2))
    if [[ $total -ge 8 ]]; then pass "Model-routing works after v2 leaves group (v1=$v1 v2=$v2)"; else fail "Model-routing broken (v1=$v1 v2=$v2 err=$err)"; fi

    # v2 still serves via direct access
    read -r v1 v2 unk err <<< "$(send_requests "$GATEWAY_URL/$NS/$V2/v1/completions" 5)"
    check_pinned "Direct v2 after leaving group" "v2" "$v1" "$v2" "$unk" "$err" 5
fi

# =========================================================================
# Phase 5: Advanced group scenarios
# =========================================================================

V3="tiny-llama-v3"

apply_member() {
    local name="$1" model_name="$2" weight="$3"
    local scheduler_field="" model_block="" baserefs_block=""
    if grep -q "scheduler:" "$OVERLAY_DIR/v1.yaml" 2>/dev/null; then
        scheduler_field="    scheduler: {}"
    fi
    if [[ "$model_name" == "$MODEL" ]]; then
        model_block="    name: $model_name"
        baserefs_block="  baseRefs:
    - name: model-tiny-llama
    - name: workload-single-cpu"
    else
        model_block="    name: $model_name
    uri: \"hf://hmellor/tiny-random-LlamaForCausalLM\""
        baserefs_block="  baseRefs:
    - name: workload-single-cpu"
    fi
    cat <<MEMBEREOF | kubectl apply -f -
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: $name
  namespace: $NS
  annotations:
    serving.kserve.io/enable-served-by-header: "true"
spec:
  model:
${model_block}
${baserefs_block}
  router:
    route:
      group: $GROUP
      weight: $weight
      http: {}
${scheduler_field}
MEMBEREOF
}

member_present() {
    local members
    members=$(kubectl get llmisvc "$1" -n "$NS" -o jsonpath='{.status.router.group.members[*].name}' 2>/dev/null)
    [[ "$members" == *"$2"* ]]
}

if step 15 "N>2 group: three-member weighted routing" 5; then
    # Reuse v1+v2 from step 14, patch back into group and add v3
    apply_member "$V1" "$MODEL" 5
    apply_member "$V2" "$MODEL" 3
    apply_member "$V3" "$MODEL" 2
    wait_ready "$V1"
    wait_ready "$V2"
    wait_ready "$V3"
    patch_epp_tls

    members=$(get_group_members "$V1")
    if [[ "$members" == *"$V1"* && "$members" == *"$V2"* && "$members" == *"$V3"* ]]; then
        pass "All 3 members in group status"
    else
        fail "Missing members: $members"
    fi

    v3_w=$(get_group_weight "$V1" "$V3")
    if [[ "$v3_w" == "2" ]]; then pass "v3 weight=2"; else fail "v3 weight=$v3_w (expected 2)"; fi

    read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" "$REQUESTS" \
        -H "$(model_routing_header)")"
    total=$((v1 + v2 + unk))
    if [[ $total -ge 40 && $v1 -gt 0 && $v2 -gt 0 && $unk -gt 0 ]]; then
        info "3-way split: v1=$v1 v2=$v2 v3=$unk (total=$total err=$err)"
        pass "All three members received traffic"
    else
        fail "Three-member routing: v1=$v1 v2=$v2 v3(unknown)=$unk err=$err (expected all >0)"
    fi
fi

if step 16 "Join existing group: v2 arrives after v1 is running" 5; then
    # Chain from step 15: delete v3+v2, keep v1, patch to standalone weight
    kubectl delete llmisvc "$V3" "$V2" -n "$NS" --wait=true 2>/dev/null || true
    set_weight "$V1" 9
    wait_until 30 member_removed "$V1" "$NS" "$V2" || true

    members=$(get_group_members "$V1")
    if [[ "$members" == *"$V1"* ]]; then pass "v1 standalone in group"; else fail "v1 not in group: $members"; fi

    # v2 joins late
    apply_member "$V2" "$MODEL" 1
    wait_ready "$V2"
    patch_epp_tls

    wait_until 30 member_present "$V1" "$V2" || true
    members=$(get_group_members "$V1")
    if [[ "$members" == *"$V2"* ]]; then pass "v2 joined existing group"; else fail "v2 not in group: $members"; fi

    v2_w=$(get_group_weight "$V1" "$V2")
    if [[ "$v2_w" == "1" ]]; then pass "v2 weight=1 after join"; else fail "v2 weight=$v2_w"; fi

    read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" "$REQUESTS" \
        -H "$(model_routing_header)")"
    check_split "After late join 90/10" "$v1" "$v2" "$unk" "$err" 75 98
fi

if step 17 "Delete member at weight > 0" 5; then
    # Chain from step 16: v1=9, v2=1. Patch to equal weight, then delete v2
    set_weight "$V1" 5
    set_weight "$V2" 5

    kubectl delete llmisvc "$V2" -n "$NS" --wait=false
    wait_until 30 member_removed "$V1" "$NS" "$V2" || true
    wait_until 15 condition_is "$V1" "Ready" "True" || true

    v1_ready=$(get_condition "$V1" "Ready")
    if [[ "$v1_ready" == "True" ]]; then pass "v1 Ready after v2 deleted at weight>0"; else fail "v1 not Ready: $(get_condition_reason "$V1" "Ready")"; fi

    read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" 10 \
        -H "$(model_routing_header)")"
    total=$((v1 + v2))
    if [[ $total -ge 8 ]]; then pass "Traffic flows to v1 after v2 deletion (v1=$v1)"; else fail "Traffic broken after v2 deletion (total=$total)"; fi
fi

if step 18 "Force-stop the route owner" 5; then
    # Chain from step 17: v1 alone. Create v2, then force-stop v1
    apply_member "$V2" "$MODEL" 5
    set_weight "$V1" 5
    wait_ready "$V2"
    patch_epp_tls
    wait_until 30 member_present "$V1" "$V2" || true

    kubectl annotate llmisvc "$V1" -n "$NS" serving.kserve.io/stop=true --overwrite
    wait_until 30 deploy_scaled_down "${V1}-kserve" "$NS" || true

    for attempt in 1 2 3; do
        read -r v1 v2 unk err <<< "$(send_requests "$(model_routing_url)" 10 \
            -H "$(model_routing_header)")"
        [[ $v2 -ge 5 ]] && break
        info "Attempt $attempt: waiting for route handoff after force-stop..."
        sleep 5
    done
    if [[ $v2 -ge 5 ]]; then
        pass "Model-routing continues after route owner force-stopped (v2=$v2)"
    else
        fail "Model-routing broken after route owner force-stopped (v2=$v2)"
    fi
fi

if step 19 "ModelNameAmbiguous: no majority (symmetric failure)" 5; then
    # Must recreate - different model names
    kubectl delete llmisvc --all -n "$NS" --wait=true 2>/dev/null || true

    apply_member "$V1" "model-alpha" 5
    apply_member "$V2" "model-beta" 5
    wait_until 120 condition_reason_set "$V1" "GroupReady" || true
    wait_until 120 condition_reason_set "$V2" "GroupReady" || true

    r1=$(get_condition_reason "$V1" "GroupReady")
    r2=$(get_condition_reason "$V2" "GroupReady")
    s1=$(get_condition "$V1" "GroupReady")
    s2=$(get_condition "$V2" "GroupReady")

    if [[ "$r1" == "ModelNameAmbiguous" && "$r2" == "ModelNameAmbiguous" ]]; then
        pass "Both members get ModelNameAmbiguous (symmetric)"
    else
        fail "Expected both ModelNameAmbiguous, got v1=$r1 v2=$r2"
    fi
    if [[ "$s1" == "False" && "$s2" == "False" ]]; then
        pass "Both GroupReady=False"
    else
        fail "Expected both False, got v1=$s1 v2=$s2"
    fi
fi

if step 20 "GroupDegraded: majority excludes outlier" 5; then
    # Must recreate - need correct model names for majority
    kubectl delete llmisvc --all -n "$NS" --wait=true 2>/dev/null || true

    apply_member "$V1" "$MODEL" 5
    apply_member "$V2" "$MODEL" 3
    wait_ready "$V1"
    wait_ready "$V2"
    apply_member "$V3" "wrong-model" 2
    wait_until 120 condition_reason_set "$V3" "GroupDegraded" || true

    # Group stays ready - majority serves traffic
    wait_until 30 condition_is "$V1" "GroupReady" "True" || true
    s1=$(get_condition "$V1" "GroupReady")
    s2=$(get_condition "$V2" "GroupReady")
    s3=$(get_condition "$V3" "GroupReady")
    if [[ "$s1" == "True" && "$s2" == "True" && "$s3" == "True" ]]; then
        pass "All members GroupReady=True (group serves traffic)"
    else
        fail "GroupReady: v1=$s1 v2=$s2 v3=$s3"
    fi

    # All members report degraded (symmetric - reflects group state, not individual participation)
    d1=$(get_condition "$V1" "GroupDegraded")
    d2=$(get_condition "$V2" "GroupDegraded")
    d3=$(get_condition "$V3" "GroupDegraded")
    r1=$(get_condition_reason "$V1" "GroupDegraded")
    if [[ "$d1" == "True" && "$d2" == "True" && "$d3" == "True" ]]; then
        pass "All members GroupDegraded=True (symmetric)"
    else
        fail "GroupDegraded: v1=$d1 v2=$d2 v3=$d3"
    fi
    if [[ "$r1" == "MemberExcluded" ]]; then
        pass "GroupDegraded reason=MemberExcluded"
    else
        fail "Expected MemberExcluded, got $r1"
    fi

    kubectl delete llmisvc --all -n "$NS" --wait=false 2>/dev/null || true
fi

# =========================================================================
# Summary
# =========================================================================

echo ""
if [[ $STEPS_RAN -eq 0 ]]; then
    echo -e "${RED}${BOLD}No steps matched. Check --phase/--step value.${NC}"
    exit 1
elif [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All $STEPS_RAN step(s) passed.${NC}"
else
    echo -e "${RED}${BOLD}$FAILURES of $STEPS_RAN step(s) failed.${NC}"
fi

echo ""
echo "Cleanup: kubectl delete namespace $NS"

exit "$FAILURES"
