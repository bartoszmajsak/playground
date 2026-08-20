#!/usr/bin/env bash
# What the gateway AUTHORIZES is not what vLLM SERVES.
#
# odh-model-controller renders a Kuadrant AuthPolicy per LLMInferenceService
# (internal/controller/resources/template/authpolicy_llm_isvc_userdefined.yaml).
# Every authorization rule in it derives the SubjectAccessReview resource name
# from `context.request.http.path`:
#
#   model-access-path   -> serving.opendatahub.io/models
#                          name = 'publishers/' + path[2] + '/models/' + <between /models/ and /v1/>
#   inference-access    -> serving.kserve.io/llminferenceservices
#                          name = path[2], namespace = path[1]
#
# Nothing in the policy reads the request body, and vLLM reads nothing else.
# This probe measures the gap: for each request, what name would the AuthPolicy
# have authorized, and which model actually answered.
#
# Requires the real backends (not the echo swap).
#
# Usage: ./probe-authz-split.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"
NS="${NS:-lora-budget}"
OUT="${SCRIPT_DIR}/golden/authz-split.tsv"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

GATEWAY_URL="${GATEWAY_URL:-http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
    -o jsonpath='{.status.addresses[0].value}')}"

Q="publishers/${NS}/models"

# path | header | body-model | what the AuthPolicy would SAR on | note
PROBES=$(cat <<EOF
/publishers/${NS}/models/model-a/v1/chat/completions||${Q}/model-a|models:${Q}/model-a|control: path and body agree
/publishers/${NS}/models/model-a/v1/chat/completions||${Q}/adapter-a1|models:${Q}/model-a|ESCALATION: authorized on base, served adapter
/publishers/${NS}/models/model-a/v1/chat/completions||${Q}/adapter-a2|models:${Q}/model-a|ESCALATION: authorized on base, served adapter
/publishers/${NS}/models/model-a/v1/chat/completions||adapter-a2|models:${Q}/model-a|ESCALATION: bare adapter name in body
/publishers/${NS}/models/model-a/v1/chat/completions||${Q}/model-b|models:${Q}/model-a|bound: other service's base is not loaded here
/publishers/${NS}/models/model-a/v1/chat/completions||${Q}/shared-adapter|models:${Q}/model-a|bound: other service's adapter is not loaded here
/publishers/${NS}/models/adapter-a1/v1/chat/completions||${Q}/adapter-a1|models:${Q}/adapter-a1|is an adapter addressable by path at all?
/${NS}/svc-a/v1/chat/completions||${Q}/adapter-a2|llminferenceservices:svc-a|ESCALATION: authorized on the service, served adapter
/v1/chat/completions|${Q}/model-a|${Q}/adapter-a2|DENIED by deny-misrouted-model-header|header axis, for comparison
/v1/chat/completions|${Q}/adapter-a1|${Q}/model-a|DENIED by deny-misrouted-model-header|header axis, for comparison
/publishers/${NS}/models/model-a/v1/chat/completions|${Q}/model-b|${Q}/adapter-a1|models:${Q}/model-a|bound: header does not hijack a publisher path
/publishers/${NS}/models/model-a/v1/chat/completions|${Q}/model-b|${Q}/model-b|models:${Q}/model-a|bound: proof it stayed on svc-a
EOF
)

echo -e "${BOLD}authz split probe${NC}   gateway ${GATEWAY_URL}"
printf '  %-52s %-34s %-6s %s\n' 'path' 'body model' 'code' 'served'
printf '  %-52s %-34s %-6s %s\n' ---------------------------------------------------- ---------------------------------- ------ ------
: >"$OUT"

while IFS='|' read -r path hdr body sar note; do
    [[ -z "$path" ]] && continue
    tmp=$(mktemp)
    args=(-s -o "$tmp" -w '%{http_code}' -X POST --max-time 90 -H 'Content-Type: application/json')
    [[ -n "$hdr" ]] && args+=(-H "X-Gateway-Model-Name: ${hdr}")
    args+=(-d "{\"model\":\"${body}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}")
    status=$(curl "${args[@]}" "${GATEWAY_URL}${path}" 2>/dev/null || echo 000)

    served=$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print(open(sys.argv[1]).read()[:60].replace(chr(10)," ") or "(empty)"); raise SystemExit
if "headers" in d and "path" in d and "model" not in d:
    print("NO KSERVE ROUTE (fell through to echo-neighbour)"); raise SystemExit
print(d.get("model") or (d.get("error") or {}).get("message","")[:60] or d.get("message","")[:60] or "(no model)")' "$tmp")
    rm -f "$tmp"

    colour="$GREEN"; [[ "$status" =~ ^[45] ]] && colour="$YEL"
    printf "  %-52s %-34s ${colour}%-6s${NC} %s\n" "${path:0:52}" "${body:0:34}" "$status" "${served:0:60}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "${hdr:--}" "$body" "$sar" "$status" "$served" >>"$OUT"
done <<<"$PROBES"

echo
echo -e "  ${CYAN}INFO${NC}: recorded golden/authz-split.tsv"
