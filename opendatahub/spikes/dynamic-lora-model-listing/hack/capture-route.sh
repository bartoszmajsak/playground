#!/usr/bin/env bash
# Get the route rules from kserve itself, not from a hand-written approximation.
#
# This spike needs a route that indexes N adapters while the runtime loads and
# unloads them underneath. The route must be EXACTLY what kserve generates --
# any hand-rolled shape introduces a difference that then has to be reasoned
# about in every result, which defeats the point.
#
# So: declare the adapters, let the controller reconcile, capture what it
# emitted, then strip the declaration. The captured rules go into
# spec.router.route.http.spec, which keeps the managed gateway and leaves kserve
# owning the HTTPRoute object -- it just stops deriving the rules from
# spec.model.lora, because there is no longer a spec.model.lora to derive from.
#
# The result is a route byte-identical to the managed one for A adapters, and a
# runtime that starts with zero.
#
# Usage:
#   ./hack/capture-route.sh                # 4 adapters
#   ./hack/capture-route.sh 7              # sweep toward the ceiling
#
# Writes manifests/route-rules.yaml and prints the budget arithmetic.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"
NS="${NS:-dynamic-lora}"
SVC="${SVC:-svc-dyn}"
A="${1:-4}"
OUT="${SCRIPT_DIR}/manifests/route-rules.yaml"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YEL='\033[0;33m'; NC='\033[0m'

adapters_json() {
    python3 -c '
import json,sys
n=int(sys.argv[1])
print(json.dumps([{"name": f"adapter-{i}", "uri": f"pvc://dynlora-models/adapter-{i}"}
                  for i in range(1, n+1)]))' "$A"
}

# Force MANAGED mode as well as declaring the adapters. Without this, re-running
# against an already-configured service reads back the route we supplied inline
# last time rather than one the controller derived. The rule and match counts are
# identical either way, so the wait below cannot tell them apart, and the file
# quietly stops being "what kserve generates" and becomes "what we fed back in".
echo -e "${CYAN}declaring ${A} adapters and forcing a managed route${NC}"
kubectl patch llminferenceservice "$SVC" -n "$NS" --type=merge \
    -p "{\"spec\":{\"model\":{\"lora\":{\"adapters\":$(adapters_json)}},\"router\":{\"route\":{}}}}" >/dev/null

# Belt and braces: drop any inline spec left from a previous run, so the
# controller has nothing to copy and must regenerate.
kubectl patch llminferenceservice "$SVC" -n "$NS" --type=json \
    -p '[{"op":"remove","path":"/spec/router/route/http"}]' >/dev/null 2>&1 || true

# Wait for the route to actually carry every adapter. Waiting on a fixed sleep
# reads the pre-reconcile route and captures the wrong thing -- and it looks
# like a valid capture, which is worse.
echo -e "${CYAN}waiting for the route to index all ${A}${NC}"
want=$((A + 1))   # base model + one name per adapter
for _ in $(seq 60); do
    got=$(kubectl get httproute "${SVC}-kserve-route" -n "$NS" -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(0); raise SystemExit
s=set()
for r in d["spec"]["rules"]:
    for m in r.get("matches",[]):
        for h in m.get("headers",[]):
            if h.get("name","").lower()=="x-gateway-model-name": s.add(h["value"])
print(len(s))' 2>/dev/null || echo 0)
    [[ "$got" == "$want" ]] && break
    sleep 5
done
[[ "$got" == "$want" ]] || { echo -e "${YEL}route indexes ${got} names, expected ${want}${NC}" >&2; exit 1; }

# The route must be controller-owned. An inline-supplied one is not, and that is
# the failure this whole preamble exists to prevent.
owner=$(kubectl get httproute "${SVC}-kserve-route" -n "$NS" \
    -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)
[[ "$owner" == "LLMInferenceService" ]] || {
    echo -e "${YEL}route is not owned by the LLMInferenceService (owner=${owner:-none}); refusing to capture${NC}" >&2
    exit 1
}

kubectl get httproute "${SVC}-kserve-route" -n "$NS" -o json |
python3 -c '
import json, sys, yaml
d = json.load(sys.stdin)
rules = d["spec"]["rules"]
total = sum(len(r.get("matches", [])) for r in rules)
biggest = max(len(r.get("matches", [])) for r in rules)
name = d["metadata"]["name"]
err = sys.stderr
print("# Captured verbatim from %s -- do not hand-edit." % name, file=err)
print("# Regenerate with hack/capture-route.sh", file=err)
print("# %d rules, %d matches, %d in the largest rule" % (len(rules), total, biggest), file=err)
for cap, label, val in ((16, "rules", len(rules)),
                        (64, "largest rule", biggest),
                        (128, "route total", total)):
    print("#   %-14s %4d / %-4d %s" % (label, val, cap, "OVER" if val > cap else "ok"), file=err)
yaml.safe_dump({"rules": rules}, sys.stdout, sort_keys=False, default_flow_style=False)
' > "$OUT"

echo -e "${CYAN}removing spec.model.lora so the runtime starts empty${NC}"
kubectl patch llminferenceservice "$SVC" -n "$NS" --type=json \
    -p '[{"op":"remove","path":"/spec/model/lora"}]' >/dev/null 2>&1 || true

echo -e "${GREEN}wrote${NC} ${OUT}"
echo "Paste it under spec.router.route.http.spec, or apply manifests/fixture.yaml"
echo "which already carries the captured copy."
