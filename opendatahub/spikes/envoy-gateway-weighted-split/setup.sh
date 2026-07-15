#!/usr/bin/env bash
# Envoy Gateway weighted split reproducer - cluster setup
#
# Follows https://aigateway.envoyproxy.io/ install pattern with InferencePool addon.
# Uses the RBAC workaround from https://gist.github.com/bartoszmajsak/5eb001b1478982e9915767cf61b83479
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="eg-split-test"
CLUSTER_NAME="eg-split-spike"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"
EG_VERSION="${EG_VERSION:-v1.8.1}"
AIEG_VERSION="${AIEG_VERSION:-v1.0.0}"
GIE_VERSION="${GIE_VERSION:-v1.0.2}"
AIEG_RAW="https://raw.githubusercontent.com/envoyproxy/ai-gateway/${AIEG_VERSION}"

info() { echo -e "\033[0;33mINFO\033[0m: $1"; }
ok()   { echo -e "\033[0;32m  OK\033[0m: $1"; }
err()  { echo -e "\033[0;31mFAIL\033[0m: $1"; exit 1; }

# Kind cluster
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "Kind cluster '$CLUSTER_NAME' already exists"
else
    info "Creating kind cluster '$CLUSTER_NAME'"
    kind create cluster --name "$CLUSTER_NAME" --wait 60s
fi
kind get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG}"

# MetalLB
info "Installing MetalLB"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
kubectl wait --timeout=120s --namespace metallb-system \
    deployment/controller --for=condition=Available || err "MetalLB not ready"

subnet=$(docker network inspect "kind" -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -v ':' | head -1)
subnet="${subnet:-172.18.0.0/16}"
base=$(echo "$subnet" | cut -d. -f1-2)
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${base}.255.200-${base}.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF

# Remove cloud-provider-kind's Gateway API CRDs (kind v0.32+ bundles them, conflicts with EG's)
info "Removing pre-installed Gateway API CRDs"
kubectl delete crd gatewayclasses.gateway.networking.k8s.io gateways.gateway.networking.k8s.io \
    httproutes.gateway.networking.k8s.io grpcroutes.gateway.networking.k8s.io \
    referencegrants.gateway.networking.k8s.io backendtlspolicies.gateway.networking.k8s.io \
    2>/dev/null || true

# Envoy Gateway (bundles Gateway API CRDs, must be first)
# Don't use AI Gateway values yet - install EG standalone first to get CRDs in place
info "Installing Envoy Gateway ${EG_VERSION}"
helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm \
    --version "${EG_VERSION}" \
    --namespace envoy-gateway-system --create-namespace
kubectl wait --timeout=300s -n envoy-gateway-system \
    deployment/envoy-gateway --for=condition=Available || err "Envoy Gateway not ready"

# GIE CRDs (now that Gateway API CRDs exist from EG install)
info "Installing GIE CRDs ${GIE_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml"

# AI Gateway CRDs + controller
info "Installing AI Gateway CRDs ${AIEG_VERSION}"
helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
    --version "${AIEG_VERSION}" \
    --namespace envoy-ai-gateway-system --create-namespace

info "Installing AI Gateway controller ${AIEG_VERSION}"
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
    --version "${AIEG_VERSION}" \
    --namespace envoy-ai-gateway-system --create-namespace
kubectl wait --timeout=120s -n envoy-ai-gateway-system \
    deployment/ai-gateway-controller --for=condition=Available || err "AI Gateway controller not ready"

# Re-install EG with AI Gateway values + InferencePool addon
info "Upgrading Envoy Gateway with AI Gateway InferencePool addon"
helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
    --version "${EG_VERSION}" \
    --namespace envoy-gateway-system \
    -f "${AIEG_RAW}/manifests/envoy-gateway-values.yaml" \
    -f "${AIEG_RAW}/examples/inference-pool/envoy-gateway-values-addon.yaml"
kubectl rollout status deployment/envoy-gateway -n envoy-gateway-system --timeout=120s \
    || err "Envoy Gateway not ready after upgrade"

# Note: RBAC workaround for InferencePool (https://gist.github.com/bartoszmajsak/5eb001b1478982e9915767cf61b83479)
# is NOT needed with EG v1.8.1 + AI Gateway v1.0.0 installed in the correct order.

ok "Envoy Gateway + AI Gateway ready"

# GatewayClass + Gateway
kubectl create namespace "$NS" 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: test-gateway
  namespace: $NS
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF

# Mock inference backends + EPP + InferencePools
# Mirrors the upstream inference-pool example from envoyproxy/ai-gateway
info "Deploying mock inference backends"
TESTUPSTREAM_IMAGE="docker.io/envoyproxy/ai-gateway-testupstream:latest"
EPP_IMAGE="registry.k8s.io/gateway-api-inference-extension/epp:v1.0.1"

# RBAC for EPP
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: epp
  namespace: $NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: epp
  namespace: $NS
rules:
  - apiGroups: ["inference.networking.x-k8s.io"]
    resources: ["inferenceobjectives", "inferencepools"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["inference.networking.k8s.io"]
    resources: ["inferencepools"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: epp
  namespace: $NS
subjects:
  - kind: ServiceAccount
    name: epp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: epp
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: epp-auth-reviewer
rules:
  - apiGroups: ["authentication.k8s.io"]
    resources: ["tokenreviews"]
    verbs: ["create"]
  - apiGroups: ["authorization.k8s.io"]
    resources: ["subjectaccessreviews"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: epp-auth-reviewer
subjects:
  - kind: ServiceAccount
    name: epp
    namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: epp-auth-reviewer
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: epp-plugins
  namespace: $NS
data:
  default-plugins.yaml: |
    apiVersion: inference.networking.x-k8s.io/v1alpha1
    kind: EndpointPickerConfig
    plugins:
    - type: queue-scorer
    schedulingProfiles:
    - name: default
      plugins:
      - pluginRef: queue-scorer
EOF

for ver in v1 v2; do
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: model-${ver}
  namespace: $NS
spec:
  selector:
    app: model
    version: ${ver}
  ports:
    - port: 8080
      targetPort: 8080
  clusterIP: None
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: model-${ver}
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: model
      version: ${ver}
  template:
    metadata:
      labels:
        app: model
        version: ${ver}
    spec:
      containers:
        - name: testupstream
          image: $TESTUPSTREAM_IMAGE
          imagePullPolicy: IfNotPresent
          env:
            - name: TESTUPSTREAM_ID
              value: "${ver}"
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 1
            periodSeconds: 1
---
apiVersion: v1
kind: Service
metadata:
  name: pool-${ver}-epp
  namespace: $NS
spec:
  selector:
    app: pool-${ver}-epp
  ports:
    - port: 9002
      targetPort: 9002
      appProtocol: http2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pool-${ver}-epp
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pool-${ver}-epp
  template:
    metadata:
      labels:
        app: pool-${ver}-epp
    spec:
      serviceAccountName: epp
      terminationGracePeriodSeconds: 130
      containers:
        - name: epp
          image: $EPP_IMAGE
          imagePullPolicy: IfNotPresent
          args:
            - --pool-name=pool-${ver}
            - --pool-namespace=$NS
            - --grpc-port=9002
            - --grpc-health-port=9003
            - --config-file=/config/default-plugins.yaml
          ports:
            - containerPort: 9002
            - containerPort: 9003
            - name: metrics
              containerPort: 9090
          livenessProbe:
            grpc:
              port: 9003
              service: inference-extension
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            grpc:
              port: 9003
              service: inference-extension
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: plugins-config
              mountPath: /config
      volumes:
        - name: plugins-config
          configMap:
            name: epp-plugins
---
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: pool-${ver}
  namespace: $NS
spec:
  targetPorts:
    - number: 8080
  selector:
    matchLabels:
      app: model
      version: ${ver}
  endpointPickerRef:
    name: pool-${ver}-epp
    port:
      number: 9002
EOF
done

kubectl wait --timeout=120s -n "$NS" \
    deployment/model-v1 deployment/model-v2 \
    deployment/pool-v1-epp deployment/pool-v2-epp \
    --for=condition=Available || err "Backends or EPPs not ready"

# Wait for gateway address
info "Waiting for gateway address..."
for _ in $(seq 1 30); do
    gw_addr=$(kubectl get gateway test-gateway -n "$NS" \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [[ -n "$gw_addr" ]]; then
        echo ""
        ok "Setup complete"
        info "Gateway: http://$gw_addr"
        info "EG version: ${EG_VERSION}, AI Gateway values: ${AIEG_VERSION}"
        echo ""
        echo "  ./validate.sh"
        exit 0
    fi
    sleep 2
done
err "Gateway has no address after 60s"
