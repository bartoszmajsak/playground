#!/usr/bin/env bash
# Applies or reverts the fix on the live gateway.
#
# Usage:
#   ./fix.sh apply     # render from the live MaaS EnvoyFilter, apply, wait for the chain
#   ./fix.sh revert    # delete the fix EnvoyFilter, wait for the defect to be back
#   ./fix.sh status    # run the diagnostic
#
# The fix is a priority-20 EnvoyFilter (scripts/render-fix.sh): it removes
# ipp-pre and ipp where the MaaS EnvoyFilter put them and re-inserts them
# around Istio's InferencePool ext_proc. The controller-owned EnvoyFilter is
# never modified, so nothing reconciles the fix away.
#
# Env: FIX_VARIANT=extproc|pre-only, FIX_REVERT_EXPECT=BROKEN (OK on a control
#      cluster where the EPP works without the fix).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

GENERATED="${MANIFESTS}/generated"

case "${1:-}" in
    apply)
        mkdir -p "$GENERATED"
        "$SCRIPT_DIR/scripts/render-fix.sh" "$GENERATED/fix-envoyfilter.yaml"
        kc apply -f "$GENERATED/fix-envoyfilter.yaml" >/dev/null
        info "applied EnvoyFilter ${FIX_EF_NAME} (variant ${FIX_VARIANT}); waiting for the chain"
        if got=$(wait_for_chain OK 120); then
            ok "EPP_ENGAGED=OK"
        else
            "$SCRIPT_DIR/scripts/check-filter-order.sh" || true
            err "chain did not reach EPP_ENGAGED=OK within 120s (last: ${got:-none})"
        fi
        ;;
    revert)
        kc delete envoyfilter "$FIX_EF_NAME" -n "$GATEWAY_NAMESPACE" --ignore-not-found >/dev/null
        want="${FIX_REVERT_EXPECT:-BROKEN}"
        info "deleted EnvoyFilter ${FIX_EF_NAME}; waiting for EPP_ENGAGED=${want}"
        if got=$(wait_for_chain "$want" 120); then
            ok "EPP_ENGAGED=${want}"
        else
            err "chain did not return to EPP_ENGAGED=${want} within 120s (last: ${got:-none})"
        fi
        ;;
    status)
        "$SCRIPT_DIR/scripts/check-filter-order.sh"
        ;;
    *)
        sed -n '2,16p' "$0"
        exit 2
        ;;
esac
