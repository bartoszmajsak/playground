#!/usr/bin/env bash
# Sets up a kind cluster with a made-up Model CRD.
set -euo pipefail

CLUSTER_NAME="informer-cache-spike"

info() { echo -e "\033[0;33mINFO\033[0m: $1"; }

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "Kind cluster '${CLUSTER_NAME}' already exists"
else
    info "Creating kind cluster '${CLUSTER_NAME}'"
    kind create cluster --name "$CLUSTER_NAME" --wait 60s
fi

kubectl --context "kind-${CLUSTER_NAME}" apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: models.spike.example.io
spec:
  group: spike.example.io
  names:
    kind: Model
    listKind: ModelList
    plural: models
    singular: model
  scope: Cluster
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                displayName:
                  type: string
                provider:
                  type: string
EOF
info "CRD applied"

echo ""
echo "Cluster ready. Run ./validate.sh"
