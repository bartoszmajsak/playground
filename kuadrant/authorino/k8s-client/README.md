# Reproducer showing k8s client timeout under load

## Quick Start

Run the setup script:

```bash
./setup.sh
```

Then follow instructions to run load tests.

## Manual Setup

### Prerequisites

Install [`k6`](https://grafana.com/docs/k6/latest/set-up/install-k6/?pg=oss-k6&plcmt=deploy-box-1#install-k6) load testing tool.

Set environment variables:

```bash
export KUADRANT_GATEWAY_NS=openshift-ingress
export KUADRANT_GATEWAY_NAME=kuadrant-gw
export KUADRANT_DEVELOPER_NS=toystore
```

## Setup Gateway

Create the gateway namespace:

```bash
kubectl create ns ${KUADRANT_GATEWAY_NS} || true
```

Create the GatewayClass:

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: kuadrant
spec:
  controllerName: "openshift.io/gateway-controller/v1"
EOF
```

Create the Gateway:

```bash
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
```

Verify gateway status:

```bash
kubectl get gateway ${KUADRANT_GATEWAY_NAME} -n ${KUADRANT_GATEWAY_NS} -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Programmed")].message}{"\n"}'
```

## Deploy Toystore Application

Create developer namespace and deploy toystore:

```bash
kubectl create ns ${KUADRANT_DEVELOPER_NS}

kubectl apply -f https://raw.githubusercontent.com/Kuadrant/Kuadrant-operator/main/examples/toystore/toystore.yaml -n ${KUADRANT_DEVELOPER_NS}
```

Create HTTPRoute:

```bash
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
```

Get gateway URL:

```bash
export KUADRANT_INGRESS_HOST=$(kubectl get gtw ${KUADRANT_GATEWAY_NAME} -n ${KUADRANT_GATEWAY_NS} -o jsonpath='{.status.addresses[0].value}')
export KUADRANT_INGRESS_PORT=$(kubectl get gtw ${KUADRANT_GATEWAY_NAME} -n ${KUADRANT_GATEWAY_NS} -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export KUADRANT_GATEWAY_URL=${KUADRANT_INGRESS_HOST}:${KUADRANT_INGRESS_PORT}
```

## Configure AuthPolicy

Apply AuthPolicy with Kubernetes TokenReview and SubjectAccessReview:

```bash
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
```

Test without authentication (should fail):

```bash
curl -H 'Host: api.toystore.com' http://$KUADRANT_GATEWAY_URL/toy -i
```

## Setup Service Account and RBAC

Create service account:

```bash
kubectl create sa user-001 -n ${KUADRANT_DEVELOPER_NS}
```

Create token:

```bash
export TOKEN=$(kubectl create token user-001 -n ${KUADRANT_DEVELOPER_NS} --duration=2h --audience=toystore-users)
```

Create ClusterRoles:

```bash
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
```

Create ClusterRoleBindings:

```bash
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
  name: system:serviceaccount:toystore:user-001
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
  name: system:serviceaccount:toystore:user-001
EOF
```

## Test Authenticated Request

```bash
curl -H "Authorization: Bearer ${TOKEN}" -H 'Host: api.toystore.com' http://$KUADRANT_GATEWAY_URL/toy -i
```

## Load Testing with k6

Run load test:

```bash
k6 run k6/test.js
```

Observe the results:

```bash
  █ THRESHOLDS

    http_req_duration
    ✓ 'p(95)<5000' p(95)=368.63ms

    http_req_failed
    ✗ 'rate<0.1' rate=89.90%

    success_rate
    ✗ 'rate>0.9' rate=10.10%


  █ TOTAL RESULTS

    checks_total.......: 1000   49.064963/s
    checks_succeeded...: 10.10% 101 out of 1000
    checks_failed......: 89.90% 899 out of 1000

    ✗ status is 200
      ↳  10% — ✓ 101 / ✗ 899

    CUSTOM
    success_rate...................: 10.10% 101 out of 1000

    HTTP
    http_req_duration..............: avg=199.68ms min=171.85ms med=181.3ms  max=383.42ms p(90)=241.52ms p(95)=368.63ms
      { expected_response:true }...: avg=345.82ms min=197.02ms med=367.09ms max=383.18ms p(90)=377.63ms p(95)=379.23ms
    http_req_failed................: 89.90% 899 out of 1000
    http_reqs......................: 1000   49.064963/s

    EXECUTION
    iteration_duration.............: avg=201.71ms min=171.95ms med=181.42ms max=438.58ms p(90)=346.77ms p(95)=371.7ms
    iterations.....................: 1000   49.064963/s
    vus............................: 10     min=10          max=10
    vus_max........................: 10     min=10          max=10

    NETWORK
    data_received..................: 499 kB 25 kB/s
    data_sent......................: 1.4 MB 68 kB/s
```

## Testing with Custom Authorino Image

Patch Authorino to use custom with k8s-client improvements:

```bash
kubectl patch authorino authorino -n kuadrant-system --type='merge' -p '{"spec":{"image":"quay.io/bmajsak/authorino:k8s-client"}}'
```

Run load test again:

```bash
k6 run k6/test.js
```

And hope for:

```bash
  █ THRESHOLDS

    http_req_duration
    ✓ 'p(95)<5000' p(95)=236.99ms

    http_req_failed
    ✓ 'rate<0.1' rate=0.00%

    success_rate
    ✓ 'rate>0.9' rate=100.00%


  █ TOTAL RESULTS

    checks_total.......: 1000    46.87864/s
    checks_succeeded...: 100.00% 1000 out of 1000
    checks_failed......: 0.00%   0 out of 1000

    ✓ status is 200

    CUSTOM
    success_rate...................: 100.00% 1000 out of 1000

    HTTP
    http_req_duration..............: avg=210.17ms min=185.46ms med=195.85ms max=287.93ms p(90)=235.43ms p(95)=236.99ms
      { expected_response:true }...: avg=210.17ms min=185.46ms med=195.85ms max=287.93ms p(90)=235.43ms p(95)=236.99ms
    http_req_failed................: 0.00%   0 out of 1000
    http_reqs......................: 1000    46.87864/s

    EXECUTION
    iteration_duration.............: avg=212.22ms min=185.58ms med=195.96ms max=469.89ms p(90)=235.56ms p(95)=237.13ms
    iterations.....................: 1000    46.87864/s
    vus............................: 10      min=10           max=10
    vus_max........................: 10      min=10           max=10

    NETWORK
    data_received..................: 2.7 MB  128 kB/s
    data_sent......................: 1.4 MB  65 kB/s
```
