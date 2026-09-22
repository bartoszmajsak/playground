#!/usr/bin/env bash
# Reports where the MaaS payload-processing ext_proc filters sit relative to
# Istio's InferencePool ext_proc filter on a gateway, and whether that order
# lets the EPP run.
#
# Usage:
#   check-filter-order.sh [--json] [--expect ok|broken] [--listener-port N] [--dump FILE]
#
# Env:
#   GATEWAY_NAME       default maas-default-gateway
#   GATEWAY_NAMESPACE  default: the namespace holding GATEWAY_NAME
#   EF_NAME            the MaaS EnvoyFilter, default payload-processing
#   KUBECTL            oc or kubectl, auto-detected
#
# Standalone on purpose: copy this one file to wherever the gateway is
# reachable from. --dump scores a saved config_dump offline; the EnvoyFilter
# section is then filled in only if the cluster is also reachable.
#
# Exit: 0 when the EPP can run (or no InferencePool filter is present),
#       1 when the order breaks it, 2 on error. --expect inverts.
set -euo pipefail

GATEWAY_NAME="${GATEWAY_NAME:-maas-default-gateway}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-}"
EF_NAME="${EF_NAME:-payload-processing}"
if [[ -z "${KUBECTL:-}" ]]; then
    if command -v oc >/dev/null 2>&1; then KUBECTL=oc; else KUBECTL=kubectl; fi
fi

JSON=0; EXPECT=""; LISTENER_PORT=""; DUMP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON=1 ;;
        --expect) EXPECT="$2"; shift ;;
        --listener-port) LISTENER_PORT="$2"; shift ;;
        --dump) DUMP="$2"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cluster_ok=0
if "$KUBECTL" get gateway -A -o name >/dev/null 2>&1; then cluster_ok=1; fi

if [[ -z "$GATEWAY_NAMESPACE" && $cluster_ok -eq 1 ]]; then
    GATEWAY_NAMESPACE=$("$KUBECTL" get gateway -A -o json 2>/dev/null \
        | jq -r --arg n "$GATEWAY_NAME" '[.items[] | select(.metadata.name==$n)][0].metadata.namespace // empty')
fi
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"

# The newest Running and Ready gateway pod. `.items[0]` can be a Terminating
# pod during a rollout, and its dump describes the previous configuration.
gateway_pod() {
    "$KUBECTL" get pod -n "$GATEWAY_NAMESPACE" -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
        -o json 2>/dev/null | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except ValueError:
    raise SystemExit
best = None
for pod in payload.get("items", []):
    if pod["status"].get("phase") != "Running" or pod["metadata"].get("deletionTimestamp"):
        continue
    if not any(c["type"] == "Ready" and c["status"] == "True" for c in pod["status"].get("conditions", [])):
        continue
    stamp = pod["metadata"]["creationTimestamp"]
    if best is None or stamp >= best[0]:
        best = (stamp, pod["metadata"]["name"])
if best:
    print(best[1])
'
}

pod=""
if [[ -n "$DUMP" ]]; then
    [[ -s "$DUMP" ]] || { echo "dump file $DUMP is empty or missing" >&2; exit 2; }
    cp "$DUMP" "$work/config_dump.json"
else
    [[ $cluster_ok -eq 1 ]] || { echo "cluster unreachable and no --dump given" >&2; exit 2; }
    pod="$(gateway_pod)"
    [[ -n "$pod" ]] || { echo "no Running+Ready pod for gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}" >&2; exit 2; }
    "$KUBECTL" exec -n "$GATEWAY_NAMESPACE" "$pod" -c istio-proxy -- \
        pilot-agent request GET config_dump > "$work/config_dump.json" 2>/dev/null \
    || "$KUBECTL" exec -n "$GATEWAY_NAMESPACE" "$pod" -c istio-proxy -- \
        curl -s --max-time 20 localhost:15000/config_dump > "$work/config_dump.json" 2>/dev/null \
    || true
    [[ -s "$work/config_dump.json" ]] || { echo "could not read config_dump from ${pod}" >&2; exit 2; }
fi

if [[ $cluster_ok -eq 1 ]]; then
    "$KUBECTL" get envoyfilter -n "$GATEWAY_NAMESPACE" -o json > "$work/envoyfilters.json" 2>/dev/null || echo '{"items":[]}' > "$work/envoyfilters.json"
    "$KUBECTL" get wasmplugin -n "$GATEWAY_NAMESPACE" -o json > "$work/wasmplugins.json" 2>/dev/null || echo '{"items":[]}' > "$work/wasmplugins.json"
    "$KUBECTL" get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o json > "$work/gateway.json" 2>/dev/null || echo '{}' > "$work/gateway.json"
else
    echo '{"items":[]}' > "$work/envoyfilters.json"
    echo '{"items":[]}' > "$work/wasmplugins.json"
    echo '{}' > "$work/gateway.json"
fi

python3 - "$work" "$GATEWAY_NAME" "$GATEWAY_NAMESPACE" "$EF_NAME" "$pod" "$LISTENER_PORT" "$JSON" "$EXPECT" <<'PY'
import json, sys, re

work, gw, gw_ns, ef_name, pod, listener_port, as_json, expect = sys.argv[1:9]
as_json = as_json == "1"

ISTIO_EXT_PROC = "envoy.filters.http.ext_proc"
IPP_PRE = "envoy.filters.http.ext_proc.ipp-pre"
IPP = "envoy.filters.http.ext_proc.ipp"
ROUTER = "envoy.filters.http.router"
RAW_WASM = "envoy.filters.http.wasm"
WASMPLUGIN_PREFIX = "extensions.istio.io/wasmplugin/"
TRAFFICEXT_PREFIX = "extensions.istio.io/trafficextension/"

def load(name):
    with open(f"{work}/{name}") as fh:
        return json.load(fh)

dump = load("config_dump.json")
efs = load("envoyfilters.json").get("items", [])
wasmplugins = load("wasmplugins.json").get("items", [])
gateway = load("gateway.json")

configs = dump.get("configs", [])

# --- listeners -> HCM http_filters chains ---------------------------------
def hcm_chains():
    out = []
    for c in configs:
        if not c.get("@type", "").endswith("ListenersConfigDump"):
            continue
        for grp in ("dynamic_listeners", "static_listeners"):
            for l in c.get(grp, []):
                ls = l.get("active_state", l).get("listener", l.get("listener", {}))
                name = ls.get("name") or l.get("name") or "?"
                port = None
                sa = ls.get("address", {}).get("socket_address", {})
                if "port_value" in sa:
                    port = sa["port_value"]
                m = re.search(r"_(\d+)$", name)
                if port is None and m:
                    port = int(m.group(1))
                chains = list(ls.get("filter_chains", []))
                if "default_filter_chain" in ls:
                    chains.append(ls["default_filter_chain"])
                for fc in chains:
                    for f in fc.get("filters", []):
                        if f.get("name") != "envoy.filters.network.http_connection_manager":
                            continue
                        tc = f.get("typed_config", {})
                        names = [h.get("name") for h in tc.get("http_filters", [])]
                        rds = (tc.get("rds") or {}).get("route_config_name")
                        out.append({"listener": name, "port": port, "chain_name": fc.get("name"),
                                    "filters": names, "rds": rds})
    return out

def is_auth(name):
    return name == RAW_WASM or name.startswith(WASMPLUGIN_PREFIX) or name.startswith(TRAFFICEXT_PREFIX)

chains = hcm_chains()
if listener_port:
    chains = [c for c in chains if str(c["port"]) == str(listener_port)] or chains
if not chains:
    print("no HTTP connection manager found in the dump", file=sys.stderr)
    sys.exit(2)
# Prefer the chain that carries an auth filter; a gateway serving both 80 and
# 443 has identical chains, and the probe listeners (15021, 15090) only have
# a router.
chains.sort(key=lambda c: (any(is_auth(n) for n in c["filters"]), len(c["filters"])), reverse=True)
chain = chains[0]
filters = chain["filters"]

def first_index(pred):
    for i, n in enumerate(filters):
        if pred(n):
            return i
    return -1

idx = {
    "istio_ext_proc": first_index(lambda n: n == ISTIO_EXT_PROC),
    "ipp_pre": first_index(lambda n: n == IPP_PRE),
    "auth": first_index(is_auth),
    "ipp": first_index(lambda n: n == IPP),
    "router": first_index(lambda n: n == ROUTER),
    "istio_stats": first_index(lambda n: n == "istio.stats"),
}
counts = {n: filters.count(n) for n in (ISTIO_EXT_PROC, IPP_PRE, IPP, RAW_WASM)}
auth_name = filters[idx["auth"]] if idx["auth"] >= 0 else ""
if auth_name == RAW_WASM:
    auth_mechanism = "raw-wasm"
elif auth_name.startswith(WASMPLUGIN_PREFIX) or auth_name.startswith(TRAFFICEXT_PREFIX):
    auth_mechanism = "wasmplugin"
else:
    auth_mechanism = "none"

# --- routes ----------------------------------------------------------------
routes = []
for c in configs:
    if not c.get("@type", "").endswith("RoutesConfigDump"):
        continue
    for r in c.get("dynamic_route_configs", []) + c.get("static_route_configs", []):
        rc = r.get("route_config", {})
        # Only the route table the analysed listener serves; a gateway with an
        # http and an https listener carries the same routes twice.
        if chain.get("rds") and rc.get("name") != chain["rds"]:
            continue
        for vh in rc.get("virtual_hosts", []):
            for rt in vh.get("routes", []):
                m = rt.get("match", {})
                path = m.get("path") or m.get("prefix") or m.get("path_separated_prefix") or (m.get("safe_regex") or {}).get("regex") or ""
                hdr = ""
                for h in m.get("headers", []):
                    if h.get("name", "").lower() == "x-gateway-model-name":
                        sm = h.get("string_match", {})
                        hdr = sm.get("exact") or sm.get("prefix") or h.get("exact_match") or "*"
                action = rt.get("route", {})
                clusters = []
                if "cluster" in action:
                    clusters = [action["cluster"]]
                elif "weighted_clusters" in action:
                    clusters = [w.get("name") for w in action["weighted_clusters"].get("clusters", [])]
                pfc = rt.get("typed_per_filter_config", {}) or {}
                ov = pfc.get(ISTIO_EXT_PROC)
                picker = None
                if ov:
                    if ov.get("disabled"):
                        picker = "disabled"
                    else:
                        picker = ((ov.get("overrides") or {}).get("grpc_service") or {}).get("envoy_grpc", {}).get("cluster_name")
                pool = any("-inference-pool-" in cl for cl in clusters)
                if pool or picker or hdr:
                    routes.append({
                        "route_config": rc.get("name"), "vhost": vh.get("name"), "name": rt.get("name"),
                        "path": path, "header": hdr, "clusters": clusters, "pool_backed": pool,
                        "picker": picker,
                        "ipp_pre_disabled": bool((pfc.get(IPP_PRE) or {}).get("disabled")),
                        "ipp_disabled": bool((pfc.get(IPP) or {}).get("disabled")),
                    })
pool_routes = [r for r in routes if r["pool_backed"]]
gated_routes = [r for r in pool_routes if r["header"]]

# --- verdicts --------------------------------------------------------------
# Structural: decided from the chain order alone. The InferencePool filter
# merges its ExtProcPerRoute once, in decodeHeaders, against whatever route
# is matched at that moment; a route gated on X-Gateway-Model-Name cannot be
# matched before ipp-pre has produced the header.
def pos(key):
    return f"[{idx[key] + 1}]" if idx[key] >= 0 else "absent"

verdicts = {}
notes = {}
gating = f"{len(gated_routes)} of {len(pool_routes)} pool routes on this listener require X-Gateway-Model-Name"
if idx["istio_ext_proc"] < 0:
    verdicts["EPP_ENGAGED"] = "N/A"
    notes["EPP_ENGAGED"] = "no InferencePool ext_proc on this listener (no InferencePool attached, or istiod started before the GIE CRDs)"
elif idx["ipp_pre"] < 0:
    verdicts["EPP_ENGAGED"] = "N/A"
    notes["EPP_ENGAGED"] = f"no ipp-pre in the chain; {gating} and would never match"
elif idx["ipp_pre"] < idx["istio_ext_proc"]:
    verdicts["EPP_ENGAGED"] = "OK"
    notes["EPP_ENGAGED"] = (f"ipp-pre {pos('ipp_pre')} runs before envoy.filters.http.ext_proc {pos('istio_ext_proc')}, "
                            f"so the header exists when the per-route picker is read; {gating}")
else:
    verdicts["EPP_ENGAGED"] = "BROKEN"
    notes["EPP_ENGAGED"] = (f"ipp-pre {pos('ipp_pre')} runs after envoy.filters.http.ext_proc {pos('istio_ext_proc')}; "
                            f"{gating}, so at {pos('istio_ext_proc')} no such route matches, no picker is merged, "
                            "and the re-route after ipp-pre cannot bring the filter back")
if idx["auth"] < 0:
    verdicts["AUTH_SEES_MODEL_HEADER"] = "N/A"
elif idx["ipp_pre"] >= 0 and idx["ipp_pre"] < idx["auth"]:
    verdicts["AUTH_SEES_MODEL_HEADER"] = "OK"
else:
    verdicts["AUTH_SEES_MODEL_HEADER"] = "BROKEN"
if idx["auth"] < 0 or idx["ipp"] < 0:
    verdicts["IPP_AFTER_AUTH"] = "N/A"
else:
    verdicts["IPP_AFTER_AUTH"] = "yes" if idx["ipp"] > idx["auth"] else "no"
if idx["auth"] < 0 or idx["istio_ext_proc"] < 0:
    verdicts["EPP_AFTER_AUTH"] = "N/A"
else:
    verdicts["EPP_AFTER_AUTH"] = "yes" if idx["istio_ext_proc"] > idx["auth"] else "no"
verdicts["NO_DUPLICATES"] = "OK" if all(v <= 1 for v in counts.values()) else "BROKEN"
verdicts["ROUTER_LAST"] = "OK" if idx["router"] == len(filters) - 1 else "BROKEN"

# --- routes ----------------------------------------------------------------
routes = []
for c in configs:
    if not c.get("@type", "").endswith("RoutesConfigDump"):
        continue
    for r in c.get("dynamic_route_configs", []) + c.get("static_route_configs", []):
        rc = r.get("route_config", {})
        # Only the route table the analysed listener serves; a gateway with an
        # http and an https listener carries the same routes twice.
        if chain.get("rds") and rc.get("name") != chain["rds"]:
            continue
        for vh in rc.get("virtual_hosts", []):
            for rt in vh.get("routes", []):
                m = rt.get("match", {})
                path = m.get("path") or m.get("prefix") or m.get("path_separated_prefix") or (m.get("safe_regex") or {}).get("regex") or ""
                hdr = ""
                for h in m.get("headers", []):
                    if h.get("name", "").lower() == "x-gateway-model-name":
                        sm = h.get("string_match", {})
                        hdr = sm.get("exact") or sm.get("prefix") or h.get("exact_match") or "*"
                action = rt.get("route", {})
                clusters = []
                if "cluster" in action:
                    clusters = [action["cluster"]]
                elif "weighted_clusters" in action:
                    clusters = [w.get("name") for w in action["weighted_clusters"].get("clusters", [])]
                pfc = rt.get("typed_per_filter_config", {}) or {}
                ov = pfc.get(ISTIO_EXT_PROC)
                picker = None
                if ov:
                    if ov.get("disabled"):
                        picker = "disabled"
                    else:
                        picker = ((ov.get("overrides") or {}).get("grpc_service") or {}).get("envoy_grpc", {}).get("cluster_name")
                pool = any("-inference-pool-" in cl for cl in clusters)
                if pool or picker or hdr:
                    routes.append({
                        "route_config": rc.get("name"), "vhost": vh.get("name"), "name": rt.get("name"),
                        "path": path, "header": hdr, "clusters": clusters, "pool_backed": pool,
                        "picker": picker,
                        "ipp_pre_disabled": bool((pfc.get(IPP_PRE) or {}).get("disabled")),
                        "ipp_disabled": bool((pfc.get(IPP) or {}).get("disabled")),
                    })

# --- EnvoyFilters ----------------------------------------------------------
def ef_selects(ef):
    spec = ef.get("spec", {})
    sel = (spec.get("workloadSelector") or {}).get("labels") or {}
    if sel.get("gateway.networking.k8s.io/gateway-name") == gw:
        return "workloadSelector"
    for tr in spec.get("targetRefs", []) or ([spec["targetRef"]] if spec.get("targetRef") else []):
        if tr.get("name") == gw:
            return "targetRef"
    if not sel and not spec.get("targetRefs") and not spec.get("targetRef"):
        return "unscoped"
    return None

ef_report = []
maas_ef = {"name": ef_name, "present": False, "mode": "absent", "anchors": []}
for ef in efs:
    how = ef_selects(ef)
    if not how:
        continue
    spec = ef.get("spec", {})
    patches = []
    for cp in spec.get("configPatches", []):
        if cp.get("applyTo") != "HTTP_FILTER":
            continue
        anchor = ((((cp.get("match") or {}).get("listener") or {}).get("filterChain") or {}).get("filter") or {}).get("subFilter", {}).get("name")
        op = (cp.get("patch") or {}).get("operation")
        inserted = ((cp.get("patch") or {}).get("value") or {}).get("name")
        if op == "REMOVE":
            matched = "n/a"
        elif op in ("INSERT_BEFORE", "INSERT_AFTER") and anchor:
            matched = "yes" if anchor in filters else "no"
        else:
            matched = "n/a"
        patches.append({"op": op, "anchor": anchor, "inserts": inserted, "anchor_in_chain": matched})
    entry = {"name": ef["metadata"]["name"], "priority": spec.get("priority", 0), "selects_by": how, "http_filter_patches": patches}
    ef_report.append(entry)
    if ef["metadata"]["name"] == ef_name:
        maas_ef["present"] = True
        anchors = sorted({p["anchor"] for p in patches if p["anchor"] and p["inserts"] in (IPP_PRE, IPP)})
        maas_ef["anchors"] = anchors
        if any(a == RAW_WASM or a.startswith(WASMPLUGIN_PREFIX) or a.startswith(TRAFFICEXT_PREFIX) for a in anchors):
            maas_ef["mode"] = "wasm-anchored"
        elif anchors == [ROUTER]:
            maas_ef["mode"] = "router-fallback"
        elif ISTIO_EXT_PROC in anchors:
            maas_ef["mode"] = "extproc-anchored"
        else:
            maas_ef["mode"] = "unknown"
ef_report.sort(key=lambda e: (e["priority"], e["name"]))

kuadrant = {
    "envoyfilter": any(e["metadata"]["name"] == f"kuadrant-{gw}" for e in efs),
    "wasmplugin": any(w["metadata"]["name"] == f"kuadrant-{gw}" for w in wasmplugins),
}

result = {
    "gateway": {"name": gw, "namespace": gw_ns, "pod": pod or None,
                "listener": chain["listener"], "port": chain["port"]},
    "chain": filters,
    "indices": idx,
    "counts": counts,
    "auth_mechanism": auth_mechanism,
    "verdicts": verdicts,
    "notes": notes,
    "routes": routes,
    "envoyfilters": ef_report,
    "maas_ef": maas_ef,
    "kuadrant": kuadrant,
}

if as_json:
    print(json.dumps(result, indent=1))
else:
    print(f"Gateway {gw_ns}/{gw}" + (f"  pod {pod}" if pod else "  (offline dump)") + f"  listener {chain['listener']}")
    print()
    print("HTTP filter chain:")
    tags = {ISTIO_EXT_PROC: "<- Istio InferencePool filter (EPP per-route override read here)",
            IPP_PRE: "<- MaaS pre-processing (sets X-Gateway-Model-Name)",
            IPP: "<- MaaS post-processing"}
    for i, n in enumerate(filters):
        tag = tags.get(n, "")
        if is_auth(n):
            tag = f"<- Kuadrant auth ({auth_mechanism})"
        print(f"  [{i+1:2}] {n}  {tag}".rstrip())
    print()
    print("Verdicts:")
    for k, v in verdicts.items():
        line = f"  {k:24} {v}"
        if k in notes:
            line += f"  ({notes[k]})"
        print(line)
    print()
    print(f"Kuadrant object kuadrant-{gw}: envoyfilter={kuadrant['envoyfilter']} wasmplugin={kuadrant['wasmplugin']}")
    print(f"MaaS EnvoyFilter {ef_name}: present={maas_ef['present']} mode={maas_ef['mode']} anchors={maas_ef['anchors']}")
    print()
    print("EnvoyFilters selecting this gateway (priority order):")
    for e in ef_report:
        print(f"  {e['name']}  priority={e['priority']}  via {e['selects_by']}")
        for p in e["http_filter_patches"]:
            print(f"      {p['op']:14} anchor={p['anchor']}  inserts={p['inserts']}  anchor_in_chain={p['anchor_in_chain']}")
    print()
    pool_routes = [r for r in routes if r["pool_backed"]]
    gated = [r for r in pool_routes if r["header"]]
    print(f"Pool-backed routes: {len(pool_routes)}  header-gated: {len(gated)}  with picker override: {sum(1 for r in pool_routes if r['picker'] and r['picker'] != 'disabled')}")
    for r in pool_routes[:12]:
        print(f"  {r['name']}  path={r['path'] or '-'}  header={r['header'] or '-'}  picker={r['picker'] or 'NONE'}")
    if len(pool_routes) > 12:
        print(f"  ... {len(pool_routes) - 12} more")

v = verdicts["EPP_ENGAGED"]
if expect == "broken":
    sys.exit(0 if v == "BROKEN" else 1)
if expect == "ok":
    sys.exit(0 if v == "OK" else 1)
sys.exit(1 if v == "BROKEN" or verdicts["NO_DUPLICATES"] == "BROKEN" else 0)
PY
