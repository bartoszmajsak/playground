#!/usr/bin/env python3
"""If adapters ever became path-addressable, does the path axis hit a ceiling too?

Today it cannot: every path rule keys on the SERVICE name or the BASE MODEL name,
and neither multiplies by adapter count. Only the two header rules grow. That is
why the seven-adapter ceiling is a header problem.

It is worth asking anyway, because on OpenShift AI the header family is denied
outright and publisher paths are the only authorized way to address a model - so
an adapter currently has no authorized path-based address at all. Giving it one
puts adapters on the path axis, and this measures what that costs.

  flat      /publishers/{ns}/models/{adapter}/v1/completions
            one rule per (endpoint, adapter). Linear, like today's header rules.

  flat-rx   the same names collapsed into one RegularExpression path per
            endpoint. PathPrefix cannot express it - a prefix match has no
            wildcard - so this is necessarily a regex, with the same program-size
            exposure the header alternation has.

  nested    /publishers/{ns}/models/{base}/adapters/{adapter}/v1/completions
            one RegularExpression path per endpoint, constant whatever the
            adapter count, because the adapter name sits in a wildcard segment.

  render-adapter-paths.py <flat|flat-rx|nested> <adapters>
"""
import re
import sys

import yaml

NS, MODEL = "lora-budget", "model-a"
ENDPOINTS = ["/v1/completions", "/v1/chat/completions", "/v1/responses", "/v1/messages"]
SAFE = re.compile(r"^[a-z0-9.-]+$")

shape, n = sys.argv[1], int(sys.argv[2])
pool = [{"kind": "Service", "name": "echo-pool", "port": 8000, "weight": 1}]
adapters = ["sql-coder-%d" % i for i in range(1, n + 1)]


def esc(s):
    return s.replace(".", r"\.") if SAFE.match(s) else re.escape(s)


def slug(ep):
    return ep.strip("/").replace("/", "-")


rules = []
for ep in ENDPOINTS:
    if shape == "flat":
        matches = [{"path": {"type": "PathPrefix",
                             "value": "/publishers/%s/models/%s%s" % (NS, a, ep)}}
                   for a in adapters]
    elif shape == "flat-rx":
        alt = "|".join(esc(a) for a in adapters)
        matches = [{"path": {"type": "RegularExpression",
                             "value": "/publishers/%s/models/(%s)%s"
                                      % (esc(NS), alt, esc(ep))}}]
    elif shape == "nested":
        # The adapter name lives in a wildcard segment, so the pattern does not
        # grow. This is the path-axis twin of the nested header regex.
        matches = [{"path": {"type": "RegularExpression",
                             "value": "/publishers/%s/models/%s(/adapters/[^/]+)?%s"
                                      % (esc(NS), esc(MODEL), esc(ep))}}]
    else:
        raise SystemExit("unknown shape " + shape)
    rules.append({"name": "adapter-%s" % slug(ep), "backendRefs": pool, "matches": matches})

bytes_max = max((len(m["path"]["value"]) for r in rules for m in r["matches"]), default=0)
print(yaml.safe_dump({
    "apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
    "metadata": {"name": "adapter-paths", "namespace": NS,
                 "annotations": {"spike/shape": shape, "spike/adapters": str(n),
                                 "spike/bytes": str(bytes_max),
                                 "spike/matches": str(sum(len(r["matches"]) for r in rules))}},
    "spec": {"parentRefs": [{"group": "gateway.networking.k8s.io", "kind": "Gateway",
                             "name": "kserve-ingress-gateway", "namespace": "kserve"}],
             "rules": rules}}, sort_keys=False))
