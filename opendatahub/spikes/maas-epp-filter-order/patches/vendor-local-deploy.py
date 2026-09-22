#!/usr/bin/env python3
"""Produce vendor/local-deploy.sh from the upstream MaaS installer.

Usage: vendor-local-deploy.py <upstream local-deploy.sh> <output>

Every edit names the upstream text it replaces and fails if that text is not
found exactly once, so a refresh against a newer upstream surfaces drift
instead of silently skipping a patch. The list doubles as the change log for
the upstream proposal in local-deploy.upstream.diff.
"""
import sys

EDITS = [
    # 0. Provenance.
    (
        "# Deploy MaaS platform locally on a Kind cluster (macOS + Linux/WSL2).\n",
        "# Deploy MaaS platform locally on a Kind cluster (macOS + Linux/WSL2).\n"
        "#\n"
        "# VENDORED COPY for the maas-epp-filter-order spike. Upstream:\n"
        "#   models-as-a-service/test/e2e/scripts/local-deploy.sh\n"
        "# Regenerate with patches/vendor-local-deploy.py; the edits are listed there\n"
        "# and diffed into patches/local-deploy.upstream.diff.\n",
    ),
    # 1. The script is no longer inside the MaaS checkout.
    (
        'PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"\n',
        'PROJECT_ROOT="${MAAS_REPO:?MAAS_REPO must point at a models-as-a-service checkout}"\n'
        'SPIKE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"\n',
    ),
    # 1b. Never delete a cluster on a failed reachability probe: a transient
    #     API hiccup would otherwise wipe an hour of state. Fail and let the
    #     operator decide.
    (
        '    warn "Cluster exists but unreachable, recreating..."\n'
        '    kind delete cluster --name "$KIND_CLUSTER_NAME"\n'
        '  fi\n',
        '    fail "Cluster \'${KIND_CLUSTER_NAME}\' exists but is unreachable; not recreating it. Fix the kubeconfig or run --teardown first."\n'
        '    exit 1\n'
        '  fi\n',
    ),
    # 2. Kuadrant >= 1.5 injects the wasm-shim through an EnvoyFilter anchored on
    #    the router, which is the RHCL 1.4 data plane this spike reproduces.
    (
        'KUADRANT_VERSION="${KUADRANT_VERSION:-1.3.1}"  # matches MaaS install-dependencies.sh\n',
        'KUADRANT_VERSION="${KUADRANT_VERSION:-1.5.3}"  # >=1.5.0: wasm via EnvoyFilter (RHCL 1.4); 1.4.x: WasmPlugin CR\n'
        'METALLB_SLOT="${METALLB_SLOT:-0}"  # LB pool 172.18.<slot>.200-250, so spike clusters can coexist\n'
        'ISTIO_OPERATOR_FILE="${ISTIO_OPERATOR_FILE:-$SPIKE_DIR/manifests/istio-operator.yaml}"\n',
    ),
    # 3. LLMISVC CRDs come from the same clone as the controller. The pinned
    #    commit serves only v1alpha1 while the controller from the default
    #    branch stores v1alpha2.
    (
        'KSERVE_COMMIT="47894470ea49"  # opendatahub fork commit pinned in maas-controller go.mod\n'
        'LLMISVC_IMAGE="quay.io/opendatahub/odh-kserve-llmisvc-controller:odh-stable"\n',
        '# CRDs, controller manifests and the GIE CRD bundle all come from one clone\n'
        '# of the opendatahub fork, so they cannot disagree on API versions.\n'
        'KSERVE_CLONE="${KSERVE_CLONE:-/tmp/opendatahub-kserve}"\n'
        'KSERVE_ODH_REF="${KSERVE_ODH_REF:-}"  # empty = default branch\n'
        'LLMISVC_IMAGE="${LLMISVC_IMAGE:-quay.io/opendatahub/odh-kserve-llmisvc-controller:odh-stable}"\n',
    ),
    # 4. istioctl: compare the version, not just presence. A different istioctl
    #    on PATH installs a different Istio while printing ISTIO_VERSION.
    (
        '# istioctl — install inline if missing\n'
        'if ! command -v istioctl &>/dev/null; then\n'
        '  warn "istioctl not found, installing ${ISTIO_VERSION}..."\n'
        '  curl -sL https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh -\n'
        '  export PATH="$PWD/istio-${ISTIO_VERSION}/bin:$PATH"\n'
        'fi\n',
        '# istioctl — install inline unless the one on PATH is exactly ISTIO_VERSION\n'
        '_istioctl_ver="$(istioctl version --remote=false 2>/dev/null | grep -oE \'[0-9]+\\.[0-9]+\\.[0-9]+\' | head -1 || true)"\n'
        'if [[ "$_istioctl_ver" != "$ISTIO_VERSION" ]]; then\n'
        '  warn "istioctl ${_istioctl_ver:-not found} on PATH, installing ${ISTIO_VERSION}..."\n'
        '  (cd /tmp && curl -sL https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh - >/dev/null)\n'
        '  export PATH="/tmp/istio-${ISTIO_VERSION}/bin:$PATH"\n'
        'fi\n',
    ),
    # 5. Clone the fork and install the GIE CRDs BEFORE istiod starts: istiod
    #    wires InferencePool support only when the CRDs exist at startup.
    (
        '# ─── Step 3: Istio ──────────────────────────────────────────────────────────\n'
        '\n'
        'step "Installing Istio (minimal profile)"\n'
        '\n'
        'if kubectl get deployment istiod -n istio-system &>/dev/null; then\n'
        '  ok "Istio already installed"\n'
        'else\n'
        '  istioctl install --set profile=minimal \\\n'
        '    --set values.pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true \\\n'
        '    --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \\\n'
        '    -y\n',
        '# ─── Step 2b: opendatahub-io/kserve clone + Inference Extension CRDs ───────\n'
        '\n'
        'step "Cloning opendatahub-io/kserve (llmisvc manifests, CRDs, GIE bundle)"\n'
        '\n'
        'if [[ ! -d "$KSERVE_CLONE/.git" ]]; then\n'
        '  gh repo clone opendatahub-io/kserve "$KSERVE_CLONE" -- --depth 1 2>&1 | tail -1\n'
        'fi\n'
        'if [[ -n "$KSERVE_ODH_REF" ]] && [[ "$(git -C "$KSERVE_CLONE" rev-parse HEAD)" != "$KSERVE_ODH_REF"* ]]; then\n'
        '  git -C "$KSERVE_CLONE" fetch --depth 1 origin "$KSERVE_ODH_REF"\n'
        '  git -C "$KSERVE_CLONE" checkout -q FETCH_HEAD\n'
        'fi\n'
        'ok "opendatahub-io/kserve at $(git -C "$KSERVE_CLONE" rev-parse --short=12 HEAD)"\n'
        '\n'
        '# istiod compiles InferencePool backendRefs into ext_proc only if these CRDs\n'
        '# exist when it starts; installed later they are ignored until a restart.\n'
        'kubectl apply --server-side -f "$KSERVE_CLONE/config/llmisvc/gateway-inference-extension.yaml" 2>&1 | tail -2\n'
        'kubectl wait --for=condition=Established crd/inferencepools.inference.networking.k8s.io --timeout=60s\n'
        'ok "Gateway API Inference Extension CRDs installed"\n'
        '\n'
        '# ─── Step 3: Istio ──────────────────────────────────────────────────────────\n'
        '\n'
        'step "Installing Istio (minimal profile)"\n'
        '\n'
        'if kubectl get deployment istiod -n istio-system &>/dev/null; then\n'
        '  ok "Istio already installed"\n'
        'else\n'
        '  # IstioOperator file rather than --set: the JSON access-log format the\n'
        '  # spike scores against carries commas.\n'
        '  istioctl install -y -f "$ISTIO_OPERATOR_FILE"\n',
    ),
    # 6. MetalLB range per slot.
    (
        '  LB_BASE=$(echo "$KIND_SUBNET" | cut -d\'.\' -f1-3)\n',
        '  LB_BASE="$(echo "$KIND_SUBNET" | cut -d\'.\' -f1-2).${METALLB_SLOT}"\n',
    ),
    # 7. The chart is not configurable; the operator default already is
    #    istio.io/gateway-controller.
    (
        '    --version "$KUADRANT_VERSION" \\\n'
        '    --set manager.env[0].name=ISTIO_GATEWAY_CONTROLLER_NAMES \\\n'
        '    --set manager.env[0].value=istio.io/gateway-controller \\\n'
        '    --wait --timeout 180s\n',
        '    --version "$KUADRANT_VERSION" \\\n'
        '    --wait --timeout 300s\n',
    ),
    # 8. maas-controller hard-mounts two secrets that OpenShift's service-ca
    #    provisions. Issue them from the CA chain created just above.
    (
        '  ok "TLS certificate created for maas-api (CA chain)"\n'
        'fi\n',
        '  ok "TLS certificate created for maas-api (CA chain)"\n'
        'fi\n'
        '\n'
        '# maas-controller mounts maas-controller-webhook-cert and maas-controller-metrics-tls\n'
        '# (deployment/base/maas-controller/manager/manager.yaml), provisioned by service-ca\n'
        '# on OpenShift. Issue both from the same CA so the webhook caBundle can be injected.\n'
        'if kubectl get secret maas-controller-webhook-cert -n "$MAAS_NAMESPACE" &>/dev/null; then\n'
        '  ok "maas-controller certificates already exist"\n'
        'else\n'
        '  kubectl apply -f - <<EOF\n'
        'apiVersion: cert-manager.io/v1\n'
        'kind: Certificate\n'
        'metadata:\n'
        '  name: maas-controller-webhook-server\n'
        '  namespace: ${MAAS_NAMESPACE}\n'
        'spec:\n'
        '  secretName: maas-controller-webhook-cert\n'
        '  commonName: maas-controller-webhook-service.${MAAS_NAMESPACE}.svc\n'
        '  dnsNames:\n'
        '  - maas-controller-webhook-service.${MAAS_NAMESPACE}.svc\n'
        '  - maas-controller-webhook-service.${MAAS_NAMESPACE}.svc.cluster.local\n'
        '  issuerRef:\n'
        '    name: maas-ca-issuer\n'
        '    kind: Issuer\n'
        '  duration: 8760h\n'
        '  renewBefore: 720h\n'
        '---\n'
        'apiVersion: cert-manager.io/v1\n'
        'kind: Certificate\n'
        'metadata:\n'
        '  name: maas-controller-metrics\n'
        '  namespace: ${MAAS_NAMESPACE}\n'
        'spec:\n'
        '  secretName: maas-controller-metrics-tls\n'
        '  commonName: maas-controller-metrics.${MAAS_NAMESPACE}.svc\n'
        '  dnsNames:\n'
        '  - maas-controller-metrics.${MAAS_NAMESPACE}.svc\n'
        '  - maas-controller-metrics.${MAAS_NAMESPACE}.svc.cluster.local\n'
        '  issuerRef:\n'
        '    name: maas-ca-issuer\n'
        '    kind: Issuer\n'
        '  duration: 8760h\n'
        '  renewBefore: 720h\n'
        'EOF\n'
        '  kubectl wait --for=condition=Ready certificate/maas-controller-webhook-server \\\n'
        '    certificate/maas-controller-metrics -n "$MAAS_NAMESPACE" --timeout=60s\n'
        '  ok "TLS certificates created for maas-controller (webhook + metrics)"\n'
        'fi\n',
    ),
    # 9. LLMISVC CRDs from the clone.
    (
        '  kubectl apply --server-side -f \\\n'
        '    "https://raw.githubusercontent.com/opendatahub-io/kserve/${KSERVE_COMMIT}/config/crd/full/serving.kserve.io_llminferenceservices.yaml"\n'
        '  kubectl apply --server-side -f \\\n'
        '    "https://raw.githubusercontent.com/opendatahub-io/kserve/${KSERVE_COMMIT}/config/crd/full/serving.kserve.io_llminferenceserviceconfigs.yaml"\n',
        '  kubectl apply --server-side -f \\\n'
        '    "$KSERVE_CLONE/config/crd/full/llmisvc/serving.kserve.io_llminferenceservices.yaml"\n'
        '  kubectl apply --server-side -f \\\n'
        '    "$KSERVE_CLONE/config/crd/full/llmisvc/serving.kserve.io_llminferenceserviceconfigs.yaml"\n',
    ),
    # 10. The clone already happened in step 2b.
    (
        '  # Clone opendatahub kserve fork to get the deployment manifests\n'
        '  KSERVE_CLONE="/tmp/opendatahub-kserve"\n'
        '  if [[ ! -d "$KSERVE_CLONE" ]]; then\n'
        '    echo "  Cloning opendatahub-io/kserve..."\n'
        '    gh repo clone opendatahub-io/kserve "$KSERVE_CLONE" -- --depth 1 2>&1 | tail -1\n'
        '  fi\n',
        '  # The fork was cloned in step 2b (the GIE CRDs had to precede istiod).\n',
    ),
    # 11. Model namespaces are not the gateway namespace: `from: Same` admits
    #     neither the maas-api route nor any model route. And maas-api only
    #     accepts a gateway Service that exposes port 443
    #     (maas-api/internal/config/cluster_config.go ResolveGatewayInternalHost),
    #     so the Gateway needs an HTTPS listener; Istio derives the Service
    #     ports from the listeners.
    (
        'if kubectl get gateway maas-default-gateway -n "$GATEWAY_NAMESPACE" &>/dev/null; then\n'
        '  ok "Gateway already exists"\n'
        'else\n'
        '  kubectl apply -f - <<EOF\n'
        'apiVersion: gateway.networking.k8s.io/v1\n'
        'kind: Gateway\n'
        'metadata:\n'
        '  name: maas-default-gateway\n'
        '  namespace: ${GATEWAY_NAMESPACE}\n'
        'spec:\n'
        '  gatewayClassName: istio\n'
        '  listeners:\n'
        '  - name: http\n'
        '    port: 80\n'
        '    protocol: HTTP\n'
        '    allowedRoutes:\n'
        '      namespaces:\n'
        '        from: Same\n'
        'EOF\n',
        'if kubectl get gateway maas-default-gateway -n "$GATEWAY_NAMESPACE" &>/dev/null; then\n'
        '  ok "Gateway already exists"\n'
        'else\n'
        '  kubectl apply -f - <<EOF\n'
        'apiVersion: cert-manager.io/v1\n'
        'kind: Certificate\n'
        'metadata:\n'
        '  name: maas-default-gateway-tls\n'
        '  namespace: ${GATEWAY_NAMESPACE}\n'
        'spec:\n'
        '  secretName: maas-default-gateway-tls\n'
        '  commonName: maas-default-gateway-istio.${GATEWAY_NAMESPACE}.svc\n'
        '  dnsNames:\n'
        '  - maas-default-gateway-istio.${GATEWAY_NAMESPACE}.svc\n'
        '  - maas-default-gateway-istio.${GATEWAY_NAMESPACE}.svc.cluster.local\n'
        '  issuerRef:\n'
        '    name: maas-selfsigned-issuer\n'
        '    kind: ClusterIssuer\n'
        '  duration: 8760h\n'
        '---\n'
        'apiVersion: gateway.networking.k8s.io/v1\n'
        'kind: Gateway\n'
        'metadata:\n'
        '  name: maas-default-gateway\n'
        '  namespace: ${GATEWAY_NAMESPACE}\n'
        'spec:\n'
        '  gatewayClassName: istio\n'
        '  listeners:\n'
        '  - name: http\n'
        '    port: 80\n'
        '    protocol: HTTP\n'
        '    allowedRoutes:\n'
        '      namespaces:\n'
        '        from: Selector\n'
        '        selector:\n'
        '          matchLabels:\n'
        '            maas.opendatahub.io/gateway-access: "true"\n'
        '  # maas-api resolves the gateway through a Service port 443; the probes\n'
        '  # themselves follow the model URL scheme.\n'
        '  - name: https\n'
        '    port: 443\n'
        '    protocol: HTTPS\n'
        '    tls:\n'
        '      mode: Terminate\n'
        '      certificateRefs:\n'
        '      - name: maas-default-gateway-tls\n'
        '    allowedRoutes:\n'
        '      namespaces:\n'
        '        from: Selector\n'
        '        selector:\n'
        '          matchLabels:\n'
        '            maas.opendatahub.io/gateway-access: "true"\n'
        'EOF\n',
    ),
    (
        'kubectl create namespace "$SUBSCRIPTION_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -\n',
        'kubectl create namespace "$SUBSCRIPTION_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -\n'
        'kubectl label namespace "$MAAS_NAMESPACE" maas.opendatahub.io/gateway-access=true --overwrite >/dev/null\n',
    ),
    (
        'kubectl create namespace "$MODEL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -\n'
        'kubectl create namespace "$INTERNAL_MODEL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -\n',
        'kubectl create namespace "$MODEL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -\n'
        'kubectl create namespace "$INTERNAL_MODEL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -\n'
        'kubectl label namespace "$MODEL_NAMESPACE" "$INTERNAL_MODEL_NAMESPACE" \\\n'
        '  maas.opendatahub.io/gateway-access=true --overwrite >/dev/null\n',
    ),
    # 11b. The IPP NetworkPolicy admits ingress from openshift-ingress only and
    #      the controller does not rewrite that peer; kind's CNI enforces it, so
    #      the gateway's ext_proc connections time out. NetworkPolicies are
    #      additive, so a second policy opens the gateway namespace without
    #      touching the controller-owned one.
    (
        '  kubectl rollout status deployment/payload-processing -n "$GATEWAY_NAMESPACE" --timeout=180s 2>/dev/null || \\\n'
        '    warn "payload-processing not ready yet"\n'
        'else\n'
        '  warn "payload-processing deployment was not created by maas-controller"\n'
        'fi\n',
        '  kubectl rollout status deployment/payload-processing -n "$GATEWAY_NAMESPACE" --timeout=180s 2>/dev/null || \\\n'
        '    warn "payload-processing not ready yet"\n'
        '  kubectl apply -f - <<EOF\n'
        'apiVersion: networking.k8s.io/v1\n'
        'kind: NetworkPolicy\n'
        'metadata:\n'
        '  name: payload-processing-allow-gateway\n'
        '  namespace: ${GATEWAY_NAMESPACE}\n'
        'spec:\n'
        '  # Only the IPP pods: an empty podSelector would also isolate the\n'
        '  # gateway pod and drop the traffic arriving from outside the cluster.\n'
        '  podSelector:\n'
        '    matchExpressions:\n'
        '    - key: app\n'
        '      operator: In\n'
        '      values: [payload-processing, payload-pre-processing]\n'
        '  policyTypes: [Ingress]\n'
        '  ingress:\n'
        '  - from:\n'
        '    - namespaceSelector:\n'
        '        matchLabels:\n'
        '          kubernetes.io/metadata.name: ${GATEWAY_NAMESPACE}\n'
        'EOF\n'
        '  ok "NetworkPolicy allows the gateway namespace to reach payload-processing"\n'
        'else\n'
        '  warn "payload-processing deployment was not created by maas-controller"\n'
        'fi\n',
    ),
    # 12. The base kustomization already generates maas-parameters; a second
    #     generator with the same id is rejected without a behavior.
    (
        'configMapGenerator:\n'
        '- envs:\n'
        '  - params.env\n'
        '  name: maas-parameters\n'
        'generatorOptions:\n',
        'configMapGenerator:\n'
        '- envs:\n'
        '  - params.env\n'
        '  name: maas-parameters\n'
        '  behavior: merge\n'
        'generatorOptions:\n',
    ),
    # 13. The validating webhook has failurePolicy: Fail and only the OpenShift
    #     inject-cabundle annotation. Inject the cert-manager CA, then restart
    #     the controller so its own bootstrap objects pass the webhook.
    (
        'echo "  Waiting for MaaS controller..."\n'
        'kubectl rollout status deployment/maas-controller -n "$MAAS_NAMESPACE" --timeout=180s 2>/dev/null || \\\n'
        '  warn "maas-controller not ready yet"\n',
        'kubectl annotate validatingwebhookconfiguration maas-validating-webhook-configuration \\\n'
        '  "cert-manager.io/inject-ca-from=${MAAS_NAMESPACE}/maas-controller-webhook-server" --overwrite >/dev/null\n'
        'echo "  Waiting for webhook caBundle injection..."\n'
        'for _i in $(seq 1 30); do\n'
        '  [[ -n "$(kubectl get validatingwebhookconfiguration maas-validating-webhook-configuration \\\n'
        '        -o jsonpath=\'{.webhooks[0].clientConfig.caBundle}\' 2>/dev/null)" ]] && break\n'
        '  sleep 2\n'
        'done\n'
        '\n'
        'echo "  Waiting for MaaS controller..."\n'
        'kubectl rollout status deployment/maas-controller -n "$MAAS_NAMESPACE" --timeout=180s 2>/dev/null || \\\n'
        '  warn "maas-controller not ready yet"\n'
        '# The controller creates its bootstrap AITenant at startup, through the\n'
        '# webhook. Restart once now that the caBundle is in place.\n'
        'kubectl rollout restart deployment/maas-controller -n "$MAAS_NAMESPACE" >/dev/null\n'
        'kubectl rollout status deployment/maas-controller -n "$MAAS_NAMESPACE" --timeout=180s 2>/dev/null || \\\n'
        '  warn "maas-controller not ready after restart"\n',
    ),
]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src, encoding="utf-8").read()
    for i, (old, new) in enumerate(EDITS):
        n = text.count(old)
        if n != 1:
            print(f"edit {i}: anchor found {n} times, expected 1:\n{old}", file=sys.stderr)
            return 1
        text = text.replace(old, new)
    open(dst, "w", encoding="utf-8").write(text)
    print(f"wrote {dst} ({len(EDITS)} edits)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
