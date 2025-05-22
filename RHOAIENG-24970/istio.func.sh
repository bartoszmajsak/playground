#!/bin/bash

configure_external_authz_provider() {
  local cm_name="istio-data-science-smcp"
  local ns="istio-system"
  local provider_yaml="manifests/provider.config.yaml"

  local mesh_yaml=$(kubectl -n "$ns" get configmap "$cm_name" -o json | jq -r '.data.mesh // ""')
  [[ -z "$mesh_yaml" ]] && mesh_yaml="{}"

  local provider_name=$(yq '.name' "$provider_yaml")
  if echo "$mesh_yaml" | yq '.extensionProviders[].name' 2>/dev/null | grep -qx "$provider_name"; then
    echo "extensionProvider '$provider_name' already present in ConfigMap $cm_name in namespace $ns. Skipping."
    return 0
  fi

  local new_mesh_yaml
  new_mesh_yaml=$(yq eval-all '
    . as $item ireduce ({}; . *+ $item) |
    .extensionProviders = (.extensionProviders // [] + [.[1]])
  ' <(echo "$mesh_yaml") "$provider_yaml")

  kubectl -n "$ns" patch configmap "$cm_name" --type='json' -p="[
    {
      \"op\": \"replace\",
      \"path\": \"/data/mesh\",
      \"value\": $(jq -Rs . <<<"$new_mesh_yaml")
    }
  ]"

}
