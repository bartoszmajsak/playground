#!/usr/bin/env bash
# Provision the pinned kind + Istio environment for the LoRA routing validator
# and deploy the controller image recorded by build.sh.
#
# Usage:
#   ./setup.sh kind-istio            # new isolated cluster + full stack
#   ./setup.sh kind-istio --reuse    # reuse the current run's cluster,
#                                    # re-deploy the controller image + fixture
#
# The cluster, namespaces and kubeconfig are run-scoped: nothing reads from or
# writes to the caller's kubeconfig or current context. All state lands in
# artifacts/<run-id>/.
#
# Environment:
#   LLMISVC_IMAGE  must match artifacts/build-manifest.json if set (exit 2
#                  otherwise) — the manifest is the source of truth.
#   ADAPTER_COUNT  adapters seeded into the fixture PVC (default 100)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ENV_NAME="${1:-}"
[[ "$ENV_NAME" == "kind-istio" ]] || die "usage: setup.sh kind-istio [--reuse] (got '${ENV_NAME:-<none>}')"
shift
REUSE=false
if [[ "${1:-}" == "--reuse" ]]; then REUSE=true; fi

require_bins kind kubectl helm docker curl python3 git
ADAPTER_COUNT="${ADAPTER_COUNT:-100}"
FIXTURE_NS="lora-fixture"
FIXTURE_PVC="lora-adapters"

# ---------------------------------------------------------------------------
# Build manifest is the source of truth for the image
# ---------------------------------------------------------------------------
MANIFEST="${ARTIFACTS_ROOT}/build-manifest.json"
[[ -f "$MANIFEST" ]] || die "no build manifest; run build.sh first"
IMAGE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["image"])' "$MANIFEST")"
IMAGE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["imageId"])' "$MANIFEST")"
KSERVE_SRC="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"])' "$MANIFEST")"
if [[ -n "${LLMISVC_IMAGE:-}" && "$LLMISVC_IMAGE" != "$IMAGE" ]]; then
    die "LLMISVC_IMAGE=${LLMISVC_IMAGE} does not match the build manifest image ${IMAGE}"
fi
docker image inspect "$IMAGE" -f '{{.Id}}' 2>/dev/null | grep -qx "$IMAGE_ID" \
    || die "local image ${IMAGE} does not match the recorded build (rebuild with build.sh)"

# ---------------------------------------------------------------------------
# Run identity
# ---------------------------------------------------------------------------
if $REUSE; then
    load_run
    guard_cluster
    info "reusing run ${RUN_ID} (cluster ${CLUSTER_NAME})"
else
    RUN_ID="$(new_run_id)"
    RUN_DIR="$(run_dir "$RUN_ID")"
    mkdir -p "$RUN_DIR"/{resources,logs}
    KUBECONFIG_PATH="${RUN_DIR}/kubeconfig"
    CLUSTER_NAME="lora-rt-$(echo "$RUN_ID" | tail -c 9)"
    echo "$RUN_ID" > "${ARTIFACTS_ROOT}/current-run"
    meta_set "$RUN_DIR" runId "$RUN_ID"
    meta_set "$RUN_DIR" cluster "$CLUSTER_NAME"
    meta_set "$RUN_DIR" environment "kind-istio"
    info "new run ${RUN_ID} (cluster ${CLUSTER_NAME})"
fi
meta_set "$RUN_DIR" image "$IMAGE"
meta_set "$RUN_DIR" imageId "$IMAGE_ID"
meta_set "$RUN_DIR" kserveSource "$KSERVE_SRC"
meta_set "$RUN_DIR" kserveCommit "$(git -C "$KSERVE_SRC" rev-parse HEAD)"
meta_set "$RUN_DIR" adapterCount "$ADAPTER_COUNT"

# Pinned dependency versions, tracked from the checkout under test.
deps="$(cat "${KSERVE_SRC}/kserve-deps.env" 2>/dev/null || true)"
if [[ -n "$deps" ]]; then eval "$(echo "$deps" | grep -E '^[A-Z_]+=' | grep -v '^OVERRIDE_' | sed 's/^/export /')"; fi
GWAPI_VERSION="${GWAPI_VERSION:-${GATEWAY_API_VERSION:-v1.5.1}}"
CERTMGR_VERSION="${CERTMGR_VERSION:-${CERT_MANAGER_VERSION:-v1.17.0}}"
LWS_VERSION="${LWS_VERSION:-v0.8.0}"
# NOT kserve-deps.env's ISTIO_VERSION (currently <1.29): Istio below 1.29
# installs the ext_proc filter as a placeholder and the endpoint picker is
# never invoked while everything reports healthy.
ISTIO_PIN="${ISTIO_VERSION_OVERRIDE:-1.30.3}"
meta_set "$RUN_DIR" versions "{\"gatewayAPI\":\"${GWAPI_VERSION}\",\"certManager\":\"${CERTMGR_VERSION}\",\"istio\":\"${ISTIO_PIN}\",\"lws\":\"${LWS_VERSION}\"}"

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
if ! $REUSE; then
    info "kind cluster ${CLUSTER_NAME}"
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then die "cluster ${CLUSTER_NAME} already exists"; fi
    kind create cluster --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_PATH" --wait 120s >/dev/null
    chmod 600 "$KUBECONFIG_PATH"
    ok "created (kubeconfig ${KUBECONFIG_PATH})"
fi
guard_cluster

if ! $REUSE; then
    info "MetalLB"
    kc apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml >/dev/null
    kc -n metallb-system wait --timeout=180s deployment/controller --for=condition=Available >/dev/null \
        || die "MetalLB controller not ready"
    subnet=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -v ':' | head -1)
    base=$(echo "${subnet:-172.18.0.0/16}" | cut -d. -f1-2)
    node_ip=$(docker inspect "${CLUSTER_NAME}-control-plane" -f '{{.NetworkSettings.Networks.kind.IPAddress}}')
    lb_ip="${base}.255.${node_ip##*.}"
    kc apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: kind-pool, namespace: metallb-system}
spec:
  addresses: ["${lb_ip}/32"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: kind-l2, namespace: metallb-system}
EOF
    ok "pool ${lb_ip}"

    info "Gateway API ${GWAPI_VERSION}"
    kc apply --server-side=true --force-conflicts \
        -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/standard-install.yaml" >/dev/null
    ok "installed"

    info "cert-manager ${CERTMGR_VERSION}"
    kc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERTMGR_VERSION}/cert-manager.yaml" >/dev/null
    kc -n cert-manager wait --timeout=300s --for=condition=Available \
        deployment/cert-manager deployment/cert-manager-webhook deployment/cert-manager-cainjector >/dev/null \
        || die "cert-manager not ready"
    ok "ready"

    info "inference extension CRDs (from checkout) and LWS ${LWS_VERSION}"
    kc apply --server-side=true --force-conflicts \
        -f "${KSERVE_SRC}/config/llmisvc/gateway-inference-extension.yaml" >/dev/null
    kc apply --server-side -f "https://github.com/kubernetes-sigs/lws/releases/download/${LWS_VERSION}/manifests.yaml" >/dev/null
    kc -n lws-system wait --timeout=180s deployment/lws-controller-manager --for=condition=Available >/dev/null \
        || die "LWS controller not ready"
    ok "installed"

    info "Istio ${ISTIO_PIN}"
    helm --kubeconfig "$KUBECONFIG_PATH" repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
    helm --kubeconfig "$KUBECONFIG_PATH" repo update istio >/dev/null
    kc create namespace istio-system >/dev/null 2>&1 || true
    helm --kubeconfig "$KUBECONFIG_PATH" upgrade -i istio-base istio/base -n istio-system --version "$ISTIO_PIN" --wait >/dev/null
    # Both flags below: without them Istio refuses every InferencePool
    # backendRef with ResolvedRefs=InvalidKind.
    helm --kubeconfig "$KUBECONFIG_PATH" upgrade -i istiod istio/istiod -n istio-system --version "$ISTIO_PIN" \
        --set resources.requests.cpu=5m --set resources.requests.memory=32Mi \
        --set pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
        --set pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true --wait >/dev/null
    kc -n istio-system wait --timeout=180s deployment/istiod --for=condition=Available >/dev/null || die "istiod not ready"
    ok "ready"

    info "Gateway kserve/kserve-ingress-gateway"
    kc create namespace kserve >/dev/null 2>&1 || true
    kc apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: kserve-ingress-gateway, namespace: kserve}
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces: {from: All}
  infrastructure:
    labels:
      serving.kserve.io/gateway: kserve-ingress-gateway
EOF
    ok "created"
fi

# ---------------------------------------------------------------------------
# KServe llmisvc from the checkout under test
# ---------------------------------------------------------------------------
info "kserve llmisvc CRDs + config (local checkout)"
kc apply --server-side=true --force-conflicts -k "${KSERVE_SRC}/config/crd/full/llmisvc" >/dev/null
for crd in llminferenceserviceconfigs.serving.kserve.io llminferenceservices.serving.kserve.io; do
    for _ in $(seq 30); do
        if kc get "crd/${crd}" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' \
            2>/dev/null | grep -q True; then break; fi
        sleep 2
    done
    kc get "crd/${crd}" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' \
        2>/dev/null | grep -q True || die "CRD ${crd} never became Established"
done
kc apply -f "${KSERVE_SRC}/config/configmap/inferenceservice.yaml" >/dev/null 2>&1 || true
kc apply -f "${KSERVE_SRC}/config/certmanager/issuer.yaml" >/dev/null || die "failed to install the selfsigned issuer"

# Point the ingress config at the gateway; leave loraModelRoutingStrategy to
# the tests (the strategy fixture snapshots and restores it per test).
ingress_json=$(kc get configmap inferenceservice-config -n kserve -o jsonpath='{.data.ingress}' 2>/dev/null || echo '{}')
patched=$(python3 - "$ingress_json" <<'PY'
import json, sys
cfg = json.loads(sys.argv[1] or "{}")
cfg["kserveIngressGateway"] = "kserve/kserve-ingress-gateway"
cfg["enableGatewayApi"] = True
print(json.dumps(cfg))
PY
)
kc patch configmap inferenceservice-config -n kserve --type merge \
    -p "{\"data\":{\"ingress\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$patched")}}" >/dev/null

info "controller (${IMAGE})"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME" >/dev/null
apply_out=$(kc apply --server-side=true --force-conflicts -k "${KSERVE_SRC}/config/llmisvc" 2>&1) || true
if echo "$apply_out" | grep -q 'no matches for kind'; then die "kserve llmisvc kustomize needs a missing CRD"; fi
kc -n kserve set image deployment/llmisvc-controller-manager "manager=${IMAGE}" >/dev/null
# Strategic merge: a plain JSON merge patch would replace the containers list
# wholesale and drop the image field.
kc -n kserve patch deployment llmisvc-controller-manager --type strategic \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"manager","imagePullPolicy":"IfNotPresent"}]}}}}' >/dev/null

kc -n kserve wait --timeout=180s --for=condition=Ready certificate/llmisvc-serving-cert >/dev/null \
    || die "serving cert never issued"
if kc get pods -n kserve -l control-plane=llmisvc-controller-manager \
    -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Pending; then
    kc delete pods -n kserve -l control-plane=llmisvc-controller-manager --wait=false >/dev/null
fi
kc rollout status deployment/llmisvc-controller-manager -n kserve --timeout=300s >/dev/null \
    || die "llmisvc controller not ready"

deployed_image="$(kc -n kserve get deployment llmisvc-controller-manager \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].image}')"
[[ "$deployed_image" == "$IMAGE" ]] || die "deployed image ${deployed_image} != manifest image ${IMAGE}"

# Deployment Available is not the webhook accepting connections, and endpoint
# readiness can reflect a pod that is being replaced. Retry the presets apply
# itself until the validating webhook answers.
presets_ok=false
presets_out=""
for _ in $(seq 30); do
    if presets_out=$(kc apply --server-side=true --force-conflicts -k "${KSERVE_SRC}/config/llmisvcconfig" 2>&1); then
        presets_ok=true
        break
    fi
    sleep 4
done
if ! $presets_ok; then
    echo "$presets_out" | tail -3
    die "failed to install llmisvcconfig presets (webhook never became reachable)"
fi
ok "controller ready"

# ---------------------------------------------------------------------------
# LoRA fixture: PVC seeded with deterministic no-op adapters
# ---------------------------------------------------------------------------
info "fixture namespace ${FIXTURE_NS} with ${ADAPTER_COUNT} adapters"
kc create namespace "$FIXTURE_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -n "$FIXTURE_NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: ${FIXTURE_PVC}}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: 512Mi}
EOF

mapfile -t ADAPTER_NAMES < <(python3 "${SCRIPT_DIR}/hack/gen-names.py" "$ADAPTER_COUNT")
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
"${SCRIPT_DIR}/hack/gen-adapter.py" "${STAGE}/adapters" "${ADAPTER_NAMES[@]}" >/dev/null
( cd "$STAGE" && find adapters -type f | sort | xargs sha256sum ) > "${STAGE}/fixture-digest.txt"
fixture_digest="$(sha256sum "${STAGE}/fixture-digest.txt" | cut -d' ' -f1)"
meta_set "$RUN_DIR" fixtureDigest "$fixture_digest"
printf '%s\n' "${ADAPTER_NAMES[@]}" > "${RUN_DIR}/resources/adapter-names.txt"

kc apply -n "$FIXTURE_NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: lora-seeder}
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts: [{name: models, mountPath: /models}]
  volumes:
    - name: models
      persistentVolumeClaim: {claimName: ${FIXTURE_PVC}}
EOF
kc -n "$FIXTURE_NS" wait --for=condition=Ready pod/lora-seeder --timeout=300s >/dev/null
tar -C "$STAGE" -cf - adapters | kc exec -i -n "$FIXTURE_NS" lora-seeder -- tar -C /models -xf -
# Count adapter directories, not top-level entries: org-prefixed names such as
# acme/billing-... nest one level deeper.
seeded=$(kc exec -n "$FIXTURE_NS" lora-seeder -- sh -c 'find /models/adapters -name adapter_config.json | wc -l')
kc delete pod lora-seeder -n "$FIXTURE_NS" --wait=false >/dev/null 2>&1 || true
[[ "$seeded" -eq "$ADAPTER_COUNT" ]] || die "seeded ${seeded} adapter dirs, expected ${ADAPTER_COUNT}"
ok "seeded ${seeded} adapters (digest ${fixture_digest:0:12})"

GW="$(gateway_url)"
meta_set "$RUN_DIR" gatewayURL "$GW"
meta_set "$RUN_DIR" fixtureNamespace "$FIXTURE_NS"
meta_set "$RUN_DIR" fixturePVC "$FIXTURE_PVC"
meta_set "$RUN_DIR" setupCompletedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf '\n%bready%b\n\n' "$BOLD" "$NC"
cat <<EOF
  run        ${RUN_ID}
  cluster    ${CLUSTER_NAME}
  gateway    ${GW}
  kubeconfig ${KUBECONFIG_PATH}

  next: ./validate.sh --scenario smoke
EOF
