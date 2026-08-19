#!/usr/bin/env bash
# Rewrite a captured HTTPRoute so its backends are directly observable.
#
# Pure transform, no cluster contact. Reads a route captured by
# capture-routes.sh and emits the same object with:
#
#   backendRef kind=InferencePool         -> Service echo-pool
#   backendRef kind=Service (workload svc) -> Service echo-service
#
# Everything else -- rule names, order, matches, filters, timeouts -- is left
# byte-for-byte alone, because that is what is under characterization.
#
# Usage:
#   ./swap-backends.sh golden/route-current.yaml > manifests/route-current-swapped.yaml
#   ./capture-routes.sh && ./swap-backends.sh golden/route-current.yaml | kubectl apply -f -

set -euo pipefail

SRC="${1:-}"
[[ -f "$SRC" ]] || { echo "usage: $0 <captured-route.yaml>" >&2; exit 2; }

python3 - "$SRC" <<'PY'
import sys, yaml

POOL_KIND = "InferencePool"

def swap(ref):
    kind = ref.get("kind", "Service")
    name = "echo-pool" if kind == POOL_KIND else "echo-service"
    # Drop group/weight/filters that only made sense for the original target.
    return {"kind": "Service", "name": name, "port": 8000}

docs = []
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not doc:
        continue
    if doc.get("kind") != "HTTPRoute":
        docs.append(doc)
        continue

    md = doc.setdefault("metadata", {})
    md["name"] = md["name"] + "-characterize"
    for k in ("ownerReferences", "resourceVersion", "uid", "generation",
              "creationTimestamp", "managedFields", "annotations"):
        md.pop(k, None)
    doc.pop("status", None)

    for rule in doc.get("spec", {}).get("rules", []):
        if "backendRefs" in rule:
            rule["backendRefs"] = [swap(r) for r in rule["backendRefs"]]

    docs.append(doc)

yaml.safe_dump_all(docs, sys.stdout, sort_keys=False, default_flow_style=False)
PY
