#!/usr/bin/env bash
set -euo pipefail

BOLD='\033[1m'
RESET='\033[0m'

export KUADRANT_GATEWAY_NS="${KUADRANT_GATEWAY_NS:-openshift-ingress}"
export KUADRANT_GATEWAY_NAME="${KUADRANT_GATEWAY_NAME:-kuadrant-gw}"
export KUADRANT_DEVELOPER_NS="${KUADRANT_DEVELOPER_NS:-toystore}"

echo -e "${BOLD}Configuration${RESET}"
echo "    Gateway Namespace: ${KUADRANT_GATEWAY_NS}"
echo "    Gateway Name: ${KUADRANT_GATEWAY_NAME}"
echo "    Developer Namespace: ${KUADRANT_DEVELOPER_NS}"
echo ""

echo -e "${BOLD}Creating namespaces...${RESET}"
kubectl create ns "${KUADRANT_GATEWAY_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns "${KUADRANT_DEVELOPER_NS}" --dry-run=client -o yaml | kubectl apply -f -

echo -e "${BOLD}Creating GatewayClass...${RESET}"
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: kuadrant
spec:
  controllerName: "openshift.io/gateway-controller/v1"
EOF

echo -e "${BOLD}Creating Gateway...${RESET}"
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${KUADRANT_GATEWAY_NAME}
  namespace: ${KUADRANT_GATEWAY_NS}
  labels:
    kuadrant.io/gateway: "true"
spec:
  gatewayClassName: kuadrant
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF

echo -e "${BOLD}Waiting for Gateway to be ready...${RESET}"
kubectl wait --for=condition=Programmed gateway/${KUADRANT_GATEWAY_NAME} -n ${KUADRANT_GATEWAY_NS} --timeout=120s || true

echo -e "${BOLD}Deploying Toystore application...${RESET}"
kubectl apply -f https://raw.githubusercontent.com/Kuadrant/Kuadrant-operator/main/examples/toystore/toystore.yaml -n ${KUADRANT_DEVELOPER_NS}

echo -e "${BOLD}Creating HTTPRoute...${RESET}"
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: toystore
  namespace: ${KUADRANT_DEVELOPER_NS}
spec:
  parentRefs:
  - name: ${KUADRANT_GATEWAY_NAME}
    namespace: ${KUADRANT_GATEWAY_NS}
  hostnames:
  - api.toystore.com
  rules:
  - matches:
    - path:
        type: Exact
        value: "/toy"
      method: GET
    backendRefs:
    - name: toystore
      port: 80
EOF

echo -e "${BOLD}Creating AuthPolicy...${RESET}"
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: toystore-protection
  namespace: ${KUADRANT_DEVELOPER_NS}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: toystore
  rules:
    authentication:
      "k8s-service-accounts":
        kubernetesTokenReview:
          audiences:
          - toystore-users
        overrides:
          "sub":
            selector: auth.identity.user.username
    authorization:
      "k8s-rbac":
        kubernetesSubjectAccessReview:
          user:
            selector: auth.identity.sub
    response:
      success:
        filters:
          "identity":
            json:
              properties:
                "userid":
                  selector: auth.identity.sub
EOF

echo -e "${BOLD}Creating Service Account...${RESET}"
kubectl create sa user-001 -n ${KUADRANT_DEVELOPER_NS} --dry-run=client -o yaml | kubectl apply -f -

echo -e "${BOLD}Creating ClusterRoles...${RESET}"
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: toystore-reader
rules:
- nonResourceURLs: ["/toy*"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: toystore-writer
rules:
- nonResourceURLs: ["/admin/toy"]
  verbs: ["post", "delete"]
EOF

echo -e "${BOLD}Creating ClusterRoleBindings...${RESET}"
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: toystore-readers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: toystore-reader
subjects:
- kind: User
  name: system:serviceaccount:${KUADRANT_DEVELOPER_NS}:user-001
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: toystore-writers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: toystore-writer
subjects:
- kind: User
  name: system:serviceaccount:${KUADRANT_DEVELOPER_NS}:user-001
EOF

echo -e "${BOLD}Waiting for Toystore deployment...${RESET}"
kubectl wait --for=condition=Available deployment/toystore -n ${KUADRANT_DEVELOPER_NS} --timeout=120s || true

echo -e "${BOLD}Retrieving Gateway URL...${RESET}"
export KUADRANT_INGRESS_HOST=$(kubectl get gtw ${KUADRANT_GATEWAY_NAME} -n ${KUADRANT_GATEWAY_NS} -o jsonpath='{.status.addresses[0].value}')
export KUADRANT_INGRESS_PORT=$(kubectl get gtw ${KUADRANT_GATEWAY_NAME} -n ${KUADRANT_GATEWAY_NS} -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export KUADRANT_GATEWAY_URL="${KUADRANT_INGRESS_HOST}:${KUADRANT_INGRESS_PORT}"

echo -e "${BOLD}Generating Token...${RESET}"
export TOKEN=$(kubectl create token user-001 -n ${KUADRANT_DEVELOPER_NS} --duration=2h --audience=toystore-users)

echo ""
echo -e "${BOLD}==========================================${RESET}"
echo -e "${BOLD}Setup complete!${RESET}"
echo -e "${BOLD}==========================================${RESET}"
echo ""
echo "Export these variables to run tests:"
echo ""
echo "export KUADRANT_GATEWAY_URL=${KUADRANT_GATEWAY_URL}"
echo "export TOKEN=${TOKEN}"
echo ""
echo "Test with curl:"
echo "  curl -H \"Authorization: Bearer \${TOKEN}\" -H 'Host: api.toystore.com' http://\${KUADRANT_GATEWAY_URL}/toy -i"
echo ""
echo "To run load tests:"
echo "  k6 run k6/test.js"
echo ""
echo "Patch Authorino with k8s-client improvements to fix timeout issues:"
echo "  kubectl patch authorino authorino -n kuadrant-system --type='merge' -p '{\"spec\":{\"image\":\"quay.io/bmajsak/authorino:k8s-client\"}}'"
echo ""
