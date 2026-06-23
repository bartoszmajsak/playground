#!/usr/bin/env bash
# Envoy Gateway weighted split reproducer - validation
set -euo pipefail

NS="eg-split-test"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; }
info() { echo -e "  ${CYAN}INFO${NC}: $1"; }

# Send OpenAI-compatible chat completion request and check for 200.
check_traffic() {
    local path="$1" count="${2:-10}"
    local ok=0 errors=0
    for _ in $(seq 1 "$count"); do
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            -H "Content-Type: application/json" \
            -H "x-ai-eg-model: test-model" \
            -d '{"model":"test-model","messages":[{"role":"user","content":"hello"}]}' \
            "${GATEWAY_URL}${path}" 2>/dev/null || true)
        if [[ "$http_code" == "200" ]]; then
            ok=$((ok + 1))
        else
            errors=$((errors + 1))
        fi
    done
    if [[ $ok -gt 0 ]]; then
        pass "Traffic flows ($ok/$count requests returned 200)"
    else
        local last_code
        last_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            -H "Content-Type: application/json" \
            -H "x-ai-eg-model: test-model" \
            -d '{"model":"test-model","messages":[{"role":"user","content":"hello"}]}' \
            "${GATEWAY_URL}${path}" 2>/dev/null || true)
        fail "No traffic (HTTP $last_code, $errors/$count failed)"
    fi
}

# Check if a route has an xDS entry in the Envoy config dump.
route_in_xds() {
    local route_name="$1"
    local proxy_pod
    proxy_pod=$(kubectl get pods -n envoy-gateway-system \
        -l app.kubernetes.io/component=proxy -o name 2>/dev/null | head -1)
    if [[ -z "$proxy_pod" ]]; then return 1; fi

    local admin_port=19099
    kubectl port-forward -n envoy-gateway-system "$proxy_pod" "${admin_port}:19000" &>/dev/null &
    local pf_pid=$!
    sleep 1

    local found
    found=$(curl -s "http://localhost:${admin_port}/config_dump" 2>/dev/null \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
for config in data.get('configs', []):
    if config.get('@type', '').endswith('RoutesConfigDump'):
        for rc in config.get('dynamic_route_configs', []):
            for vh in rc.get('route_config', {}).get('virtual_hosts', []):
                for route in vh.get('routes', []):
                    if '${route_name}' in route.get('name', ''):
                        print('found')
                        sys.exit(0)
" 2>/dev/null || true)

    kill $pf_pid 2>/dev/null
    wait $pf_pid 2>/dev/null
    [[ "$found" == "found" ]]
}

GATEWAY_URL=""
gw_addr=$(kubectl get gateway test-gateway -n "$NS" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
if [[ -n "$gw_addr" ]]; then
    GATEWAY_URL="http://$gw_addr"
else
    echo "No gateway address found."
    exit 1
fi

echo -e "${BOLD}Envoy Gateway Weighted Split Reproducer${NC}"
echo "Gateway: $GATEWAY_URL"
echo ""

# Wait for the gateway to be programmed
info "Waiting for gateway to be programmed..."
for _ in $(seq 1 30); do
    programmed=$(kubectl get gateway test-gateway -n "$NS" \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
    if [[ "$programmed" == "True" ]]; then
        break
    fi
    sleep 2
done
if [[ "$programmed" != "True" ]]; then
    fail "Gateway not programmed after 60s"
    exit 1
fi

# Wait for EG to register InferencePools as custom backend resources
info "Waiting for EG to register InferencePools..."
for _ in $(seq 1 15); do
    registered=$(kubectl logs -n envoy-gateway-system deployment/envoy-gateway --tail=50 2>&1 \
        | grep -c "added custom backend resource.*InferencePool" || true)
    if [[ "$registered" -ge 2 ]]; then
        break
    fi
    sleep 2
done

# =========================================================================
# Test 1: Service weighted split (standard Gateway API baseline)
# =========================================================================

echo -e "${BOLD}Test 1: Service backendRefs with weighted split${NC}"

kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: service-weighted
  namespace: $NS
spec:
  parentRefs:
    - name: test-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/chat/completions
      backendRefs:
        - name: model-v1
          port: 8080
          weight: 9
        - name: model-v2
          port: 8080
          weight: 1
EOF
sleep 5

accepted=$(kubectl get httproute service-weighted -n "$NS" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
if [[ "$accepted" == "True" ]]; then
    pass "Service weighted HTTPRoute accepted"
else
    fail "Service weighted HTTPRoute not accepted"
fi

check_traffic "/v1/chat/completions" 20

# Clean up - don't leave a path-conflicting route for the AIGatewayRoute tests
kubectl delete httproute service-weighted -n "$NS" >/dev/null 2>&1
sleep 3

echo ""

# =========================================================================
# Test 2: Single InferencePool via AIGatewayRoute (control)
# =========================================================================

echo -e "${BOLD}Test 2: Single InferencePool via AIGatewayRoute (control)${NC}"

kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute
metadata:
  name: pool-single
  namespace: $NS
spec:
  parentRefs:
    - name: test-gateway
      kind: Gateway
      group: gateway.networking.k8s.io
  rules:
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: test-model
      backendRefs:
        - group: inference.networking.k8s.io
          kind: InferencePool
          name: pool-v1
EOF

# Wait for AIGatewayRoute controller to generate HTTPRoute + ext_proc sidecar rollout
info "Waiting for AIGatewayRoute reconciliation + sidecar rollout..."
for _ in $(seq 1 30); do
    status=$(kubectl get aigatewayroute pool-single -n "$NS" \
        -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
    if [[ "$status" == "True" ]]; then break; fi
    sleep 2
done

# The sidecar rollout takes time - wait for the proxy pod to have 3 containers
for _ in $(seq 1 30); do
    ready=$(kubectl get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy \
        -o jsonpath='{.items[0].status.containerStatuses[?(@.ready==true)].name}' 2>/dev/null | wc -w || true)
    init_ready=$(kubectl get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy \
        -o jsonpath='{.items[0].status.initContainerStatuses[?(@.ready==true)].name}' 2>/dev/null | wc -w || true)
    total=$((ready + init_ready))
    if [[ $total -ge 3 ]]; then break; fi
    sleep 2
done
sleep 5

if route_in_xds "pool-single"; then
    pass "Single-pool route present in Envoy config"
else
    fail "Single-pool route missing from Envoy config"
fi

check_traffic "/v1/chat/completions"

echo ""

# =========================================================================
# Test 3: Multi-InferencePool weighted split via AIGatewayRoute
# =========================================================================

echo -e "${BOLD}Test 3: Multi-InferencePool weighted split${NC}"

# AIGatewayRoute rejects multiple InferencePools per rule at admission:
#   "only one InferencePool backend is allowed per rule"
# So we test with a plain HTTPRoute to hit the xDS-level bug.
aigw_error=$(kubectl apply -f - 2>&1 <<'AIGWEOF' || true
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute
metadata:
  name: pool-weighted
  namespace: eg-split-test
spec:
  parentRefs:
    - name: test-gateway
      kind: Gateway
      group: gateway.networking.k8s.io
  rules:
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: test-model-weighted
      backendRefs:
        - group: inference.networking.k8s.io
          kind: InferencePool
          name: pool-v1
          weight: 9
        - group: inference.networking.k8s.io
          kind: InferencePool
          name: pool-v2
          weight: 1
AIGWEOF
)
if echo "$aigw_error" | grep -qi "only one InferencePool"; then
    pass "AIGatewayRoute rejects multi-pool at admission"
    info "Validation: only one InferencePool backend is allowed per rule"
else
    info "AIGatewayRoute accepted multi-pool (unexpected)"
fi

# Bypass AIGatewayRoute validation with a plain HTTPRoute
kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: pool-weighted
  namespace: $NS
spec:
  parentRefs:
    - name: test-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /pool-split
      backendRefs:
        - group: inference.networking.k8s.io
          kind: InferencePool
          name: pool-v1
          weight: 9
        - group: inference.networking.k8s.io
          kind: InferencePool
          name: pool-v2
          weight: 1
EOF
sleep 5

xds_error=$(kubectl logs -n envoy-gateway-system deployment/envoy-gateway --since=30s 2>&1 \
    | grep -o "at most one inferencepool.*" | head -1 || true)
if [[ -n "$xds_error" ]]; then
    fail "xDS translation rejected by AI Gateway extension server"
    info "EG log: $xds_error"
else
    pass "No xDS translation errors for multi-pool route"
fi

if route_in_xds "pool-weighted"; then
    pass "Route present in Envoy config"
else
    fail "Route missing from Envoy config (no xDS generated)"
fi

check_traffic "/pool-split"

echo ""

# =========================================================================
# Test 4: xDS poisoning
# =========================================================================

echo -e "${BOLD}Test 4: xDS poisoning${NC}"

# 4a: The single-pool route from Test 2 was configured before the multi-pool
# route. Envoy keeps the last good xDS config, so it should survive.
if route_in_xds "pool-single"; then
    pass "Pre-existing single-pool route survived (cached xDS)"
else
    fail "Pre-existing single-pool route lost"
fi

# 4b: Create a brand-new single-pool route that has never been in any xDS push.
kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: pool-single-new
  namespace: $NS
spec:
  parentRefs:
    - name: test-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /pool-single-new
      backendRefs:
        - group: inference.networking.k8s.io
          kind: InferencePool
          name: pool-v1
EOF
sleep 5

if route_in_xds "pool-single-new"; then
    pass "New single-pool route configured despite multi-pool route"
else
    fail "New single-pool route blocked by multi-pool xDS failure"
    info "The broken route poisons the entire xDS push, not just its own route"
fi

check_traffic "/pool-single-new"

echo ""

# =========================================================================
# Test 5: Recovery after removing the broken route
# =========================================================================

echo -e "${BOLD}Test 5: Recovery - removing multi-pool route unblocks single-pool${NC}"

kubectl delete httproute pool-weighted pool-single-new -n "$NS" >/dev/null 2>&1
sleep 5

if route_in_xds "pool-single"; then
    pass "Single-pool route recovered after removing multi-pool route"

    xds_error=$(kubectl logs -n envoy-gateway-system deployment/envoy-gateway --since=10s 2>&1 \
        | grep -o "at most one inferencepool.*" | head -1 || true)
    if [[ -n "$xds_error" ]]; then
        fail "Unexpected xDS error after recovery"
    else
        pass "xDS translation clean"
    fi

    check_traffic "/v1/chat/completions"
else
    fail "Single-pool route did not recover"
fi

echo ""

# =========================================================================
# Summary
# =========================================================================

eg_image=$(kubectl get deployment envoy-gateway -n envoy-gateway-system \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
aieg_image=$(kubectl get deployment ai-gateway-controller -n envoy-ai-gateway-system \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

echo -e "${BOLD}Summary${NC}"
echo ""
echo "  EG:         $eg_image"
echo "  AI Gateway: $aieg_image"
echo ""
echo "  Cleanup: kind delete cluster --name eg-split-spike"
