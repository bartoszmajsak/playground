#!/usr/bin/env bash
# Per-Participant Routes Validation Script
#
# Each participant has ONE HTTPRoute with three rule types:
#   1. Header match (weighted, overlapping) - gateway picks oldest
#   2. Publisher path (weighted, overlapping) - gateway picks oldest
#   3. Direct access path (pinned, non-overlapping) - both routes active
#
# Tests validate all three access patterns, failover, and independence.
#
# Usage:
#   ./validate.sh [GATEWAY_URL]

set -euo pipefail

NS="${ROUTE_VALIDATION_NS:-route-validation}"
REQUESTS="${ROUTE_VALIDATION_REQUESTS:-100}"
SETTLE="${ROUTE_VALIDATION_SETTLE:-16}"
VERBOSE="${ROUTE_VALIDATION_VERBOSE:-false}"
MODEL_HEADER="X-Gateway-Model-Name"
MODEL_VALUE="publishers/route-validation/models/test-model"
PUBLISHER_PATH="/publishers/route-validation/models/test-model"
SPLIT_90_MIN="${ROUTE_VALIDATION_SPLIT_90_MIN:-82}"
SPLIT_90_MAX="${ROUTE_VALIDATION_SPLIT_90_MAX:-97}"
SPLIT_50_MIN="${ROUTE_VALIDATION_SPLIT_50_MIN:-35}"
SPLIT_50_MAX="${ROUTE_VALIDATION_SPLIT_50_MAX:-65}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "  ${CYAN}INFO${NC}: $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC}: $1"; }
header() { echo -e "\n${BOLD}$1${NC}"; }

FAILURES=0

send_requests() {
    local url="$1" count="$2"; shift 2
    local v1=0 v2=0 errors=0

    # Sample first request with full headers for provenance
    local tmpfile
    tmpfile=$(mktemp)
    local body status
    body=$(curl -s -D "$tmpfile" --max-time 5 "$@" "$url" 2>/dev/null || echo "ERROR")
    status=$(head -1 "$tmpfile" 2>/dev/null | awk '{print $2}')
    local route_header upstream_svc
    route_header=$(grep -i "x-envoy-decorator-overwrite\|x-envoy-upstream-service-time" "$tmpfile" 2>/dev/null | tr -d '\r' || true)
    upstream_svc=$(grep -i "x-envoy-upstream-service-host" "$tmpfile" 2>/dev/null | tr -d '\r' || true)

    {
        echo -e "  ${CYAN}INFO${NC}: Sample (1/${count}): status=${status:-?} body='${body}'"
        if [[ -n "$route_header" ]]; then
            echo -e "  ${CYAN}INFO${NC}: Envoy headers: ${route_header}"
        fi
        if [[ -n "$upstream_svc" ]]; then
            echo -e "  ${CYAN}INFO${NC}: Upstream: ${upstream_svc}"
        fi
    } >&2
    rm -f "$tmpfile"

    for ((i = 0; i < count; i++)); do
        local resp
        if [[ "$VERBOSE" == "true" ]]; then
            local vtmp
            vtmp=$(mktemp)
            resp=$(curl -s -D "$vtmp" --max-time 5 "$@" "$url" 2>/dev/null || echo "ERROR")
            local ver="?"
            case "$resp" in *v1*) ver="v1" ;; *v2*) ver="v2" ;; *) ver="ERR" ;; esac
            local vupstream
            vupstream=$(grep -i "x-envoy-upstream-service-host" "$vtmp" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)
            echo -e "  ${CYAN}    ${NC} #$((i+1)): ${ver} upstream=${vupstream:-?}" >&2
            rm -f "$vtmp"
        else
            resp=$(curl -s --max-time 5 "$@" "$url" 2>/dev/null || echo "ERROR")
        fi
        case "$resp" in
            *v1*) v1=$((v1 + 1)) ;;
            *v2*) v2=$((v2 + 1)) ;;
            *)    errors=$((errors + 1)) ;;
        esac
    done
    echo "$v1 $v2 $errors"
}

check_split() {
    local label="$1" v1="$2" v2="$3" errors="$4" lo="$5" hi="$6"
    local total=$((v1 + v2))
    if [[ $errors -gt 5 ]]; then fail "$label: too many errors ($errors)"; return; fi
    if [[ $total -eq 0 ]]; then fail "$label: no responses"; return; fi
    local pct=$((v1 * 100 / total))
    info "$label: v1=${pct}% v2=$((100 - pct))% (v1=$v1 v2=$v2 err=$errors)"
    if [[ $pct -ge $lo && $pct -le $hi ]]; then
        pass "$label: within ${lo}-${hi}%"
    else
        fail "$label: v1=${pct}% outside ${lo}-${hi}%"
    fi
}

check_pinned() {
    local label="$1" expect="$2" v1="$3" v2="$4" errors="$5" count="$6"
    local got; [[ "$expect" == "v1" ]] && got=$v1 || got=$v2
    if [[ $got -eq $count && $errors -eq 0 ]]; then
        pass "$label: all $count reached $expect"
    else
        fail "$label: expected $expect x$count, got v1=$v1 v2=$v2 err=$errors"
    fi
}

assert_route_order() {
    local v1_created v2_created
    v1_created=$(kubectl get httproute route-v1 -n "$NS" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
    v2_created=$(kubectl get httproute route-v2 -n "$NS" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)

    if [[ -z "$v1_created" || -z "$v2_created" ]]; then
        fail "Unable to read route creation timestamps (route-v1='${v1_created:-?}' route-v2='${v2_created:-?}')"
        return 1
    fi

    info "Route creation timestamps: route-v1=$v1_created route-v2=$v2_created"
    if [[ "$v1_created" < "$v2_created" ]]; then
        pass "Precondition met: route-v1 is oldest, route-v2 is newer standby"
        return 0
    fi

    fail "Precondition failed: route-v1 must be older than route-v2 for failover validation"
    return 1
}

setup() {
    header "Setup"
    info "Deploying base resources..."
    kubectl apply -f manifests.yaml
    kubectl wait -n "$NS" --for=condition=Ready pod -l app=echo --timeout=60s
    kubectl wait -n "$NS" --for=condition=Programmed gateway/test-gateway --timeout=60s 2>/dev/null || \
    kubectl wait -n "$NS" --for=condition=Ready gateway/test-gateway --timeout=60s 2>/dev/null || \
    warn "Gateway condition check skipped"

    info "Resetting HTTPRoutes to enforce deterministic precedence..."
    kubectl delete httproute route-v1 route-v2 -n "$NS" --ignore-not-found=true >/dev/null 2>&1 || true

    info "Creating route-v1 (must be oldest)..."
    kubectl apply -f manifests.yaml
    sleep 2

    info "Applying route-v2 (must be newer standby)..."
    kubectl apply -f route-v2.yaml
    sleep 3

    assert_route_order
}

discover_gateway() {
    if [[ -n "${1:-}" ]]; then GATEWAY_URL="$1"; info "Using: $GATEWAY_URL"; return; fi
    info "Discovering gateway URL..."
    local addr
    addr=$(kubectl get gateway test-gateway -n "$NS" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [[ -n "$addr" ]]; then GATEWAY_URL="http://${addr}"; info "Found: $GATEWAY_URL"; return; fi
    addr=$(kubectl get svc -n "$NS" -l gateway.networking.k8s.io/gateway-name=test-gateway \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "$addr" ]]; then GATEWAY_URL="http://${addr}"; info "Found LB: $GATEWAY_URL"; return; fi
    warn "Auto-discovery failed. Starting port-forward..."
    local svc
    svc=$(kubectl get svc -n "$NS" -l gateway.networking.k8s.io/gateway-name=test-gateway \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "test-gateway-istio")
    kubectl port-forward -n "$NS" "svc/${svc}" 8888:80 &
    PF_PID=$!; sleep 2; GATEWAY_URL="http://localhost:8888"
    info "Port-forward PID $PF_PID: $GATEWAY_URL"
}

# ================================================================
# Test 1: Route status - both routes must be attached
# ================================================================
test_route_status() {
    header "1. Route status conditions"
    local v1_accepted v1_reason v1_refs v1_conditions
    local v2_accepted v2_reason v2_refs v2_conditions

    v1_accepted=$(kubectl get httproute route-v1 -n "$NS" \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "?")
    v1_reason=$(kubectl get httproute route-v1 -n "$NS" \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || echo "?")
    v1_refs=$(kubectl get httproute route-v1 -n "$NS" \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || echo "?")
    v1_conditions=$(kubectl get httproute route-v1 -n "$NS" \
        -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}' 2>/dev/null || echo "?")

    v2_accepted=$(kubectl get httproute route-v2 -n "$NS" \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "?")
    v2_reason=$(kubectl get httproute route-v2 -n "$NS" \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || echo "?")
    v2_refs=$(kubectl get httproute route-v2 -n "$NS" \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || echo "?")
    v2_conditions=$(kubectl get httproute route-v2 -n "$NS" \
        -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}' 2>/dev/null || echo "?")

    info "route-v1: Accepted=$v1_accepted Reason=$v1_reason"
    info "route-v1 conditions: $v1_conditions"
    info "route-v2: Accepted=$v2_accepted Reason=$v2_reason"
    info "route-v2 conditions: $v2_conditions"

    [[ "$v1_refs" == "True" ]] && pass "route-v1 ResolvedRefs=True" || fail "route-v1 ResolvedRefs is '$v1_refs'"
    [[ "$v2_refs" == "True" ]] && pass "route-v2 ResolvedRefs=True" || fail "route-v2 ResolvedRefs is '$v2_refs'"

    if [[ "$v1_accepted" == "True" ]]; then
        pass "route-v1 Accepted=True"
    else
        fail "route-v1 must be Accepted=True (got '$v1_accepted', reason '$v1_reason')"
    fi

    if [[ "$v2_accepted" == "True" ]]; then
        pass "route-v2 Accepted=True (standby route is attached and active)"
    elif [[ "$v2_accepted" == "False" ]]; then
        fail "route-v2 must be Accepted=True for this model (got False, reason '$v2_reason')"
    else
        fail "route-v2 Accepted condition missing (got '$v2_accepted')"
    fi

    echo ""
    kubectl get httproute -n "$NS" -o wide 2>/dev/null || true
}

# ================================================================
# Test 2: Header match - weighted split (overlapping rule)
# ================================================================
test_header_split() {
    header "2. Header match weighted split ($REQUESTS requests)"
    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/" "$REQUESTS" -H "${MODEL_HEADER}: ${MODEL_VALUE}")"
    check_split "Header match" "$v1" "$v2" "$errors" "$SPLIT_90_MIN" "$SPLIT_90_MAX"
}

# ================================================================
# Test 3: Publisher path - weighted split (overlapping rule)
# ================================================================
test_publisher_path_split() {
    header "3. Publisher path weighted split ($REQUESTS requests)"
    read -r v1 v2 errors <<< "$(send_requests "${GATEWAY_URL}${PUBLISHER_PATH}" "$REQUESTS")"
    check_split "Publisher path" "$v1" "$v2" "$errors" "$SPLIT_90_MIN" "$SPLIT_90_MAX"
}

# ================================================================
# Test 4: Direct access - pinned to specific version (non-overlapping)
# ================================================================
test_direct_access() {
    header "4. Direct access paths (non-overlapping, pinned)"
    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/direct/v1" 10)"
    check_pinned "/direct/v1" "v1" "$v1" "$v2" "$errors" 10

    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/direct/v2" 10)"
    check_pinned "/direct/v2" "v2" "$v1" "$v2" "$errors" 10
}

# ================================================================
# Test 5: All three access patterns work concurrently
# ================================================================
test_concurrent() {
    header "5. All access patterns concurrent (no interference)"

    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/" 20 -H "${MODEL_HEADER}: ${MODEL_VALUE}")"
    [[ $((v1 + v2)) -ge 18 ]] && pass "Header match: $((v1+v2))/20" || fail "Header match: $((v1+v2))/20"

    read -r v1 v2 errors <<< "$(send_requests "${GATEWAY_URL}${PUBLISHER_PATH}" 20)"
    [[ $((v1 + v2)) -ge 18 ]] && pass "Publisher path: $((v1+v2))/20" || fail "Publisher path: $((v1+v2))/20"

    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/direct/v1" 5)"
    check_pinned "Direct /v1" "v1" "$v1" "$v2" "$errors" 5

    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/direct/v2" 5)"
    check_pinned "Direct /v2" "v2" "$v1" "$v2" "$errors" 5
}

# ================================================================
# Test 6: Hot standby failover (delete oldest route)
# ================================================================
test_failover() {
    header "6. Hot standby failover (delete route-v1)"
    kubectl delete httproute route-v1 -n "$NS"
    sleep "$SETTLE"

    info "Header match after failover:"
    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/" "$REQUESTS" -H "${MODEL_HEADER}: ${MODEL_VALUE}")"
    check_split "Header after failover" "$v1" "$v2" "$errors" "$SPLIT_90_MIN" "$SPLIT_90_MAX"

    info "Publisher path after failover:"
    read -r v1 v2 errors <<< "$(send_requests "${GATEWAY_URL}${PUBLISHER_PATH}" "$REQUESTS")"
    check_split "Publisher after failover" "$v1" "$v2" "$errors" "$SPLIT_90_MIN" "$SPLIT_90_MAX"

    info "Direct /v1 should be unreachable (route deleted):"
    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/direct/v1" 5)"
    if [[ $errors -ge 4 ]]; then
        pass "/direct/v1 correctly unreachable"
    else
        warn "/direct/v1 still reachable (v1=$v1 v2=$v2 err=$errors) - may indicate route merge"
    fi

    info "Direct /v2 should still work:"
    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/direct/v2" 5)"
    check_pinned "/direct/v2 after failover" "v2" "$v1" "$v2" "$errors" 5

    info "Restoring route-v1..."
    kubectl apply -f manifests.yaml
    sleep "$SETTLE"
}

# ================================================================
# Test 7: Weight change on active route
# ================================================================
WEIGHT_PATCH_50='[
    {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":5},
    {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":5},
    {"op":"replace","path":"/spec/rules/1/backendRefs/0/weight","value":5},
    {"op":"replace","path":"/spec/rules/1/backendRefs/1/weight","value":5}
]'
WEIGHT_PATCH_90='[
    {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":9},
    {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":1},
    {"op":"replace","path":"/spec/rules/1/backendRefs/0/weight","value":9},
    {"op":"replace","path":"/spec/rules/1/backendRefs/1/weight","value":1}
]'

patch_both_routes() {
    local patch="$1" label="$2"
    info "Patching both routes: $label"
    kubectl patch httproute route-v1 -n "$NS" --type='json' -p="$patch"
    kubectl patch httproute route-v2 -n "$NS" --type='json' -p="$patch"
    sleep "$SETTLE"
    # Verify
    local w1 w2
    w1=$(kubectl get httproute route-v1 -n "$NS" -o jsonpath='{.spec.rules[0].backendRefs[0].weight} {.spec.rules[0].backendRefs[1].weight}' 2>/dev/null)
    w2=$(kubectl get httproute route-v2 -n "$NS" -o jsonpath='{.spec.rules[0].backendRefs[0].weight} {.spec.rules[0].backendRefs[1].weight}' 2>/dev/null)
    info "Verified weights - route-v1: [$w1] route-v2: [$w2]"
}

test_weight_change() {
    header "7. Weight change (90/10 -> 50/50 on BOTH routes)"
    info "Simulates controller reconciling all group members to new weights"

    patch_both_routes "$WEIGHT_PATCH_50" "50/50"

    info "Header match after weight change:"
    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/" "$REQUESTS" -H "${MODEL_HEADER}: ${MODEL_VALUE}")"
    check_split "Header 50/50" "$v1" "$v2" "$errors" "$SPLIT_50_MIN" "$SPLIT_50_MAX"

    info "Publisher path after weight change:"
    read -r v1 v2 errors <<< "$(send_requests "${GATEWAY_URL}${PUBLISHER_PATH}" "$REQUESTS")"
    check_split "Publisher 50/50" "$v1" "$v2" "$errors" "$SPLIT_50_MIN" "$SPLIT_50_MAX"

    info "Direct access unaffected by weight change:"
    read -r v1 v2 errors <<< "$(send_requests "$GATEWAY_URL/direct/v1" 5)"
    check_pinned "/direct/v1 still pinned" "v1" "$v1" "$v2" "$errors" 5

    # Restore
    patch_both_routes "$WEIGHT_PATCH_90" "90/10 (restore)"
}

# --- Main ---
main() {
    echo ""
    echo "============================================================"
    echo "  Per-Participant Routes Validation Spike"
    echo ""
    echo "  Each route carries: header match (weighted, overlapping)"
    echo "                      publisher path (weighted, overlapping)"
    echo "                      direct access (pinned, non-overlapping)"
    echo "  Split thresholds:   90/10 => ${SPLIT_90_MIN}-${SPLIT_90_MAX}% v1"
    echo "                      50/50 => ${SPLIT_50_MIN}-${SPLIT_50_MAX}% v1"
    echo "============================================================"

    setup
    discover_gateway "${1:-}"

    test_route_status
    test_header_split
    test_publisher_path_split
    test_direct_access
    test_concurrent
    test_failover
    test_weight_change

    echo ""
    echo "============================================================"
    if [[ $FAILURES -eq 0 ]]; then
        echo -e "  ${GREEN}All tests passed${NC}"
    else
        echo -e "  ${RED}$FAILURES test(s) failed${NC}"
    fi
    echo "============================================================"

    [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true
    exit "$FAILURES"
}

main "$@"
