# oauth-proxy as external authz provider

## Prerequisites
 
* `kubectl`
* `oc`
* `jq`
* `yq`
* `envsubst`

## Steps 

Tested using `crc`. Log in as kubeadmin following the instructions from `crc start`.

To setup up ODH with Model Serving and KServe+Serverless run the following commands: 

```sh
./odh setup
```

> [!IMPROTANT]
> If you see errors during setup, re-run `./odh setup`. It will eventually work! :)

Deploy the model:
```sh
./odh model-deploy
```

Verify that you can call the model:
```sh
./odh model-call
```

Now enable new authorization provider for the default model deployed earlier:
```sh
./odh inject-oauth-proxy  --label "serving.kserve.io/inferenceservice=sklearn-v2-iris" --model-ns "kserve-model"
```

Now we can call the model using different tokens:
```sh
oc login -u developer -p developer
DEV_TOKEN=$(oc whoami -t)

oc login -u kubeadmin -p <YOUR_PASSWORD>
ADMIN_TOKEN=$(oc whoami -t)

SVC_TOKEN=$(kubectl exec -n kserve-model \
  $(kubectl get pods -n kserve-model -l serving.kserve.io/inferenceservice=sklearn-v2-iris -o jsonpath='{.items[0].metadata.name}') \
  -c oauth-proxy -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
```

This should fail - you should see login page response
```sh
odh model-call --token $DEV_TOKEN
```

`kubeadmin`, as it belongs to `cluster-admin` group should be able to call the model
```sh
odh model-call --token $ADMIN_TOKEN
```

When using `$SVC_TOKEN` the call should be rejected, as the Service Account lacks proper RBAC roles. To fix it apply:
```sh
kubectl apply -n kserve-model -f manifests/role-get-isvc.yaml
odh model-call --token $SVC_TOKEN
```

## Under the hood

Below are the changes applied to the cluster to integrate openshift/oauth-proxy

### Service Mesh 

- Registers oauth-proxy as Istio external authorization provider 
- Patches existing KServe Istio AuthorizationPolicies to avoid overlap with new "authorization-group" that should only rely local oauth-proxy container
    - Without this change existing policies are additive and Authorino will also evaluate requests
- Creates new AuthorizationPolicy targeting workloads that want to use new authorization provider

### Model namespace

### Shared oauth-proxy config

- Self-signed TLS secret for the oauth-proxy
- New ServiceAccount and RBAC rules required for oauth-proxy

### ISVC deployment
- Adds the ServiceAccount and mount the TLS secret
- Injects the oauth-proxy sidecar container
- Adds a label to the ISVC deployment's pod template to enable external authorization
- Inject echo service as oauth-proxy upstream allowing Envoy to proceed with authorized requests

### Service Mesh settings

- Creates ServiceEntry to allow lookup for the local authorization provider that is deployed as sidecar container.