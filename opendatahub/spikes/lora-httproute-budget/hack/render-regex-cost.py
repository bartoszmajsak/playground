#!/usr/bin/env python3
"""Render a route that forces a KNOWN number of header-match evaluations.

Measuring one regex evaluation against a 1.5ms request is hopeless: the effect is
smaller than the run-to-run noise on a laptop. So amplify it. Every match here
shares a path the probe request satisfies and a header value it does NOT, so
Envoy must evaluate the header matcher and move on, `depth` times, before
reaching the terminal rule.

Two slopes fall out of it:

  depth sweep at fixed pattern size  -> cost per evaluation
  size sweep at fixed depth          -> how that cost scales with pattern length

Both are differential, so whatever the laptop is doing cancels out as long as
configurations are interleaved.

  render-regex-cost.py <regex|exact> <adapters> <depth>

`adapters` sets the pattern size the same way the real shape does: the alternation
lists 1 + N names. depth is the number of evaluations forced, capped by the
route-wide 128-match limit.
"""
import re
import sys

import yaml

NS, MODEL = "lora-budget", "model-a"
HDR = "X-Gateway-Model-Name"
MAX_MATCHES_PER_RULE = 64
MAX_MATCHES_PER_ROUTE = 128

kind, n, depth = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
if depth + 1 > MAX_MATCHES_PER_ROUTE:
    raise SystemExit("depth %d + terminal exceeds the route-wide %d cap" % (depth, MAX_MATCHES_PER_ROUTE))

prefix = "publishers/%s/models/" % NS
tails = [MODEL] + ["adapter-a%d" % i for i in range(1, n + 1)]

# The pattern is EXACTLY the one the real alternation shape ships, byte for byte.
# What makes the probe miss is the header value it is fed: see MISS in the caller.
# That value shares the longest possible prefix with a real alternative and
# diverges only at its final character, so RE2 scans the whole input before
# failing. A value that diverged early would go to a dead state immediately and
# flatter the result.
pattern = re.escape(prefix) + "(" + "|".join(re.escape(t) for t in tails) + ")"
exact_val = prefix + "no-such-model"

pool = [{"kind": "Service", "name": "echo-pool", "port": 8000, "weight": 1}]
svc = [{"kind": "Service", "name": "echo-service", "port": 8000, "weight": 1}]


def matcher():
    if kind == "regex":
        return [{"type": "RegularExpression", "name": HDR, "value": pattern}]
    return [{"type": "Exact", "name": HDR, "value": exact_val}]


rules, left, idx = [], depth, 0
while left > 0:
    take = min(left, MAX_MATCHES_PER_RULE)
    rules.append({"name": "burn-%d" % idx, "backendRefs": pool,
                  "matches": [{"path": {"type": "PathPrefix", "value": "/v1"},
                               "headers": matcher()} for _ in range(take)]})
    left -= take
    idx += 1

# The probe lands here, in every configuration, after `depth` failed evaluations.
rules.append({"name": "terminal", "backendRefs": svc,
              "matches": [{"path": {"type": "PathPrefix", "value": "/v1"}}]})

print(yaml.safe_dump({
    "apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
    "metadata": {"name": "latency-probe", "namespace": NS,
                 "annotations": {"spike/kind": kind, "spike/adapters": str(n),
                                 "spike/depth": str(depth),
                                 "spike/pattern-bytes": str(len(pattern))}},
    "spec": {"parentRefs": [{"group": "gateway.networking.k8s.io", "kind": "Gateway",
                             "name": "kserve-ingress-gateway", "namespace": "kserve"}],
             "rules": rules}}, sort_keys=False))
