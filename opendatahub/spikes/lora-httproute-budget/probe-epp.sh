#!/usr/bin/env bash
# What actually answers a request the collapse newly sends to the InferencePool?
#
# Everything the characterization harness reports about the pool is a Service
# named echo-pool -- backends are swapped so destination is observable, which
# means the EPP is never in the path. That is right for characterizing route
# matching and useless for this question.
#
# Here the routes keep their real backendRefs, so a request that matches a
# pool rule goes gateway -> InferencePool -> EPP -> runtime. What comes back is
# the answer: a status code and, when it fails, whose error it is.
#
# The probe list is deliberately narrow. It is the set the collapse moves from
# the workload Service to the pool, plus controls that should be unaffected.
#
# Usage:
#   ./probe-epp.sh current     # today's shape: these paths reach the Service
#   ./probe-epp.sh collapse    # after the collapse: they reach the pool
#   ./probe-epp.sh --diff      # compare the two recorded runs

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"
NS="${NS:-lora-budget}"
OUT_DIR="${SCRIPT_DIR}/golden"
H="publishers/lora-budget/models/model-a"
A1="publishers/lora-budget/models/adapter-a1"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

if [[ "${1:-}" == "--diff" ]]; then
    diff -u "${OUT_DIR}/epp-current.tsv" "${OUT_DIR}/epp-collapse.tsv" || true
    exit 0
fi
SHAPE="${1:-current}"

GATEWAY_URL="${GATEWAY_URL:-http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
    -o jsonpath='{.status.addresses[0].value}')}"

# method  path  header  note
PROBES=$(cat <<EOF
GET|/health|${H}|moved by collapse; no body, so no model
GET|/metrics|${H}|moved by collapse; no body
GET|/v1/models|${H}|moved by collapse; no body
POST|/v1/embeddings|${H}|moved by collapse; has model, endpoint may not exist
POST|/v1/messages/count_tokens|${H}|moved by collapse; has model
GET|/v1/responses/resp_abc123|${H}|moved by collapse; stateful, no model
POST|/anything/at/all|${H}|moved by collapse; unknown path
GET|/|${H}|moved by collapse; root
POST|/v1/chat/completions|${H}|control: already reaches the pool today
POST|/v1/chat/completions|${A1}|control: adapter, already reaches the pool
POST|/lora-budget/svc-a/v1/chat/completions||control: path-addressed to the pool
GET|/lora-budget/svc-a/health||control: path-addressed to the Service
GET|/lora-budget/svc-a/v1/models||control: path-addressed to the Service
EOF
)

echo -e "${BOLD}EPP probe: ${SHAPE}${NC}   gateway ${GATEWAY_URL}"
printf '  %-6s %-34s %-9s %-6s %s\n' method path header status 'body / error'
printf '  %-6s %-34s %-9s %-6s %s\n' ------ ---------------------------------- --------- ------ ------------

OUT="${OUT_DIR}/epp-${SHAPE}.tsv"
: >"$OUT"

while IFS='|' read -r method path hdr note; do
    [[ -z "$method" ]] && continue
    body=$(mktemp)
    args=(-s -o "$body" -w '%{http_code}' -X "$method" --max-time 20 -H 'Content-Type: application/json')
    [[ -n "$hdr" ]] && args+=(-H "X-Gateway-Model-Name: ${hdr}")
    if [[ "$method" == "POST" ]]; then
        args+=(-d "{\"model\":\"${hdr:-model-a}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}")
    fi
    status=$(curl "${args[@]}" "${GATEWAY_URL}${path}" 2>/dev/null || echo 000)

    # Keep the first line of whatever came back: EPP errors are plain text,
    # runtime errors are JSON, and an empty body is itself a signal.
    snippet=$(head -c 300 "$body" | tr -d '\n' | sed 's/  */ /g')
    [[ -z "$snippet" ]] && snippet="(empty)"
    rm -f "$body"

    tag="${hdr:+hdr}"; tag="${tag:--}"
    [[ "$hdr" == "$A1" ]] && tag="adapter"
    colour="$GREEN"; [[ "$status" =~ ^[45] ]] && colour="$RED"
    printf "  %-6s %-34s %-9s ${colour}%-6s${NC} %s\n" "$method" "$path" "$tag" "$status" "${snippet:0:70}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$method" "$path" "$tag" "$status" "${snippet:0:120}" >>"$OUT"
done <<<"$PROBES"

echo
echo -e "  ${CYAN}INFO${NC}: recorded golden/epp-${SHAPE}.tsv"
