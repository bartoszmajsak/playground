#!/usr/bin/env python3
"""Render a latency-probe HTTPRoute for one (shape, adapters) pair.

Deliberately NOT the same renderer probe-ceiling.sh uses: every backendRef here
points at an echo Deployment rather than the InferencePool, because the question
is what Envoy's own match evaluation costs, and an ext_proc round trip to the
endpoint picker would be the only thing visible otherwise.

The miss-catcher is PathPrefix /v1 rather than /, so it out-specifies the
neighbour fixture's catch-all and a header miss still lands on a backend we
control. Ties on path length fall back to route age, and the neighbour route is
older than anything this script applies.
"""
import re
import sys

import yaml

NS, MODEL = "lora-budget", "model-a"
HDR = "X-Gateway-Model-Name"
ENDPOINTS = ["/v1/completions", "/v1/chat/completions", "/v1/responses", "/v1/messages"]

shape, n = sys.argv[1], int(sys.argv[2])

pool = [{"kind": "Service", "name": "echo-pool", "port": 8000, "weight": 1}]
svc = [{"kind": "Service", "name": "echo-service", "port": 8000, "weight": 1}]
tails = [MODEL] + ["adapter-a%d" % i for i in range(1, n + 1)]
prefix = "publishers/%s/models/" % NS


def q(name):
    return prefix + name


def exact(v):
    return [{"type": "Exact", "name": HDR, "value": v}]


def rx(pat):
    return [{"type": "RegularExpression", "name": HDR, "value": pat}]


alternation = re.escape(prefix) + "(" + "|".join(re.escape(t) for t in tails) + ")"

rules = []
if shape == "pathonly":
    pass
elif shape == "current":
    rules.append({"name": "v1-model-routing", "backendRefs": pool,
                  "matches": [{"path": {"type": "Exact", "value": p}, "headers": exact(q(v))}
                              for ep in ENDPOINTS for p in (ep, ep + "/") for v in tails]})
elif shape == "alternation":
    rules.append({"name": "v1-model-routing", "backendRefs": pool,
                  "matches": [{"path": {"type": "Exact", "value": p},
                               "headers": rx(alternation)}
                              for ep in ENDPOINTS for p in (ep, ep + "/")]})
elif shape == "collapse":
    rules.append({"name": "v1-model-routing", "backendRefs": pool,
                  "matches": [{"headers": exact(q(v))} for v in tails]})
else:
    raise SystemExit("unknown shape " + shape)

# pathonly needs SOMETHING to send the probe to, and every other shape needs a
# miss-catcher, so both get the same terminal rule. Its cost is in every column.
rules.append({"name": "floor", "backendRefs": pool if shape == "pathonly" else svc,
              "matches": [{"path": {"type": "PathPrefix", "value": "/v1"}}]})

print(yaml.safe_dump({
    "apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
    "metadata": {"name": "latency-probe", "namespace": NS},
    "spec": {"parentRefs": [{"group": "gateway.networking.k8s.io", "kind": "Gateway",
                             "name": "kserve-ingress-gateway", "namespace": "kserve"}],
             "rules": rules}}, sort_keys=False))
