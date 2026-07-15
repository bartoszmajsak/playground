#!/usr/bin/env bash
# AgentGateway BackendRef Override Spike - Validation
#
# Deploys a tiny LLM via LLMInferenceService with AgentgatewayBackend backendRef override,
# then verifies that AgentGateway activates its LLM pipeline (GenAI telemetry, token tracking).
#
# Usage:
#   ./validate.sh                    # full flow
#   ./validate.sh --ratelimit        # also test token-based rate limiting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="agentgateway-spike"
MODEL="tiny-llama"
ENABLE_RATELIMIT=false

for arg in "$@"; do
    case "$arg" in
        --ratelimit) ENABLE_RATELIMIT=true ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FAILURES=0
STEPS_RAN=0

info()   { echo -e "  ${CYAN}INFO${NC}: $1"; }
pass()   { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail()   { echo -e "  ${RED}FAIL${NC}: $1"; FAILURES=$((FAILURES + 1)); }
header() { echo -e "\n${BOLD}$1${NC}"; STEPS_RAN=$((STEPS_RAN + 1)); }

# -------------------------------------------------------------------------
# Gateway discovery
# -------------------------------------------------------------------------

discover_gateway() {
    if [[ -n "${GATEWAY_URL:-}" ]]; then return; fi

    local addr
    addr=$(kubectl get gateway kserve-ingress-gateway -n kserve \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [[ -n "$addr" ]]; then
        GATEWAY_URL="http://$addr"
        return
    fi

    addr=$(kubectl get svc -n kserve \
        -l "gateway.networking.k8s.io/gateway-name=kserve-ingress-gateway" \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "$addr" ]]; then
        GATEWAY_URL="http://$addr"
        return
    fi

    echo "No gateway address found. Set GATEWAY_URL manually or use port-forward."
    exit 1
}

# -------------------------------------------------------------------------
# Deploy
# -------------------------------------------------------------------------

deploy() {
    header "Deploying LLMInferenceService with AgentgatewayBackend override"

    kubectl apply -k "$SCRIPT_DIR/manifests/overlays/agentgateway" 2>/dev/null

    info "Waiting for LLMInferenceService to be Ready (this may take a few minutes for vLLM startup)..."
    kubectl wait llminferenceservice "$MODEL" -n "$NS" \
        --for=condition=Ready --timeout=600s \
        || { fail "LLMInferenceService not ready after 600s"; exit 1; }

    ok "LLMInferenceService $MODEL is Ready"

    info "Checking generated resources..."
    echo "  HTTPRoutes:"
    kubectl get httproute -n "$NS" 2>/dev/null || true
    echo "  AgentgatewayBackend:"
    kubectl get agentgatewaybackend -n "$NS" 2>/dev/null || true
    echo "  Workload service:"
    kubectl get svc -n "$NS" -l "serving.kserve.io/llminferenceservice=${MODEL}" 2>/dev/null || true
}

# -------------------------------------------------------------------------
# Shared curl helpers
# -------------------------------------------------------------------------

CHAT_PAYLOAD='{"model":"'"$MODEL"'","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'

chat_completion() {
    local extra_headers=("$@")
    local resp_file http_code
    resp_file=$(mktemp)
    http_code=$(curl -s -D "${resp_file}.hdr" -o "$resp_file" -w "%{http_code}" \
        --max-time 30 \
        -H "Content-Type: application/json" \
        "${extra_headers[@]}" \
        -d "$CHAT_PAYLOAD" \
        "${GATEWAY_URL}/v1/chat/completions" 2>/dev/null) || http_code="000"

    LAST_HTTP_CODE="$http_code"
    LAST_RESPONSE=$(cat "$resp_file" 2>/dev/null || true)
    LAST_HEADERS=$(cat "${resp_file}.hdr" 2>/dev/null || true)
    rm -f "$resp_file" "${resp_file}.hdr"
}

# -------------------------------------------------------------------------
# Test: Chat completion
# -------------------------------------------------------------------------

test_chat_completion() {
    header "Step 1: Chat completion request"

    discover_gateway
    info "Gateway URL: $GATEWAY_URL"
    info "curl -s ${GATEWAY_URL}/v1/chat/completions -H 'Content-Type: application/json' -d '${CHAT_PAYLOAD}'"

    chat_completion
    echo ""

    if [[ "$LAST_HTTP_CODE" != "200" ]]; then
        fail "Expected HTTP 200, got $LAST_HTTP_CODE"
        info "Trying with Host header: ${MODEL}.${NS}.example.com"
        chat_completion -H "Host: ${MODEL}.${NS}.example.com"
        if [[ "$LAST_HTTP_CODE" != "200" ]]; then
            fail "Still got HTTP $LAST_HTTP_CODE with Host header"
            info "Debug: HTTPRoute details:"
            kubectl get httproute -n "$NS" -o yaml 2>/dev/null | head -40
            return 1
        fi
    fi

    echo "$LAST_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$LAST_RESPONSE"
    echo ""

    if echo "$LAST_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'choices' in d" 2>/dev/null; then
        pass "Response contains 'choices' field"
    else
        fail "Response missing 'choices' field"
    fi

    local usage
    usage=$(echo "$LAST_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
u = d.get('usage', {})
print(f\"prompt={u.get('prompt_tokens','?')} completion={u.get('completion_tokens','?')} total={u.get('total_tokens','?')}\")
" 2>/dev/null || echo "unavailable")
    info "Token usage: $usage"

    if echo "$LAST_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('usage',{}).get('total_tokens',0) > 0" 2>/dev/null; then
        pass "Response includes token usage counts"
    else
        fail "Response missing token usage (needed for AgentGateway token tracking)"
    fi
}

# -------------------------------------------------------------------------
# Test: GenAI telemetry in gateway logs
# -------------------------------------------------------------------------

test_genai_telemetry() {
    header "Step 2: GenAI telemetry in gateway logs"

    local gw_ns="" gw_deploy=""
    for ns in kserve agentgateway-system; do
        gw_deploy=$(kubectl get deploy -n "$ns" \
            -l "gateway.networking.k8s.io/gateway-name=kserve-ingress-gateway" \
            -o name 2>/dev/null | head -1)
        if [[ -n "$gw_deploy" ]]; then gw_ns="$ns"; break; fi
    done

    if [[ -z "$gw_deploy" ]]; then
        fail "Could not find AgentGateway proxy deployment"
        info "Deployments in kserve:"
        kubectl get deploy -n kserve 2>/dev/null
        return 1
    fi

    info "Checking logs: kubectl logs -n $gw_ns $gw_deploy --tail=50"
    local logs
    logs=$(kubectl logs -n "$gw_ns" "$gw_deploy" --tail=50 2>/dev/null || true)

    if echo "$logs" | grep -qE "protocol=llm|gen_ai\.|protocol.*llm"; then
        pass "GenAI telemetry detected in gateway logs"
        echo "$logs" | grep -E "gen_ai\.|protocol.*llm" | tail -5
    else
        fail "No GenAI telemetry found - gateway treating traffic as plain HTTP"
        info "Recent gateway logs:"
        echo "$logs" | tail -10
    fi
}

# -------------------------------------------------------------------------
# Test: Token-based rate limiting (optional)
# -------------------------------------------------------------------------

test_ratelimit() {
    header "Step 4: Token-based rate limiting"

    discover_gateway

    info "AgentgatewayPolicy status:"
    kubectl get agentgatewaypolicy -n "$NS" 2>/dev/null || true
    echo ""

    local total=30
    info "Sending $total rapid requests to exhaust token budget..."
    info "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST ${GATEWAY_URL}/v1/chat/completions ..."
    echo ""

    local ok_count=0 limited_count=0 err_count=0

    for i in $(seq 1 $total); do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -X POST "${GATEWAY_URL}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"model":"'"$MODEL"'","messages":[{"role":"user","content":"Hello request '"$i"'"}],"max_tokens":10}' \
            2>/dev/null) || code="000"

        case "$code" in
            200) ((ok_count++)) ;;
            429) ((limited_count++)) ;;
            *)   ((err_count++)) ;;
        esac
        echo "  Request $i: HTTP $code"
    done

    echo ""
    info "Results: $ok_count OK, $limited_count rate-limited (429), $err_count errors"

    if [[ $limited_count -gt 0 ]]; then
        pass "Token-based rate limiting is working ($limited_count/$total got 429)"
    else
        fail "No requests were rate-limited - policy may not be attached or budget too high"
    fi
}

# -------------------------------------------------------------------------
# Test: Compare with vs without AgentgatewayBackend
# -------------------------------------------------------------------------

test_backendref_override() {
    header "Step 3: HTTPRoute backendRef override"

    info "kubectl get httproute -n $NS"
    kubectl get httproute -n "$NS" 2>/dev/null || true
    echo ""

    local refs
    refs=$(kubectl get httproute -n "$NS" \
        -o jsonpath='{range .items[*]}{range .spec.rules[*]}{range .backendRefs[*]}{.kind}{"\n"}{end}{end}{end}' 2>/dev/null || true)

    if echo "$refs" | grep -q "AgentgatewayBackend"; then
        pass "HTTPRoute backendRefs point to AgentgatewayBackend"
        info "backendRef details:"
        kubectl get httproute -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}:{"\n"}{range .spec.rules[*]}{range .backendRefs[*]}  kind={.kind} name={.name} group={.group}{"\n"}{end}{end}{"\n"}{end}' 2>/dev/null
    elif echo "$refs" | grep -qE "InferencePool|Service"; then
        fail "HTTPRoute backendRefs still point to InferencePool/Service - override not applied"
        info "Expected kind=AgentgatewayBackend, got:"
        kubectl get httproute -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}:{"\n"}{range .spec.rules[*]}{range .backendRefs[*]}  kind={.kind} name={.name} group={.group}{"\n"}{end}{end}{"\n"}{end}' 2>/dev/null
    else
        fail "No backendRefs found in HTTPRoutes"
    fi
}

# =========================================================================
# Main
# =========================================================================

echo -e "${BOLD}AgentGateway BackendRef Override Spike - Validation${NC}"
echo ""

deploy
test_chat_completion
test_genai_telemetry
test_backendref_override

if [[ "$ENABLE_RATELIMIT" == "true" ]]; then
    test_ratelimit
fi

echo ""
echo -e "${BOLD}========================================${NC}"
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All $STEPS_RAN steps passed.${NC}"
else
    echo -e "${RED}${BOLD}$FAILURES failure(s) across $STEPS_RAN steps.${NC}"
fi
echo -e "${BOLD}========================================${NC}"
echo ""
echo "Manual exploration:"
echo "  export GATEWAY_URL=${GATEWAY_URL:-\$(kubectl get gateway kserve-ingress-gateway -n kserve -o jsonpath='{.status.addresses[0].value}')}"
echo "  curl -s \$GATEWAY_URL/v1/chat/completions -H 'Content-Type: application/json' -d '${CHAT_PAYLOAD}' | jq ."
echo "  kubectl logs -n kserve deploy/kserve-ingress-gateway -f"
if [[ "$ENABLE_RATELIMIT" != "true" ]]; then
    echo "  ./validate.sh --ratelimit    # test token-based rate limiting"
fi

exit "$FAILURES"
