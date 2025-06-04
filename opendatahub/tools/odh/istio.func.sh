#!/bin/bash

configure_external_authz_provider() {
  local cm_name="istio-data-science-smcp"
  local ns="istio-system"
  local provider_yaml="manifests/provider.config.yaml"

  local mesh_yaml_str
  mesh_yaml_str=$(kubectl -n "$ns" get configmap "$cm_name" -o json | jq -r '.data.mesh // "{}"')

  local new_provider_json
  new_provider_json=$(yq -o=json '.' "$provider_yaml" | jq '.extensionProviders[0]')

  local provider_name
  provider_name=$(echo "$new_provider_json" | jq -r '.name' | xargs)

  local filtered_providers_json
  filtered_providers_json=$(echo "$mesh_yaml_str" | yq -o=json '.extensionProviders // []' | jq "[.[] | select(.name != \"$provider_name\")]")

  local updated_providers_json
  updated_providers_json=$(echo "$filtered_providers_json" | jq ". + [$new_provider_json]")

  local new_mesh_yaml
  new_mesh_yaml=$(echo "$mesh_yaml_str" | yq ".extensionProviders = $updated_providers_json")

  kubectl -n "$ns" patch configmap "$cm_name" --type='json' -p="[
    {
      \"op\": \"replace\",
      \"path\": \"/data/mesh\",
      \"value\": $(jq -Rs . <<<\"$new_mesh_yaml\")
    }
  ]"
}
