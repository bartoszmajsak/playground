#!/usr/bin/env bash
# Renders the fix as a second EnvoyFilter, from the MaaS EnvoyFilter the
# controller rendered on the live cluster, so the ipp filters keep exactly the
# typed_config they have today and only their anchors change.
#
# Usage: render-fix.sh [out.yaml]      (default: stdout)
#
# Env: FIX_VARIANT=pre-only (default) moves ipp-pre before Istio's
#      InferencePool ext_proc and leaves ipp after the auth filter; extproc
#      also moves ipp to right after the ext_proc, which puts the post-stage
#      ahead of auth and breaks it (maas-headers-guard strips Authorization).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/lib.sh"

EF_NAME="${EF_NAME:-payload-processing}"
out="${1:-/dev/stdout}"

# Through a file: the heredoc below is python's stdin, so a pipe would be lost.
live="$(mktemp)"
trap 'rm -f "$live"' EXIT
kc get envoyfilter "$EF_NAME" -n "$GATEWAY_NAMESPACE" -o json > "$live"
[[ -s "$live" ]] || err "EnvoyFilter ${GATEWAY_NAMESPACE}/${EF_NAME} not found"

# The patch REMOVEs ipp-pre and re-inserts it before Istio's InferencePool
# filter. On a gateway without that filter the REMOVE would still apply and
# the insert would match nothing, leaving no ipp-pre at all.
if [[ "${FIX_FORCE:-0}" != 1 && "$FIX_VARIANT" != "first" ]]; then
    idx=$("$SCRIPT_DIR/scripts/check-filter-order.sh" --json 2>/dev/null | jq -r '.indices.istio_ext_proc // -1' || echo -1)
    [[ "${idx:--1}" -ge 0 ]] || err "no envoy.filters.http.ext_proc on ${GATEWAY_NAME}: no InferencePool attached, nothing to re-anchor on (FIX_FORCE=1 overrides)"
fi

python3 - "$live" "$FIX_EF_NAME" "$FIX_VARIANT" <<'PY' > "$out"
import json, sys, yaml

live, name, variant = sys.argv[1], sys.argv[2], sys.argv[3]
ef = json.load(open(live))
spec = ef["spec"]

IPP_PRE = "envoy.filters.http.ext_proc.ipp-pre"
IPP = "envoy.filters.http.ext_proc.ipp"
ISTIO_EXT_PROC = "envoy.filters.http.ext_proc"

def inserted(filter_name):
    for cp in spec.get("configPatches", []):
        if cp.get("applyTo") != "HTTP_FILTER":
            continue
        value = (cp.get("patch") or {}).get("value") or {}
        if value.get("name") == filter_name:
            return value
    raise SystemExit(f"no HTTP_FILTER patch inserting {filter_name} in EnvoyFilter {ef['metadata']['name']}")

def match(sub_filter):
    return {"context": "GATEWAY",
            "listener": {"filterChain": {"filter": {
                "name": "envoy.filters.network.http_connection_manager",
                "subFilter": {"name": sub_filter}}}}}

def remove(sub_filter):
    return {"applyTo": "HTTP_FILTER", "match": match(sub_filter), "patch": {"operation": "REMOVE"}}

def insert(op, anchor, value):
    return {"applyTo": "HTTP_FILTER", "match": match(anchor), "patch": {"operation": op, "value": value}}

def insert_first(value):
    return {"applyTo": "HTTP_FILTER",
            "match": {"context": "GATEWAY",
                      "listener": {"filterChain": {"filter": {
                          "name": "envoy.filters.network.http_connection_manager"}}}},
            "patch": {"operation": "INSERT_FIRST", "value": value}}

patches = [remove(IPP_PRE)]
if variant == "extproc":
    patches.append(remove(IPP))
if variant == "first":
    # No anchor: lands ahead of everything, InferencePool filter or not. The
    # upstream llm-d payload-processor chart's default.
    patches.append(insert_first(inserted(IPP_PRE)))
else:
    patches.append(insert("INSERT_BEFORE", ISTIO_EXT_PROC, inserted(IPP_PRE)))
if variant == "extproc":
    patches.append(insert("INSERT_AFTER", ISTIO_EXT_PROC, inserted(IPP)))

doc = {
    "apiVersion": "networking.istio.io/v1alpha3",
    "kind": "EnvoyFilter",
    "metadata": {"name": name, "namespace": ef["metadata"]["namespace"],
                 "annotations": {"maas-epp-filter-order/variant": variant,
                                 "maas-epp-filter-order/rendered-from": ef["metadata"]["name"]}},
    "spec": {
        # Applied after Kuadrant and the MaaS EnvoyFilter, whatever priority
        # the latter carries: the REMOVEs find the filters those two produced,
        # and the inserts land relative to the filter Istio placed in the
        # base chain.
        "priority": int(spec.get("priority", 0)) + 10,
        "workloadSelector": spec.get("workloadSelector"),
        "configPatches": patches,
    },
}
print(yaml.safe_dump(doc, sort_keys=False))
PY
