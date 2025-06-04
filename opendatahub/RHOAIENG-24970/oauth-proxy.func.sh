#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/cluster.func.sh"
source "$SCRIPT_DIR/istio.func.sh"

oauth_proxy_ext_authz() {
  local label_selector="$1"
  local namespace="$2"
  local deployment_name
  
  deployment_name=$(get_deployment_name_by_label "$label_selector" "$namespace")
  if [[ -z "$deployment_name" ]]; then
    echo "No deployment found with label $label_selector in namespace $namespace" >&2
    return 1
  fi
  
  configure_external_authz_provider
  patch_existing_auth_policies
  create_auth_policy
  
  create_tls_secret "oauth-proxy-tls-creds" "$namespace"
  create_service_account "oauth-proxy-sa" "$namespace"
  
  # nasty hack to prevent from reconciliation - hijacking resources :)
  remove_owner_references "$deployment_name" "$namespace"

  ensure_automount_serviceaccount_token "$deployment_name" "$namespace"
  add_sa_with_secret "$deployment_name" "$namespace"
  
  inject_oauth_proxy_sidecar "$deployment_name" "$namespace"
  create_service_entry "$namespace"
  enable_authz "$deployment_name" "$namespace"
}

get_deployment_name_by_label() {
  local label_selector="$1"
  local namespace="$2"
  kubectl get deployment -n "$namespace" -l "$label_selector" -o jsonpath='{.items[0].metadata.name}'
}


ensure_automount_serviceaccount_token() {
  local deployment_name="$1"
  local namespace="$2"
  echo "Ensuring automountServiceAccountToken: true for deployment $deployment_name in namespace $namespace..."
  kubectl -n "$namespace" patch deployment "$deployment_name" --type='merge' -p '{"spec":{"template":{"spec":{"automountServiceAccountToken":true}}}}'
}

create_service_account() {
  local sa_name="$1"
  local namespace="$2"
  
  if [[ -z "$sa_name" || -z "$namespace" ]]; then
    echo "Usage: create_service_account <serviceaccount> <namespace>" >&2
    return 1
  fi
  echo "Creating ServiceAccount and RBAC from manifests/service-account.yaml for $sa_name in $namespace..."
  SA_NAME="$sa_name" NAMESPACE="$namespace" envsubst < manifests/service-account.yaml | kubectl apply -f -
}

create_tls_secret() {
  local secret_name="$1"
  local namespace="$2"
  
  if ! kubectl -n "$namespace" get secret "$secret_name" &>/dev/null; then
    echo "Generating self-signed cert and creating secret $secret_name in namespace $namespace..."
    tmpdir=$(mktemp -d)
    local ingress_domain=$(kubectl get ingresses.config.openshift.io/cluster -o jsonpath='{.spec.domain}')
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -subj "/CN=${ingress_domain}" \
      -keyout "$tmpdir/tls.key" -out "$tmpdir/tls.crt"
    kubectl -n "$namespace" create secret tls "$secret_name" \
      --cert="$tmpdir/tls.crt" --key="$tmpdir/tls.key"
    rm -rf "$tmpdir"
  fi
}

add_sa_with_secret() {
  local deployment_name="$1"
  local namespace="$2"
  echo "Patching deployment $deployment_name in namespace $namespace to add oauth-proxy-tls-creds volume and set serviceAccountName..."
  patch_yaml=$(cat <<EOF
spec:
  template:
    spec:
      serviceAccountName: oauth-proxy-sa
      volumes:
        - name: oauth-proxy-tls-creds
          secret:
            secretName: oauth-proxy-tls-creds
            defaultMode: 420
EOF
)
  kubectl -n "$namespace" patch deployment "$deployment_name" --type=strategic -p "$patch_yaml"
}

inject_oauth_proxy_sidecar() {
  local deployment_name="$1"
  local namespace="$2"
  echo "Checking if oauth-proxy container already exists in deployment $deployment_name..."
  if kubectl -n "$namespace" get deployment "$deployment_name" -o json | jq -e '.spec.template.spec.containers[] | select(.name=="oauth-proxy")' >/dev/null; then
    echo "Container 'oauth-proxy' already exists in deployment $deployment_name, skipping patch."
    return 0
  fi
  echo "Injecting oauth-proxy sidecar into deployment $deployment_name in namespace $namespace using manifests/oauth-proxy.sidecar.yaml..."
  export NAMESPACE="$namespace"
  ISVC_NAME=$(kubectl -n "$namespace" get deployment "$deployment_name" -o jsonpath='{.metadata.labels.serving\.kserve\.io/inferenceservice}')
  export ISVC_NAME

  containers_json=$(envsubst < "$SCRIPT_DIR/manifests/oauth-proxy.sidecar.yaml" | yq -o=json)
  num_containers=$(echo "$containers_json" | jq 'length')
  for i in $(seq 0 $((num_containers - 1))); do
    container=$(echo "$containers_json" | jq ".[$i]")
    kubectl -n "$namespace" patch deployment "$deployment_name" --type='json' -p="[
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/-\",\"value\":$container}
    ]"
  done
}

enable_authz() {
  local deployment_name="$1"
  local namespace="$2"
  echo "Adding label security.opendatahub.io/authorization-group=oauth-proxy to deployment $deployment_name pod template..."
  kubectl -n "$namespace" patch deployment "$deployment_name" --type=merge -p '{
    "spec": {
      "template": {
        "metadata": {
          "labels": {
            "security.opendatahub.io/authorization-group": "oauth-proxy"
          }
        }
      }
    }
  }'
}

remove_owner_references() {
  local deployment_name="$1"
  local namespace="$2"
  echo "Removing ownerReferences from deployment $deployment_name in namespace $namespace..."
  hack_remove_owner_ref deployment "$deployment_name" "$namespace"
}

patch_existing_auth_policies() {
  local namespace="istio-system"
  local label_selector="platform.opendatahub.io/part-of=kserve"
  echo "Finding all AuthorizationPolicies in namespace $namespace with label $label_selector..."
  policies=$(kubectl -n "$namespace" get authorizationpolicies -l "$label_selector" -o jsonpath='{.items[*].metadata.name}')
  for policy in $policies; do
    kubectl -n "$namespace" patch authorizationpolicy "$policy" --type=merge --patch-file=manifests/existing-auth-policy.patch.yaml
  done
}

create_auth_policy() {
  local namespace="istio-system"
  kubectl -n "$namespace" apply -f manifests/auth-policy.yaml
}

create_service_entry() {
  local namespace="$1"
  if [[ -z "$namespace" ]]; then
    echo "Usage: create_service_entry <namespace>" >&2
    return 1
  fi
  echo "Applying manifests/service-entry.yaml to namespace $namespace..."
  kubectl apply -n "$namespace" -f manifests/service-entry.yaml
}

