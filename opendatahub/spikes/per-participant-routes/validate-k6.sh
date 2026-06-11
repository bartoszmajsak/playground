#!/usr/bin/env bash
set -euo pipefail

NS="${ROUTE_VALIDATION_NS:-route-validation}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K6_SCRIPT="${SCRIPT_DIR}/validate-k6.js"
PF_PID=""

cleanup() {
    if [[ -n "${PF_PID}" ]]; then
        kill "${PF_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage:
  ./validate-k6.sh [GATEWAY_URL] [k6 run args...]

Examples:
  ./validate-k6.sh
  ./validate-k6.sh http://10.96.1.100
  ROUTE_VALIDATION_K6_DURATION=60s ROUTE_VALIDATION_K6_HEADER_VUS=50 ./validate-k6.sh --summary-export=summary.json

Environment:
  ROUTE_VALIDATION_NS            Namespace (default: route-validation)
  ROUTE_VALIDATION_K6_DURATION   Scenario duration (default: 30s)
  ROUTE_VALIDATION_K6_HEADER_VUS Header scenario VUs (default: 20)
  ROUTE_VALIDATION_K6_PUBLISHER_VUS
                                 Publisher scenario VUs (default: 20)
  ROUTE_VALIDATION_K6_DIRECT_V1_VUS
                                 Direct /v1 scenario VUs (default: 10)
  ROUTE_VALIDATION_K6_DIRECT_V2_VUS
                                 Direct /v2 scenario VUs (default: 10)
  ROUTE_VALIDATION_K6_REQUEST_TIMEOUT
                                 Per-request timeout (default: 5s)
  ROUTE_VALIDATION_SPLIT_90_MIN  Lower bound for 90/10 v1 share (default: 82)
  ROUTE_VALIDATION_SPLIT_90_MAX  Upper bound for 90/10 v1 share (default: 97)
EOF
}

discover_gateway() {
    local provided="${1:-}"
    if [[ -n "${provided}" ]]; then
        GATEWAY_URL="${provided}"
        return
    fi

    local addr=""
    addr=$(kubectl get gateway test-gateway -n "${NS}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [[ -n "${addr}" ]]; then
        GATEWAY_URL="http://${addr}"
        return
    fi

    addr=$(kubectl get svc -n "${NS}" -l gateway.networking.k8s.io/gateway-name=test-gateway \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "${addr}" ]]; then
        GATEWAY_URL="http://${addr}"
        return
    fi

    local svc=""
    svc=$(kubectl get svc -n "${NS}" -l gateway.networking.k8s.io/gateway-name=test-gateway \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "test-gateway-istio")
    kubectl port-forward -n "${NS}" "svc/${svc}" 8888:80 >/tmp/validate-k6-port-forward.log 2>&1 &
    PF_PID=$!
    sleep 2
    GATEWAY_URL="http://localhost:8888"
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if ! command -v k6 >/dev/null 2>&1; then
        echo "k6 is not installed or not in PATH."
        echo "Install from https://k6.io/docs/get-started/installation/"
        exit 1
    fi

    local gateway_arg=""
    if [[ "${1:-}" =~ ^https?:// ]]; then
        gateway_arg="${1}"
        shift
    fi

    discover_gateway "${gateway_arg}"
    export BASE_URL="${GATEWAY_URL}"

    echo "Running k6 parallel validation against ${BASE_URL}"
    k6 run "${K6_SCRIPT}" "$@"
}

main "$@"
