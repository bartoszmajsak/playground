#!/usr/bin/env bash
# One-screen status of everything the spike depends on. Run it any time; setup.sh
# and validate.sh print it automatically when a step fails.
#
# Usage: scripts/status.sh [--errors N]    (N recent error lines per component, default 3)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/lib.sh"

ERRORS="${2:-3}"
[[ "${1:-}" == "--errors" ]] || ERRORS=3

section() { echo -e "\n${BOLD}$1${NC}"; }

section "Pods not Running/Ready"
kc get pods -A -o json 2>/dev/null | jq -r '
  .items[]
  | select(.status.phase != "Succeeded")
  | select((.status.phase != "Running") or ([.status.containerStatuses[]? | select(.ready|not)] | length > 0))
  | "\(.metadata.namespace)/\(.metadata.name)  phase=\(.status.phase)  " +
    ([.status.containerStatuses[]? | select(.ready|not) | "\(.name): \(.state | to_entries[0] | "\(.key) \(.value.reason // "")")"] | join(", ")) +
    "  restarts=\([.status.containerStatuses[]?.restartCount] | add // 0)"' \
  | sed 's/^/  /' | { grep . || echo "  (none)"; }

section "Deployments (ready/desired)"
for spec in "istio-system/istiod" "istio-system/maas-default-gateway-istio" "istio-system/payload-pre-processing" \
            "istio-system/payload-processing" "${MAAS_NAMESPACE}/maas-api" "${MAAS_NAMESPACE}/maas-controller" \
            "kuadrant-system/authorino" "kuadrant-system/limitador-limitador" "kuadrant-system/kuadrant-operator-controller-manager" \
            "kserve/llmisvc-controller-manager" "${NS}/${LLMISVC_NAME}-kserve-router-scheduler" "${NS}/${LLMISVC_NAME}-kserve"; do
    ns="${spec%%/*}"; name="${spec##*/}"
    printf '  %-58s %s\n' "$spec" "$(kc get deploy "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo missing)"
done

section "Gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}"
echo "  address: $(gateway_url || echo none)   pod: $(gateway_pod || echo none)   image: $(gateway_pod_image 2>/dev/null || echo ?)"
kc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o json 2>/dev/null | jq -r '
  .status.listeners[]? | "  listener \(.name): " + ([.conditions[] | "\(.type)=\(.status)"] | join(" "))'

section "Model ${NS}/${LLMISVC_NAME}"
kc get llmisvc "$LLMISVC_NAME" -n "$NS" -o json 2>/dev/null | jq -r '
  "  llmisvc: " + ([.status.conditions[]? | "\(.type)=\(.status)" + (if .status != "True" then " (\(.reason // ""): \(.message // "" | .[0:80]))" else "" end)] | join("  "))' \
  || echo "  llmisvc: missing"
echo "  inferencepool Accepted: $(kc get inferencepool "${LLMISVC_NAME}-inference-pool" -n "$NS" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo missing)"
kc get httproute -A -o json 2>/dev/null | jq -r '
  .items[] | "  httproute \(.metadata.namespace)/\(.metadata.name): " +
  ([.status.parents[]? | "\(.parentRef.namespace // "")/\(.parentRef.name) " + ([.conditions[] | "\(.type)=\(.status)"] | join(" "))] | join(" | "))'
kc get maasmodelref -A -o json 2>/dev/null | jq -r '.items[] | "  maasmodelref \(.metadata.namespace)/\(.metadata.name): \(.status.phase // "?") \(.status.message // "")"'
kc get maassubscription,maasauthpolicy -A -o json 2>/dev/null | jq -r '.items[] | "  \(.kind|ascii_downcase) \(.metadata.namespace)/\(.metadata.name): \(.status.phase // "?")"'
kc get authpolicy,tokenratelimitpolicy -A -o json 2>/dev/null | jq -r '
  .items[] | "  \(.kind) \(.metadata.namespace)/\(.metadata.name): Enforced=\([.status.conditions[]? | select(.type=="Enforced") | .status] | first // "?")"'

section "EnvoyFilters in ${GATEWAY_NAMESPACE} and the chain"
kc get envoyfilter -n "$GATEWAY_NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | "  \(.metadata.name)  priority=\(.spec.priority // 0)"'
echo "  wasmplugins: $(kc get wasmplugin -n "$GATEWAY_NAMESPACE" -o name 2>/dev/null | tr '\n' ' ')"
# The diagnostic exits 1 on BROKEN, which is a result here, not a failure.
diag="$("$SCRIPT_DIR/scripts/check-filter-order.sh" --json 2>/dev/null || true)"
if [[ -n "$diag" ]]; then
    jq -r '"  chain: " + (.chain | join(" > ")) + "\n  verdict EPP_ENGAGED=\(.verdicts.EPP_ENGAGED)  auth=\(.auth_mechanism)  maas_ef=\(.maas_ef.mode)  duplicates=\(.verdicts.NO_DUPLICATES)"' <<<"$diag"
else
    echo "  chain: diagnostic produced no output"
fi

section "Recent errors (last ${ERRORS} per component)"
errs() {
    local label="$1" ns="$2" sel="$3" out
    out=$(kc logs -n "$ns" -l "$sel" --all-containers --tail=300 --since=15m 2>/dev/null \
        | grep -iE '"level":"error"|level=error|\berror\b|panic|CrashLoop' | grep -viE 'level":"info"' | tail -n "$ERRORS" | cut -c1-220)
    if [[ -n "$out" ]]; then echo "  [$label]"; echo "$out" | sed 's/^/    /'; fi
}
errs maas-controller "$MAAS_NAMESPACE" control-plane=maas-controller
errs maas-api "$MAAS_NAMESPACE" app.kubernetes.io/name=maas-api
errs llmisvc-controller kserve control-plane=llmisvc-controller-manager
errs istiod istio-system app=istiod
errs ipp-pre "$GATEWAY_NAMESPACE" app=payload-pre-processing
errs ipp "$GATEWAY_NAMESPACE" app=payload-processing
errs epp "$NS" app.kubernetes.io/component=llminferenceservice-router-scheduler
errs authorino kuadrant-system app=authorino
echo
