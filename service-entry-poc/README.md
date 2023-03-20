# Splitting traffic to external resources

This repo contains a trival proxy app and Istio configuration which allows to split the traffic for a fixed URL to different locations using `ServiceEntry` and `VirtualService`.

## Steps

### Prerequisites

* Openshift cluster
* Openshift Service Mesh

### Create namespace

```sh
export NS=service-entry-traffic-split
kubectl create namespace $NS
```

next, we make it part of the Service Mesh by creating `ServiceMeshMember` resource:

```sh
kubectl apply -n $NS -f - <<EOF
apiVersion: maistra.io/v1
kind: ServiceMeshMember
metadata:
  name: default
spec:
  controlPlaneRef:
    namespace: istio-system
    name: basic
EOF
```

### Deploy proxy app

We will now deploy the simple app which will act as a proxy:

```sh
kubectl apply -n $NS -f manifests/deployment.yaml
```

### Create Istio routing rules

```sh
kubectl apply -n $NS -f manifests/istio.yaml
```

after applying it, you will see that following resources have been created:

```
gateway.networking.istio.io/service-entry-gateway created
serviceentry.networking.istio.io/gist-local created
serviceentry.networking.istio.io/gist-ext created
virtualservice.networking.istio.io/gist-rewrite-vs created
destinationrule.networking.istio.io/gist created
```

Let's break it down:

* `ServiceEntry` named `gist-local` allows to refer to `gist.local` host from our proxy app, so that the URL of the service we want to reach stays the same (trick for the `VirtualService` to work).
* `ServiceEntry` named `gist-ext` registers `ServiceEntry` external to the mesh which points to `gist.githubusercontent.com` over `HTTPS`.
* `VirtualService` will dispatch a call made to `gist.local` to different endpoints outside of the mesh based on some critiera (in this case `x-end-user` header). It does that by rewriting the URI to point to the actual location.
* `DestinatioRule` is needed as we originate our calls from the proxy app using `HTTP`, but be need to set a TLS client to reach external location using `HTTPS`.

### Testing

The simplest way is to attach a pod to the mesh and curl the service.

```sh
kubectl -n $NS run curl-pod-$(uuid) --attach --rm --restart=Never -q --image=curlimages/curl -it sh 
```

Then we can use curl to check if our calls are routed correctly.

```sh
curl echo
{ "name": "user:anonymous" }
```

```sh
$ curl echo -H"x-end-user: bartosz"
{ "name": "user:bartosz" }
```

You should see two different responses.