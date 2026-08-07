#!/usr/bin/env bash
# Renders profiles/<profile>.yaml into an Istio EnvoyFilter.
#
# The profile fragments are plain Envoy http_filters lists - the same text that
# gets spliced into profiles/_base.yaml for --docker. An EnvoyFilter needs each
# filter wrapped in its own INSERT_BEFORE-the-router configPatch, so this turns
# one into the other. Single source of truth for both run modes.
#
# manifests/envoyfilter.yaml is the committed output for the default profile:
#   ./render-envoyfilter.sh metadata-filter > manifests/envoyfilter.yaml
# validate.sh --cluster checks the two still agree.
#
# Usage:
#   ./render-envoyfilter.sh [profile] [buffer-mib]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-metadata-filter}"
BUFFER_MIB="${2:-32}"
NS="${NS:-bbr-spike}"

FRAG="${SCRIPT_DIR}/profiles/${PROFILE}.yaml"
[[ -f "$FRAG" ]] || { echo "no such profile: $PROFILE" >&2; exit 2; }

python3 - "$FRAG" "$PROFILE" "$NS" "$((BUFFER_MIB * 1024 * 1024))" <<'PY'
import copy, sys, yaml

frag, profile, ns, limit = sys.argv[1:5]
filters = yaml.safe_load(open(frag))

# Istio applies configPatches in order and each INSERT_BEFORE lands immediately
# before the router, so listing them in filter-chain order preserves that order.
ROUTER_MATCH = {
    "context": "GATEWAY",
    "listener": {"filterChain": {"filter": {
        "name": "envoy.filters.network.http_connection_manager",
        "subFilter": {"name": "envoy.filters.http.router"}}}},
}

patches = [{
    "applyTo": "LISTENER",
    "match": {"context": "GATEWAY"},
    "patch": {"operation": "MERGE",
              "value": {"per_connection_buffer_limit_bytes": int(limit)}},
}]
for f in filters:
    patches.append({
        "applyTo": "HTTP_FILTER",
        # Deep copy, otherwise pyyaml emits the shared dict as an &anchor/*alias.
        "match": copy.deepcopy(ROUTER_MATCH),
        "patch": {"operation": "INSERT_BEFORE", "value": f},
    })

doc = {
    "apiVersion": "networking.istio.io/v1alpha3",
    "kind": "EnvoyFilter",
    "metadata": {"name": "model-body-to-header", "namespace": ns},
    "spec": {
        "workloadSelector": {"labels": {
            "gateway.networking.k8s.io/gateway-name": "spike-gateway"}},
        "configPatches": patches,
    },
}

print(f"# GENERATED from profiles/{profile}.yaml by render-envoyfilter.sh - do not edit.")
print(f"# Buffer limit {int(limit) // 1024 // 1024}MiB. Filter chain, in order:")
for f in filters:
    print(f"#   {f['name']}")
print(yaml.safe_dump(doc, sort_keys=False, width=100), end="")
PY
