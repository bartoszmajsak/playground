#!/usr/bin/env bash
# Brings up the MaaS gateway chain on kind and adds a scheduler-backed
# LLMInferenceService to it: kind + Istio (native InferencePool) + Kuadrant
# (wasm-shim auth) + MaaS (maas-api, maas-controller, payload-processing
# ext_procs) + the ODH llmisvc controller + a simulator model with an EPP.
#
# Usage:
#   ./setup.sh                 # ~15 min on a warm image cache
#   ./setup.sh --teardown      # delete the kind cluster
#   KUADRANT_VERSION=1.4.7 CLUSTER_NAME=maas-epp-ctl-spike METALLB_SLOT=1 ./setup.sh
#                              # control: WasmPlugin-based Kuadrant, EPP invoked without a fix
#
# Everything version-shaped is an env override; see lib.sh. The MaaS stack is
# installed by vendor/local-deploy.sh, a patched copy of the MaaS repo's own
# kind installer (patches/local-deploy.upstream.diff lists the changes).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
docker_socket_guard
STATUS_ON_ERR=1
trap on_error ERR

vendored_env() {
    env KUBECONFIG="$KUBECONFIG" \
        KIND_CLUSTER_NAME="$CLUSTER_NAME" \
        ISTIO_VERSION="$ISTIO_VERSION" \
        KUADRANT_VERSION="$KUADRANT_VERSION" \
        GATEWAY_API_VERSION="$GATEWAY_API_VERSION" \
        CERTMANAGER_VERSION="$CERTMANAGER_VERSION" \
        GATEWAY_NAMESPACE="$GATEWAY_NAMESPACE" \
        MAAS_NAMESPACE="$MAAS_NAMESPACE" \
        METALLB_SLOT="$METALLB_SLOT" \
        KSERVE_CLONE="$KSERVE_CLONE" \
        KSERVE_ODH_REF="$KSERVE_ODH_REF" \
        MAAS_REPO="$MAAS_REPO" \
        ISTIO_OPERATOR_FILE="${MANIFESTS}/istio-operator.yaml" \
        mise x "istioctl@${ISTIO_VERSION}" -- bash "${SCRIPT_DIR}/vendor/local-deploy.sh" "$@"
}

if [[ "${1:-}" == "--teardown" ]]; then
    vendored_env --teardown
    rm -f "$KUBECONFIG"
    exit 0
fi

step "Preflight"
for tool in kind kubectl kustomize helm jq yq python3 gh mise docker curl; do
    command -v "$tool" >/dev/null 2>&1 || err "missing tool: $tool"
done
[[ -d "$MAAS_REPO/deployment/base/payload-processing" ]] \
    || err "MAAS_REPO=$MAAS_REPO is not a models-as-a-service checkout"
mise install "istioctl@${ISTIO_VERSION}" >/dev/null 2>&1 || true
[[ "$(istioctl_pinned version --remote=false 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" == "$ISTIO_VERSION" ]] \
    || err "mise cannot provide istioctl ${ISTIO_VERSION}"
helm repo add kuadrant https://kuadrant.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update kuadrant >/dev/null 2>&1
[[ "$(helm search repo kuadrant/kuadrant-operator --version "$KUADRANT_VERSION" -o json | jq length)" == "1" ]] \
    || err "kuadrant-operator chart ${KUADRANT_VERSION} is not in the helm index"
ok "istioctl ${ISTIO_VERSION}, kuadrant-operator chart ${KUADRANT_VERSION}, MaaS checkout $(git -C "$MAAS_REPO" rev-parse --short=12 HEAD)"

mkdir -p "$RESULTS/setup"

step "MaaS stack via the vendored installer (cluster ${CLUSTER_NAME})"
vendored_env 2>&1 | tee "$RESULTS/setup/local-deploy.log"
kind get kubeconfig --name "$CLUSTER_NAME" > "$KUBECONFIG"
ok "MaaS stack up; log at $RESULTS/setup/local-deploy.log"

step "Model namespace ${NS}"
kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
# The Gateway admits routes from labelled namespaces only.
kc label namespace "$NS" maas.opendatahub.io/gateway-access=true --overwrite >/dev/null
render_manifest "$MANIFESTS/metrics-reader.yaml" | kc apply -f - >/dev/null
ok "namespace labelled for gateway access, metrics-reader in place"

step "LLMInferenceService ${LLMISVC_NAME} with a scheduler (backend ${MODEL_BACKEND})"
if [[ "$MODEL_BACKEND" == "vllm-cpu" ]]; then
    # The CPU image is several GB; hand it to the node from the host cache
    # rather than pulling it three times over the network.
    if docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1 \
       && ! docker exec "${CLUSTER_NAME}-control-plane" crictl images -q "docker.io/${VLLM_IMAGE}" 2>/dev/null | grep -q .; then
        substep "loading ${VLLM_IMAGE} into the kind node"
        kind load docker-image "$VLLM_IMAGE" --name "$CLUSTER_NAME" >/dev/null
    fi
    render_manifest "$MANIFESTS/llmisvc-vllm.yaml" | kc apply -f - >/dev/null
    wait_llmisvc_ready "$LLMISVC_NAME" "$NS" 1200 || err "llmisvc ${NS}/${LLMISVC_NAME} not Ready"
else
    render_manifest "$MANIFESTS/llmisvc-sim.yaml" | kc apply -f - >/dev/null
    wait_llmisvc_ready "$LLMISVC_NAME" "$NS" 600 || err "llmisvc ${NS}/${LLMISVC_NAME} not Ready"
fi
ok "llmisvc Ready"
wait_for_field "inferencepool/${LLMISVC_NAME}-inference-pool" "$NS" \
    '{.status.parents[0].conditions[?(@.type=="Accepted")].status}' True 180 >/dev/null \
    || err "InferencePool ${LLMISVC_NAME}-inference-pool not Accepted"
wait_for_field "httproute/${LLMISVC_NAME}-kserve-route" "$NS" \
    '{.status.parents[0].conditions[?(@.type=="Accepted")].status}' True 180 >/dev/null \
    || err "HTTPRoute ${LLMISVC_NAME}-kserve-route not Accepted by ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}"
ok "InferencePool Accepted, HTTPRoute Accepted"
# The preset only enables TLS on the picker when the global config asks for
# it; the DestinationRule is right in exactly that case and wrong otherwise.
if kc get deploy "${LLMISVC_NAME}-kserve-router-scheduler" -n "$NS" -o json 2>/dev/null \
    | jq -r '.spec.template.spec.containers[].args[]?' | grep -q -- '--secure-serving=true'; then
    render_manifest "$MANIFESTS/epp-destinationrule.yaml" | kc apply -f - >/dev/null
    ok "EPP serves TLS: DestinationRule applied"
else
    substep "EPP serves plaintext, no DestinationRule"
fi

step "MaaS registration (MaaSModelRef, MaaSSubscription, MaaSAuthPolicy)"
render_manifest "$MANIFESTS/maas-registration.yaml" | kc apply -f - >/dev/null
wait_for_field "maasmodelref/${LLMISVC_NAME}" "$NS" '{.status.phase}' Ready 300 >/dev/null \
    || err "MaaSModelRef ${NS}/${LLMISVC_NAME} not Ready: $(kc get maasmodelref "$LLMISVC_NAME" -n "$NS" -o jsonpath='{.status}')"
# MaaS keeps one gateway-level AuthPolicy; per model it renders a
# TokenRateLimitPolicy in the model namespace.
wait_for_field "tokenratelimitpolicy/maas-trlp-${LLMISVC_NAME}" "$NS" \
    '{.status.conditions[?(@.type=="Enforced")].status}' True 300 >/dev/null \
    || err "TokenRateLimitPolicy maas-trlp-${LLMISVC_NAME} not Enforced in ${NS}"
deadline=$(( $(date +%s) + 300 ))
while (( $(date +%s) < deadline )); do
    enforced=$(kc get authpolicy -n "$GATEWAY_NAMESPACE" -o json 2>/dev/null \
        | jq -r '[.items[] | select(any(.status.conditions[]?; .type=="Enforced" and .status=="True"))] | length')
    [[ "${enforced:-0}" -ge 1 ]] && break
    sleep 3
done
[[ "${enforced:-0}" -ge 1 ]] || err "no Enforced AuthPolicy on the gateway in ${GATEWAY_NAMESPACE}"
ok "MaaSModelRef Ready, TokenRateLimitPolicy Enforced, gateway AuthPolicy Enforced"

step "Gateway filter chain"
wait_for_gateway 180 || err "gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME} has no address"
# The diagnostic exits 1 on a BROKEN chain, which is the state this waits for;
# capture its output rather than piping it, or pipefail hides the answer.
chain_ready() {
    local out
    out=$("$SCRIPT_DIR/scripts/check-filter-order.sh" --json 2>/dev/null || true)
    [[ -n "$out" ]] && jq -e '.indices.istio_ext_proc >= 0 and .indices.ipp_pre >= 0 and .indices.ipp >= 0' <<<"$out" >/dev/null 2>&1
}
deadline=$(( $(date +%s) + 300 ))
until chain_ready || (( $(date +%s) >= deadline )); do sleep 3; done
chain_ready || err "chain never showed Istio's ext_proc plus both ipp filters; see scripts/check-filter-order.sh"
# The controller decides between the wasm anchors and the router fallback by
# looking for Kuadrant's object at tenant reconcile time, which can predate
# the first AuthPolicy. A re-render fixes a stale choice.
if [[ "$("$SCRIPT_DIR/scripts/check-filter-order.sh" --json 2>/dev/null | jq -r '.maas_ef.mode')" == "router-fallback" ]]; then
    warn "MaaS EnvoyFilter rendered in router-fallback mode; restarting maas-controller to re-render"
    kc rollout restart deployment/maas-controller -n "$MAAS_NAMESPACE" >/dev/null
    kc rollout status deployment/maas-controller -n "$MAAS_NAMESPACE" --timeout=180s >/dev/null
    deadline=$(( $(date +%s) + 300 ))
    until [[ "$("$SCRIPT_DIR/scripts/check-filter-order.sh" --json 2>/dev/null | jq -r '.maas_ef.mode')" == "wasm-anchored" ]] \
        || (( $(date +%s) >= deadline )); do sleep 3; done
fi
"$SCRIPT_DIR/scripts/check-filter-order.sh" | tee "$RESULTS/setup/diag.txt" || true

step "Smoke: one authenticated body-routed request"
api_key="$(maas_api_key epp-spike-setup)"
[[ -n "$api_key" ]] || err "could not mint a MaaS API key through maas-api"
code=$(curl -s -o "$RESULTS/setup/smoke.json" -w '%{http_code}' --max-time 30 \
    "$(gateway_url)/v1/chat/completions" \
    -H "Authorization: Bearer ${api_key}" -H "Content-Type: application/json" \
    -H "x-req-id: setup-smoke" \
    -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"smoke\"}],\"max_tokens\":5}")
[[ "$code" == "200" ]] || err "smoke request returned HTTP ${code}: $(head -c 300 "$RESULTS/setup/smoke.json")"
ok "HTTP 200 for model ${MODEL_ID} through ${GATEWAY_NAME}"

step "Recording versions"
{
    echo "cluster=${CLUSTER_NAME}"
    echo "istio=${ISTIO_VERSION}"
    echo "istiod_image=$(kc get deploy istiod -n istio-system -o jsonpath='{.spec.template.spec.containers[0].image}')"
    echo "gateway_proxy_image=$(gateway_pod_image)"
    echo "envoy=$(envoy_admin 'server_info' | jq -r .version)"
    echo "kuadrant_chart=${KUADRANT_VERSION}"
    echo "kuadrant_operator_image=$(image_digest kuadrant-system control-plane=controller-manager)"
    if kc get envoyfilter "kuadrant-${GATEWAY_NAME}" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1; then
        echo "kuadrant_wasm_mechanism=envoyfilter"
    elif kc get wasmplugin "kuadrant-${GATEWAY_NAME}" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1; then
        echo "kuadrant_wasm_mechanism=wasmplugin"
    else
        echo "kuadrant_wasm_mechanism=none"
    fi
    echo "kserve_odh_clone=$(git -C "$KSERVE_CLONE" rev-parse HEAD)"
    echo "llmisvc_controller_image=$(image_digest kserve control-plane=llmisvc-controller-manager)"
    echo "gie_bundle=$(kc get crd inferencepools.inference.networking.k8s.io -o jsonpath='{.metadata.annotations.inference\.networking\.k8s\.io/bundle-version}')"
    echo "epp_image=$(kc get pod -n "$NS" -l app.kubernetes.io/component=llminferenceservice-router-scheduler -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="main")].imageID}')"
    echo "model_backend=${MODEL_BACKEND}"
    echo "model=${MODEL_NAME} (${MODEL_URI})"
    echo "model_server_image=$(kc get pod -n "$NS" -l "app.kubernetes.io/name=${LLMISVC_NAME},kserve.io/component=workload" -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="main")].imageID}')"
    echo "ipp_image=$(image_digest "$GATEWAY_NAMESPACE" app=payload-processing)"
    echo "ipp_pre_image=$(image_digest "$GATEWAY_NAMESPACE" app=payload-pre-processing)"
    echo "maas_controller_image=$(image_digest "$MAAS_NAMESPACE" control-plane=maas-controller)"
    echo "maas_api_image=$(image_digest "$MAAS_NAMESPACE" app.kubernetes.io/name=maas-api)"
    echo "maas_repo=$(git -C "$MAAS_REPO" rev-parse HEAD)"
} > "$RESULTS/versions.txt"
ok "$RESULTS/versions.txt"

echo
echo "Next:"
echo "  ./validate.sh --scenario defect      # the EPP is bypassed"
echo "  ./validate.sh --scenario all         # defect, fix, auth-order"
