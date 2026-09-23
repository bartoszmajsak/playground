#!/usr/bin/env bash
# Render a separate EnvoyFilter, preserving the live filter configurations.
# The default moves native EPP after IPP. Experimental variants move IPP stages.
#
# Usage: render-fix.sh [out.yaml]      (default: stdout)
#
# Env: FIX_VARIANT=epp-after-ipp (default). pre-only moves ipp-pre before Istio's
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
dump="$(mktemp)"
trap 'rm -f "$live" "$dump"' EXIT
kc get envoyfilter "$EF_NAME" -n "$GATEWAY_NAMESPACE" -o json > "$live"
[[ -s "$live" ]] || err "EnvoyFilter ${GATEWAY_NAMESPACE}/${EF_NAME} not found"
case "$FIX_VARIANT" in
    epp-after-ipp) capture config_dump "$dump" || err "cannot capture native EPP configuration" ;;
    pre-only|first|extproc) ;;
    *) err "unknown FIX_VARIANT=$FIX_VARIANT" ;;
esac

# The patch REMOVEs ipp-pre and re-inserts it before Istio's InferencePool
# filter. On a gateway without that filter the REMOVE would still apply and
# the insert would match nothing, leaving no ipp-pre at all.
if [[ "${FIX_FORCE:-0}" != 1 && "$FIX_VARIANT" != "first" ]]; then
    idx=$("$SCRIPT_DIR/scripts/check-filter-order.sh" --json 2>/dev/null | jq -r '.indices.istio_ext_proc // -1' || echo -1)
    [[ "${idx:--1}" -ge 0 ]] || err "no envoy.filters.http.ext_proc on ${GATEWAY_NAME}: no InferencePool attached, nothing to re-anchor on (FIX_FORCE=1 overrides)"
fi

python3 - "$live" "$FIX_EF_NAME" "$FIX_VARIANT" "$dump" <<'PY' > "$out"
import json, sys, yaml

live, name, variant, dump = sys.argv[1:]
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

patches = []
if variant == "epp-after-ipp":
    native = []
    for config in json.load(open(dump))["configs"]:
        for listener in config.get("dynamic_listeners", []):
            for chain in listener.get("active_state", {}).get("listener", {}).get("filter_chains", []):
                for network_filter in chain.get("filters", []):
                    filters = network_filter.get("typed_config", {}).get("http_filters", [])
                    found = [f for f in filters if f["name"] == ISTIO_EXT_PROC]
                    if any(f["name"] == IPP for f in filters) and not found:
                        raise SystemExit("an IPP listener lacks native EPP; refusing to insert EPP into an unrelated listener")
                    if found:
                        if len(found) != 1 or sum(f["name"] == IPP for f in filters) != 1:
                            raise SystemExit("each native EPP chain must contain exactly one EPP and one IPP")
                        native.extend(found)
    if not native or any(f != native[0] for f in native):
        raise SystemExit("native EPP is absent or differs between listeners; cannot render one safe patch")
    patches = [remove(ISTIO_EXT_PROC), insert("INSERT_AFTER", IPP, native[0])]
else:
    patches = [remove(IPP_PRE)]
if variant == "extproc":
    patches.append(remove(IPP))
if variant == "first":
    # No anchor: lands ahead of everything, InferencePool filter or not. The
    # upstream llm-d payload-processor chart's default.
    patches.append(insert_first(inserted(IPP_PRE)))
elif variant != "epp-after-ipp":
    patches.append(insert("INSERT_BEFORE", ISTIO_EXT_PROC, inserted(IPP_PRE)))
if variant == "extproc":
    patches.append(insert("INSERT_AFTER", ISTIO_EXT_PROC, inserted(IPP)))

if not spec.get("workloadSelector", {}).get("labels"):
    raise SystemExit("MaaS EnvoyFilter has no workload selector; refusing an unscoped patch")
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
