#!/usr/bin/env bash
# Measure each shape's real adapter ceiling against the apiserver.
#
# Synthesises the route at increasing adapter counts and asks the apiserver to
# validate it with --dry-run=server. That is the same CEL and maxItems check the
# controller trips over, minus the controller, the workload and any traffic --
# so a full sweep costs seconds and the answer comes from the cluster's actual
# CRD rather than from arithmetic in a document.
#
# Usage:
#   ./probe-ceiling.sh                 # all shapes
#   ./probe-ceiling.sh collapse        # one shape

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SHAPES=("${@:-}")
[[ -z "${SHAPES[*]}" ]] && SHAPES=(current split split-noslash prefix split-prefix alternation nested collapse collapse-dedup)

render() {  # shape, adapters -> route yaml on stdout
    python3 - "$1" "$2" <<'PY'
import sys, copy, re, yaml

shape, n = sys.argv[1], int(sys.argv[2])
NS, MODEL = "lora-budget", "model-a"
TARGET = "v1-model-routing"
ENDPOINTS = ["/v1/completions", "/v1/chat/completions", "/v1/responses", "/v1/messages"]
HDR = "X-Gateway-Model-Name"

def q(name):
    return "publishers/{}/models/{}".format(NS, name)

def slug(s):
    """HTTPRouteRule.name must be a DNS-label-ish token: no slashes."""
    return s.strip("/").replace("/", "-")

names = [q(MODEL)] + [q("adapter-a{}".format(i)) for i in range(1, n + 1)]

def hdr(v):
    return [{"type": "Exact", "name": HDR, "value": v}]

pool = [{"group": "inference.networking.k8s.io", "kind": "InferencePool",
         "name": "svc-a-inference-pool", "port": 8000, "weight": 1}]
svc = [{"kind": "Service", "name": "svc-a-kserve-workload-svc", "port": 8000, "weight": 1}]
timeouts = {"backendRequest": "0s", "request": "0s"}

def rewrite(ep):
    return [{"type": "URLRewrite",
             "urlRewrite": {"path": {"type": "ReplacePrefixMatch", "replacePrefixMatch": ep}}}]

rules = []
# name-path family
for ep in ENDPOINTS:
    rules.append({"name": "name-{}".format(slug(ep)), "backendRefs": pool, "filters": rewrite(ep),
                  "timeouts": timeouts,
                  "matches": [{"path": {"type": "PathPrefix",
                                        "value": "/{}/svc-a{}".format(NS, ep)}}]})

# the rule under test
if shape == "current":
    m = []
    for ep in ENDPOINTS:
        for p in (ep, ep + "/"):
            for v in names:
                m.append({"path": {"type": "Exact", "value": p}, "headers": hdr(v)})
    rules.append({"name": TARGET, "backendRefs": pool, "timeouts": timeouts, "matches": m})
elif shape in ("split", "split-noslash"):
    for ep in ENDPOINTS:
        paths = [ep] if shape == "split-noslash" else [ep, ep + "/"]
        m = [{"path": {"type": "Exact", "value": p}, "headers": hdr(v)}
             for p in paths for v in names]
        rules.append({"name": "{}-{}".format(TARGET, slug(ep)),
                      "backendRefs": pool, "timeouts": timeouts, "matches": m})
elif shape == "alternation":
    # One regex listing the existing names. Match COUNT is constant; what grows
    # is the pattern, bounded by the CRD's 4096-byte cap on a header value.
    pat = re.escape(q(MODEL) + "/") .rsplit("/", 1)[0]
    prefix = "publishers/" + NS + "/models/"
    tails = [MODEL] + ["adapter-a%d" % i for i in range(1, n + 1)]
    pat = re.escape(prefix) + "(" + "|".join(re.escape(t) for t in tails) + ")"
    m = [{"path": {"type": "Exact", "value": p2}, "headers":
          [{"type": "RegularExpression", "name": HDR, "value": pat}]}
         for ep in ENDPOINTS for p2 in (ep, ep + "/")]
    rules.append({"name": TARGET, "backendRefs": pool, "timeouts": timeouts, "matches": m})
elif shape == "nested":
    # One regex covers the base model and everything nested beneath it, so the
    # adapter axis disappears from the route entirely: match count is constant.
    pat = re.escape(q(MODEL)) + "(/.*)?"
    m = [{"path": {"type": "Exact", "value": p}, "headers":
          [{"type": "RegularExpression", "name": HDR, "value": pat}]}
         for ep in ENDPOINTS for p in (ep, ep + "/")]
    rules.append({"name": TARGET, "backendRefs": pool, "timeouts": timeouts, "matches": m})
elif shape == "prefix":
    # PathPrefix makes the trailing-slash twin redundant: one match per endpoint
    m = [{"path": {"type": "PathPrefix", "value": ep}, "headers": hdr(v)}
         for ep in ENDPOINTS for v in names]
    rules.append({"name": TARGET, "backendRefs": pool, "timeouts": timeouts, "matches": m})
elif shape == "split-prefix":
    for ep in ENDPOINTS:
        m = [{"path": {"type": "PathPrefix", "value": ep}, "headers": hdr(v)} for v in names]
        rules.append({"name": "{}-{}".format(TARGET, slug(ep)),
                      "backendRefs": pool, "timeouts": timeouts, "matches": m})
elif shape in ("collapse", "collapse-dedup"):
    rules.append({"name": TARGET, "backendRefs": pool, "timeouts": timeouts,
                  "matches": [{"headers": hdr(v)} for v in names]})
else:
    raise SystemExit("unknown shape " + shape)

# publisher family
for ep in ENDPOINTS:
    rules.append({"name": "pub-{}".format(slug(ep)), "backendRefs": pool, "filters": rewrite(ep),
                  "timeouts": timeouts,
                  "matches": [{"path": {"type": "PathPrefix",
                                        "value": "/publishers/{}/models/{}{}".format(NS, MODEL, ep)}}]})
rules.append({"name": "pub-catch-all", "backendRefs": svc, "timeouts": timeouts,
              "filters": [{"type": "URLRewrite", "urlRewrite": {"path": {"type": "ReplacePrefixMatch", "replacePrefixMatch": "/"}}}],
              "matches": [{"path": {"type": "PathPrefix", "value": "/publishers/{}/models/{}".format(NS, MODEL)}}]})
rules.append({"name": "catch-all", "backendRefs": svc, "timeouts": timeouts,
              "filters": [{"type": "URLRewrite", "urlRewrite": {"path": {"type": "ReplacePrefixMatch", "replacePrefixMatch": "/"}}}],
              "matches": [{"path": {"type": "PathPrefix", "value": "/{}/svc-a".format(NS)}}]})
if shape != "collapse-dedup":
    rules.append({"name": "catch-all-model-routing", "backendRefs": svc, "timeouts": timeouts,
                  "matches": ([{"headers": [{"type": "RegularExpression", "name": HDR,
                                             "value": re.escape(q(MODEL)) + "(/.*)?"}]}]
                              if shape == "nested" else
                              [{"headers": [{"type": "RegularExpression", "name": HDR,
                                             "value": re.escape("publishers/" + NS + "/models/") + "("
                                                      + "|".join(re.escape(t) for t in
                                                                 [MODEL] + ["adapter-a%d" % i for i in range(1, n + 1)])
                                                      + ")"}]}]
                              if shape == "alternation" else
                              [{"headers": hdr(v)} for v in names])})

print(yaml.safe_dump({
    "apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
    "metadata": {"name": "ceiling-probe", "namespace": NS},
    "spec": {"parentRefs": [{"group": "gateway.networking.k8s.io", "kind": "Gateway",
                             "name": "kserve-ingress-gateway", "namespace": "kserve"}],
             "rules": rules}}, sort_keys=False))
PY
}

stats() {  # shape, adapters -> "rules maxrule total"
    render "$1" "$2" | python3 -c '
import sys, yaml
r = yaml.safe_load(sys.stdin)["spec"]["rules"]
c = [len(x.get("matches", [])) for x in r]
print(len(r), max(c), sum(c))'
}

echo -e "${BOLD}Adapter ceiling per shape (server-side dry-run)${NC}"
printf '  %-14s %-6s %-7s %-9s %-7s %s\n' shape maxA rules 'max/rule' total 'first rejection'
printf '  %-14s %-6s %-7s %-9s %-7s %s\n' -------------- ------ ------- --------- ------- ---------------

for shape in "${SHAPES[@]}"; do
    last_ok=-1; reason=""
    for n in $(seq 0 400); do
        if render "$shape" "$n" | kubectl apply --dry-run=server -f - >/dev/null 2>/tmp/ceilerr; then
            last_ok=$n
        else
            reason=$(grep -oE '(spec\.rules[^,]*|Too many: [0-9]+[^,]*|must have at most [0-9]+ items|total number of matches[^"]*)' /tmp/ceilerr | head -1)
            [[ -z "$reason" ]] && reason=$(head -c 90 /tmp/ceilerr | tr '\n' ' ')
            break
        fi
    done
    read -r rules maxrule total < <(stats "$shape" "$last_ok")
    printf "  %-14s ${GREEN}%-6s${NC} %-7s %-9s %-7s %s\n" \
        "$shape" "$last_ok" "$rules" "$maxrule" "$total" "${reason:0:52}"
done

echo
echo -e "  ${CYAN}INFO${NC}: maxA is the largest adapter count the apiserver accepts;"
echo -e "  ${CYAN}INFO${NC}: rules/max-rule/total are measured at that count."
