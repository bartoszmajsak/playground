# Using Gateway API with OSSM v2

> [!IMPORTANT]
> This has been tested on ROSA

## References

- https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/service_mesh/service-mesh-2-x#enabling-openshift-container-platform-gateway-api
- Blog post: [How to use Gateway API with OpenShift Service Mesh 2.6](https://developers.redhat.com/articles/2024/09/16/how-use-gateway-api-openshift-service-mesh-26)

## Prerequisites

```sh {"name":"pre-req", "tag": "setup"}
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.0.0" | kubectl apply -f -; }
```

```sh {"name":"create-smcp", "tag": "setup"}
kubectl create ns istio-system || true
kubectl apply -f - << EOF
kind: ServiceMeshControlPlane
apiVersion: maistra.io/v2
metadata:
  name: minimal
  namespace: istio-system
spec:
  version: v2.6
  mode: ClusterWide # In this mode Gateway API is enabled by default, there is no need for additional configuration.
  security:
    manageNetworkPolicy: false # To allow external access through GW API easily
    ## ROSA specific settings, see https://access.redhat.com/solutions/6529231
    identity:
      type: ThirdParty
      thirdParty:
        audience: istio-ca
  policy:
    type: Istiod
  telemetry:
    type: Istiod
  addons:
    kiali:
      enabled: false
EOF
```

## Demo app

We will use bookinfo app to verify the setup.

```sh {"name":"bookinfo-create", "tag": "app"}
export NS="bookinfo-2"
kubectl create ns "${NS}" || true
kubectl label namespace "${NS}" istio-injection=enabled
kubectl apply -n "${NS}" -f https://raw.githubusercontent.com/Maistra/istio/maistra-2.6/samples/bookinfo/platform/kube/bookinfo.yaml
kubectl apply -n "${NS}" -f https://raw.githubusercontent.com/Maistra/istio/maistra-2.6/samples/bookinfo/gateway-api/bookinfo-gateway.yaml
```

Verification:

```sh {"name": "verify"}
export NS="bookinfo"
export INGRESS_HOST=$(kubectl get gtw bookinfo-gateway -n "${NS}" -o jsonpath='{.status.addresses[0].value}')
kubectl exec -n bookinfo "$(kubectl get pod -n ${NS} -l app=ratings  -o jsonpath='{.items[0].metadata.name}')" -c ratings -- curl -sS productpage:9080/productpage -H'Host:bookinfo.rh.io'| grep -o "<title>.*</title>"
curl -H'Host:bookinfo.rh.io' -s "http://${INGRESS_HOST}/productpage" | grep -o "<title>.*</title>"
```