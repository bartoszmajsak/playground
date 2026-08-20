#!/usr/bin/env python3
"""One route, two data planes, identical patterns.

The point is that nothing differs between the Istio and kgateway versions except
the parentRef, so any difference in where a request lands is a difference in how
the data plane interprets a RegularExpression header match - which is the thing
Gateway API leaves implementation-specific and which the alternation shape
depends on.

  model-a, adapter-a1, adapter-a2  -> alternation rule -> echo-pool
  model-b and anything under it    -> nested rule      -> echo-neighbour
  everything else on /v1           -> terminal         -> echo-service

`echo-service` therefore means "no model rule matched", and seeing echo-pool
where the probe table expects a miss is the anchoring failure.
"""
import re
import sys

import yaml

NS = "lora-budget"
HDR = "X-Gateway-Model-Name"
prefix = "publishers/%s/models/" % NS

target = sys.argv[1]
parent = ({"group": "gateway.networking.k8s.io", "kind": "Gateway",
           "name": "kserve-ingress-gateway", "namespace": "kserve"}
          if target == "istio" else
          {"group": "gateway.networking.k8s.io", "kind": "Gateway",
           "name": "kgw", "namespace": NS})

alternation = re.escape(prefix) + "(" + "|".join(
    re.escape(t) for t in ["model-a", "adapter-a1", "adapter-a2"]) + ")"
nested = re.escape(prefix + "model-b") + "(/.*)?"


def rule(name, backend, pattern):
    return {"name": name,
            "backendRefs": [{"kind": "Service", "name": backend, "port": 8000, "weight": 1}],
            "matches": [{"path": {"type": "PathPrefix", "value": "/v1"},
                         "headers": [{"type": "RegularExpression", "name": HDR,
                                      "value": pattern}]}]}


print(yaml.safe_dump({
    "apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
    "metadata": {"name": "anchoring-%s" % target, "namespace": NS},
    "spec": {"parentRefs": [parent],
             "rules": [
                 rule("alternation", "echo-pool", alternation),
                 rule("nested", "echo-neighbour", nested),
                 {"name": "terminal",
                  "backendRefs": [{"kind": "Service", "name": "echo-service",
                                   "port": 8000, "weight": 1}],
                  "matches": [{"path": {"type": "PathPrefix", "value": "/v1"}}]},
             ]}}, sort_keys=False))
