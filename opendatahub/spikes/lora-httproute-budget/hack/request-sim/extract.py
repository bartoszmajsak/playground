#!/usr/bin/env python3
"""Extract the routing rules of each shape into JSON the browser can evaluate.

Rules come from make-shape.py, i.e. the same synthesis that produced every golden
file, so the simulator cannot drift from what was measured. The neighbour route is
included because "falls through" is one of the outcomes and it is the thing being
fallen through to.
"""
import json, io, os, subprocess, sys, yaml

REPO = "/home/bartek/code/work/playground/opendatahub/spikes/lora-httproute-budget"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "routes.json")
SHAPES = {"current": "baseline", "split": "split", "split-noslash": "split-noslash",
          "alternation": "alternation", "nested": "nested"}


def compact(doc):
    rules = []
    for r in doc["spec"]["rules"]:
        be = r.get("backendRefs") or []
        ms = []
        for m in r.get("matches", []):
            p = m.get("path")
            ms.append([
                [p.get("type", "PathPrefix"), p["value"]] if p else None,
                [[h["name"].lower(), h.get("type", "Exact"), h["value"]]
                 for h in m.get("headers", [])],
                m.get("method"),
            ])
        rules.append({"n": r.get("name"), "to": be[0]["name"] if be else None, "m": ms})
    return {"r": "%s/%s" % (doc["metadata"]["namespace"],
                            doc["metadata"]["name"].replace("-characterize", "")),
            "rules": rules}


def neighbour():
    for doc in yaml.safe_load_all(io.open(os.path.join(REPO, "manifests/backends.yaml"),
                                          encoding="utf-8")):
        if doc and doc.get("kind") == "HTTPRoute":
            return compact(doc)
    raise SystemExit("neighbour route not found")


data = {}
for label, shape in SHAPES.items():
    txt = subprocess.check_output([sys.executable, "make-shape.py", shape],
                                  cwd=REPO, stderr=subprocess.DEVNULL)
    routes = [compact(d) for d in yaml.safe_load_all(txt) if d]
    routes.append(neighbour())
    data[label] = routes

io.open(OUT, "w", encoding="utf-8").write(json.dumps(data, separators=(",", ":"), sort_keys=True))
print("wrote %s  %d bytes" % (OUT, os.path.getsize(OUT)))
for label in SHAPES:
    n = sum(len(r["m"]) for rt in data[label] for r in rt["rules"])
    print("  %-14s %d routes, %d matches" % (label, len(data[label]), n))
