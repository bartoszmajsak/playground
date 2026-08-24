#!/usr/bin/env bash
# Delete a run's kind cluster after verifying the target against the run's own
# metadata and kubeconfig. Never acts on the caller's current context.
#
# Usage:
#   ./cleanup.sh --run <run-id>      # delete that run's cluster
#   ./cleanup.sh                      # delete the current run's cluster

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

RUN_ARG=""
[[ "${1:-}" == "--run" ]] && RUN_ARG="${2:-}"
load_run "$RUN_ARG"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    # Verify the kubeconfig really points at this cluster before deleting.
    guard_cluster
    info "deleting kind cluster ${CLUSTER_NAME} (run ${RUN_ID})"
    kind delete cluster --name "$CLUSTER_NAME"
    ok "deleted"
else
    warn "cluster ${CLUSTER_NAME} not found; nothing to delete"
fi

meta_set "$RUN_DIR" clusterDeletedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ok "artifacts retained at ${RUN_DIR}"
