#!/usr/bin/env bash
# Scores the live gateway against the scenarios below. Evidence is captured to
# results/<slug>/<scenario>/ first and scored out of process by score.py, so a
# run can be re-scored by hand.
#
# Usage:
#   ./validate.sh --scenario defect      # EPP bypassed: diagnostic BROKEN, picker never called, round robin
#   ./validate.sh --scenario fix         # apply fix.sh, EPP called for every request, revert
#   ./validate.sh --scenario auth-order  # with the fix, unauthenticated requests still reach the EPP
#   ./validate.sh --scenario control     # Kuadrant 1.4.x cluster: EPP called without any fix
#   ./validate.sh --scenario all         # defect, fix, auth-order
#   flags: --smoke (5 requests, no distribution check) --requests N --keep-fix
#
# Exit code is the number of failed checks.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
STATUS_ON_ERR=1
trap on_error ERR

SCENARIOS=()
SMOKE=0
KEEP_FIX=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario) SCENARIOS+=("$2"); shift ;;
        --smoke) SMOKE=1; REQUESTS=5 ;;
        --requests) REQUESTS="$2"; shift ;;
        --keep-fix) KEEP_FIX=1 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) err "unknown flag: $1" ;;
    esac
    shift
done
[[ ${#SCENARIOS[@]} -gt 0 ]] || SCENARIOS=(defect)
if [[ " ${SCENARIOS[*]} " == *" all "* ]]; then SCENARIOS=(defect fix auth-order); fi

mkdir -p "$RESULTS"

TOTAL_FAILURES=0
HEADLINES=()

main() {
header "Preflight"
kc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1 || err "gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME} not found (KUBECONFIG=$KUBECONFIG)"
pod="$(gateway_pod)"
[[ -n "$pod" ]] || err "no Running+Ready gateway pod"
img="$(gateway_pod_image)"
[[ "$img" == *":${ISTIO_VERSION}" ]] || err "gateway pod runs ${img}, results would be stamped istio-${ISTIO_VERSION}"
ok "gateway pod ${pod} on ${img##*/}"
kc wait llmisvc "$LLMISVC_NAME" -n "$NS" --for=condition=Ready --timeout=30s >/dev/null 2>&1 || err "llmisvc ${NS}/${LLMISVC_NAME} not Ready"
[[ -n "$(epp_pod)" ]] || err "no EPP pod for ${NS}/${LLMISVC_NAME}"
GW_URL="$(gateway_url)"
[[ -n "$GW_URL" ]] || err "gateway has no address"
API_KEY="$(maas_api_key epp-spike-validate)"
[[ -n "$API_KEY" ]] || err "could not mint a MaaS API key"
# A fix left behind by an aborted run would make the defect scenario score a
# fixed chain; every run starts from the controller-rendered state.
if kc get envoyfilter "$FIX_EF_NAME" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1 \
   && [[ " ${SCENARIOS[*]} " == *" defect "* || " ${SCENARIOS[*]} " == *" control "* ]]; then
    warn "leftover ${FIX_EF_NAME} from a previous run; reverting before scoring"
    "$SCRIPT_DIR/fix.sh" revert
fi
ok "gateway ${GW_URL}, model ${MODEL_ID}, ${REQUESTS} requests per scenario"

# Sends REQUESTS body-routed chat completions. with_auth=0 sends none of the
# credentials, for the auth-order scenario.
send_requests() {
    local scenario="$1" with_auth="$2" dir="$3" i code hdrs body ipod model
    local -a auth_args=()
    [[ "$with_auth" == 1 ]] && auth_args=(-H "Authorization: Bearer ${API_KEY}")
    hdrs="$(mktemp)"; body="$(mktemp)"
    : > "$dir/traffic.tsv"
    for i in $(seq 1 "$REQUESTS"); do
        code=$(curl -s -o "$body" -D "$hdrs" -w '%{http_code}' --max-time 30 \
            "${GW_URL}/v1/chat/completions" \
            -H "Content-Type: application/json" -H "x-req-id: ${scenario}-${i}" \
            "${auth_args[@]}" \
            -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"epp ${scenario} ${i}\"}],\"max_tokens\":5}" \
            || echo "000")
        # A failed request has neither header nor JSON body; record it, do not die.
        ipod=$( { grep -i '^x-inference-pod:' "$hdrs" || true; } | awk '{print $2}' | tr -d '\r')
        model=$(jq -r '.model // empty' "$body" 2>/dev/null || true)
        printf '%s\t%s\t%s\t%s\n' "$i" "$code" "${ipod:--}" "${model:--}" >> "$dir/traffic.tsv"
    done
    rm -f "$hdrs" "$body"
}

# Captures the state every scenario is scored against, before traffic.
capture_state() {
    local dir="$1"
    capture "config_dump" "$dir/config_dump.json" || err "empty config_dump capture"
    "$SCRIPT_DIR/scripts/check-filter-order.sh" > "$dir/diag.txt" 2>&1 || true
    "$SCRIPT_DIR/scripts/check-filter-order.sh" --json > "$dir/diag.json" 2>/dev/null || true
    [[ -s "$dir/diag.json" ]] || err "diagnostic produced no JSON"
    # Line-oriented views of the dump, the way the sandbox spike keeps them,
    # so a surprising verdict can be traced without re-reading the JSON.
    jq -r '.chain | to_entries[] | "\(.key + 1)\t\(.value)"' "$dir/diag.json" > "$dir/filters.tsv"
    jq -r '.routes[] | [.name, (.path // "-"), (.header // "-"), (.clusters | join(",")), (.picker // "-"), (.ipp_pre_disabled|tostring), (.ipp_disabled|tostring)] | @tsv' \
        "$dir/diag.json" > "$dir/routes.tsv"
    envoy_admin "clusters?format=json" 2>/dev/null | jq -r '
        .cluster_statuses[]? | select(.name | test("inference-pool|epp-service|payload-")) |
        [.name, ([.host_statuses[]? | .address.socket_address.address + ":" + (.address.socket_address.port_value|tostring) + "/" + (.health_status.eds_health_status // "?")] | join(","))] | @tsv' \
        > "$dir/clusters.tsv" 2>/dev/null || true
    kc get envoyfilter -n "$GATEWAY_NAMESPACE" -o yaml > "$dir/envoyfilters.yaml" 2>/dev/null || true
    kc get httproute -n "$NS" -o yaml > "$dir/httproutes.yaml" 2>/dev/null || true
    kc get inferencepool -n "$NS" -o yaml > "$dir/inferencepools.yaml" 2>/dev/null || true
    # The scheduler config the EPP runs with (scorers and weights), from the
    # --config-text argument KServe hands it.
    kc get deploy "${LLMISVC_NAME}-kserve-router-scheduler" -n "$NS" -o json 2>/dev/null \
        | jq -r '.spec.template.spec.containers[] | select(.name=="main") | .args as $a | ($a | index("--config-text")) as $i | if $i then $a[$i+1] else ($a[] | select(startswith("--config-text=")) | sub("^--config-text=";"")) end' \
        > "$dir/epp-config.yaml" 2>/dev/null || true
}

# A burst of same-prefix requests, CONCURRENCY at a time. Same long prefix,
# different tail, enough output tokens for vLLM to hold KV cache for a moment.
# An engaged EPP with the prefix-cache scorer pins these to one pod; Envoy's
# round robin spreads them.
send_prefix_burst() {
    local scenario="$1" dir="$2" n="${PREFIX_REQUESTS:-12}" conc="${PREFIX_CONCURRENCY:-6}" i
    local prefix
    prefix="$(printf 'The quick brown fox jumps over the lazy dog near the river bank while the sun sets slowly behind the hills. %.0s' {1..8})"
    : > "$dir/traffic-prefix.tsv"
    one() {
        local i="$1" hdrs body code ipod
        hdrs="$(mktemp)"; body="$(mktemp)"
        code=$(curl -s -o "$body" -D "$hdrs" -w '%{http_code}' --max-time 120 \
            "${GW_URL}/v1/chat/completions" \
            -H "Content-Type: application/json" -H "x-req-id: ${scenario}-prefix-${i}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"${prefix} Question ${i}: continue.\"}],\"max_tokens\":32}" \
            || echo "000")
        ipod=$( { grep -i '^x-inference-pod:' "$hdrs" || true; } | awk '{print $2}' | tr -d '\r')
        printf '%s\t%s\t%s\n' "$i" "$code" "${ipod:--}" >> "$dir/traffic-prefix.tsv"
        rm -f "$hdrs" "$body"
    }
    for i in $(seq 1 "$n"); do
        one "$i" &
        if (( i % conc == 0 )); then wait; fi
    done
    wait
}

collect_access_log() {
    local scenario="$1" dir="$2" since="$3"
    sleep 3
    kc logs -n "$GATEWAY_NAMESPACE" "$(gateway_pod)" -c istio-proxy --since-time="$since" 2>/dev/null \
        > "$dir/access-all.jsonl" || true
    grep "\"req_id\":\"${scenario}-[0-9]" "$dir/access-all.jsonl" > "$dir/access.jsonl" || true
    grep "\"req_id\":\"${scenario}-prefix-" "$dir/access-all.jsonl" > "$dir/access-prefix.jsonl" || true
    rm -f "$dir/access-all.jsonl"
}

run_scenario() {
    local scenario="$1" with_auth="$2" since dir epp
    dir="$RESULTS/$scenario"
    header "Scenario: ${scenario}"
    rm -rf "$dir"; mkdir -p "$dir"
    capture_state "$dir"
    substep "chain: $(jq -r '.verdicts.EPP_ENGAGED' "$dir/diag.json") (auth via $(jq -r '.auth_mechanism' "$dir/diag.json"), MaaS EF mode $(jq -r '.maas_ef.mode' "$dir/diag.json"))"
    epp=$(epp_scrape "$dir/epp-before.prom") || err "EPP scrape (before) failed"
    vllm_scrape_all "$dir" before
    substep "EPP ${epp} and $(model_pods | wc -w) model pods scraped before traffic"
    since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sleep 1
    send_requests "$scenario" "$with_auth" "$dir"
    substep "sent ${REQUESTS} requests: $(cut -f2 "$dir/traffic.tsv" | sort | uniq -c | awk '{printf "%s x%s ", $2, $1}')"
    vllm_scrape_all "$dir" after
    if [[ "$with_auth" == 1 ]]; then
        vllm_scrape_all "$dir" prefix-before
        send_prefix_burst "$scenario" "$dir"
        vllm_scrape_all "$dir" prefix-after
        substep "same-prefix burst: $(cut -f2 "$dir/traffic-prefix.tsv" | sort | uniq -c | awk '{printf "%s x%s ", $2, $1}')"
    fi
    # After the burst, so the picker delta covers every request of the scenario.
    epp=$(epp_scrape "$dir/epp-after.prom") || err "EPP scrape (after) failed"
    collect_access_log "$scenario" "$dir" "$since"
    kc logs -n "$NS" "$epp" --since-time="$since" > "$dir/epp.log" 2>/dev/null || true
    substep "access log lines: $(wc -l < "$dir/access.jsonl"); EPP log lines: $(wc -l < "$dir/epp.log")"
    # score.py exits with its failure count; `|| rc=$?` keeps that out of the
    # ERR trap and out of set -e.
    local rc=0
    local -a smoke_flag=()
    [[ $SMOKE == 1 ]] && smoke_flag=(--smoke)
    python3 "$SCRIPT_DIR/score.py" "$scenario" "$dir" --requests "$REQUESTS" \
        --model-id "$MODEL_ID" --route-prefix "${NS}.${LLMISVC_NAME}-kserve-route." \
        "${smoke_flag[@]}" > "$dir/score.txt" 2>&1 || rc=$?
    cat "$dir/score.txt"
    TOTAL_FAILURES=$(( TOTAL_FAILURES + rc ))
    HEADLINES+=("$(cat "$dir/headline" 2>/dev/null || echo "${scenario}: no headline")")
}

fix_applied() { [[ "$(chain_verdict || true)" == "OK" ]]; }

for s in "${SCENARIOS[@]}"; do
    case "$s" in
        defect)
            run_scenario defect 1
            ;;
        control)
            run_scenario control 1
            ;;
        fix)
            "$SCRIPT_DIR/fix.sh" apply
            run_scenario fix 1
            if [[ $KEEP_FIX == 0 ]]; then "$SCRIPT_DIR/fix.sh" revert; fi
            ;;
        auth-order)
            applied_here=0
            if ! fix_applied; then "$SCRIPT_DIR/fix.sh" apply; applied_here=1; fi
            run_scenario auth-order 0
            if [[ $applied_here == 1 && $KEEP_FIX == 0 ]]; then "$SCRIPT_DIR/fix.sh" revert; fi
            ;;
        *) err "unknown scenario: $s" ;;
    esac
done

header "Summary ($(results_slug))"
i=0
for h in "${HEADLINES[@]}"; do i=$((i+1)); echo "  ${i}. ${h}"; done
if [[ $TOTAL_FAILURES -eq 0 ]]; then
    ok "all checks passed"
else
    fail "${TOTAL_FAILURES} check(s) failed"
fi
return "$TOTAL_FAILURES"
}

# Everything printed also lands in validate.out, ANSI stripped. A pipeline
# rather than `exec > >(tee)`: the process substitution can lose the last
# lines when the script exits right after printing them.
# A non-zero failure count is a result, not a harness error: no trap here.
trap - ERR
set +e
main "$@" 2>&1 | tee >(sed 's/\x1b\[[0-9;]*m//g' > "$RESULTS/validate.out")
rc="${PIPESTATUS[0]}"
sleep 0.2
exit "$rc"
