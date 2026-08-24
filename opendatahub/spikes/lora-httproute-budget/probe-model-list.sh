#!/usr/bin/env bash
# Does /v1/models report what is actually loaded, and what happens when the
# adapter set changes underneath it?
#
# The spike has measured the ROUTE's view of the adapter set exhaustively: how
# many matches it costs, where the ceiling is, what a request matches. It has
# never asked the runtime what IT thinks it is serving. Those are two
# independent registries and nothing reconciles them:
#
#   the HTTPRoute   is an index from model name -> InferencePool, written by
#                   the kserve controller from spec.model.lora.adapters
#   vLLM            holds its own table of loaded adapters, populated from
#                   --lora-modules at startup and mutable at runtime if
#                   VLLM_ALLOW_RUNTIME_LORA_UPDATING is set
#
# So there are four quadrants, and three of them are interesting:
#
#                     | in vLLM            | not in vLLM
#   ------------------+--------------------+---------------------------------
#   in the route      | works              | route matches, runtime 404s
#   not in the route  | reachable ONLY via | 404 (the honest case)
#                     | a service-scoped   |
#                     | path; invisible on |
#                     | the shared endpoint|
#
# The bottom-left is what runtime loading creates. The top-right is the steady
# state of #279 (clearing spec.model.lora leaves the matches behind).
#
# Nothing here encodes an expectation. It records what /v1/models returns, what
# the route matches, and where the two disagree.
#
# Note on dual registration: kserve registers every adapter under TWO body-level
# names (workload_lora.go:166-167) -- the bare name and the fully qualified one:
#
#   {Name: a.name,                                        Path: a.mountPath}
#   {Name: fullyQualifiedModelName(ns, a.name),           Path: a.mountPath}
#
# Measured: the BASE is dual-registered too, via --served-model-name, so the
# cardinality is 2 x (1 + N) -- six entries for one base and two adapters. An
# operator reading /v1/models sees every model twice, which is worth knowing
# before anyone builds a UI on it.
#
# Requires the REAL backends (not the echo swap) -- this asks the runtime a
# question, so the runtime has to be in the path.
#
# Usage:
#   ./probe-model-list.sh                 # part A only: what does /v1/models list
#   ./probe-model-list.sh --churn         # + part B: add/remove via spec.model.lora
#   ./probe-model-list.sh --runtime       # + part C: vLLM load/unload endpoints
#   ./probe-model-list.sh --all
#
# Part C needs VLLM_ALLOW_RUNTIME_LORA_UPDATING=1 on the workload. The fixture
# does not set it by default, which is why the captured openapi.json has no
# /v1/load_lora_adapter -- vLLM only registers those routes when it is set.
# Run with FIXTURE_RUNTIME_LORA=1 ./setup.sh or patch the deployment first; the
# script detects the endpoint's absence and says so rather than reporting a 404
# as a finding.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"
NS="${NS:-lora-budget}"
SVC="${SVC:-svc-a}"
BASE="${BASE:-model-a}"
OUT="${SCRIPT_DIR}/golden/model-list.tsv"

# One scratch file for response bodies. $$-based names broke a --all run under
# `set -e`: the file was gone by the time it was read and the script died
# mid-probe with "No such file or directory".
TMPBODY="$(mktemp)"
trap 'rm -f "$TMPBODY"' EXIT

# Truncate before every request. Sharing one scratch file across probes meant a
# curl that never connected left the PREVIOUS probe's body in place, and the
# served-by classifier happily reported it -- a request that timed out was
# recorded as "ECHO-NEIGHBOUR", which is a completely different finding.
fresh_body() { : > "$TMPBODY"; }

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DO_CHURN=false; DO_RUNTIME=false
for a in "$@"; do
    case "$a" in
        --churn)   DO_CHURN=true ;;
        --runtime) DO_RUNTIME=true ;;
        --all)     DO_CHURN=true; DO_RUNTIME=true ;;
        *) echo "usage: $0 [--churn] [--runtime] [--all]" >&2; exit 2 ;;
    esac
done

GATEWAY_URL="${GATEWAY_URL:-http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
    -o jsonpath='{.status.addresses[0].value}')}"
QUAL="publishers/${NS}/models"

# Only a RUNNING, READY pod. Taking .items[0] blindly picks up Terminating and
# Succeeded pods during a rollout, and exec against those fails with "cannot
# exec into a container in a completed pod" -- or worse, succeeds against the
# pod that is about to die and reports the pre-change state as the new one.
pod() {
    kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SVC}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null | awk '$2=="True"{print $1; exit}'
}

# ---------------------------------------------------------------------------
# what the RUNTIME says it has loaded, straight from the pod. This is ground
# truth: no gateway, no route, no EPP in the path.
# ---------------------------------------------------------------------------
runtime_models() {
    local p; p="$(pod)"
    [[ -n "$p" ]] || { echo "no ${SVC} pod" >&2; return 1; }
    kubectl exec -n "$NS" "$p" -c main -- \
        curl -sf --max-time 10 localhost:8000/v1/models 2>/dev/null
}

# ---------------------------------------------------------------------------
# what the GATEWAY returns for /v1/models, per addressing form. The three forms
# do not necessarily reach the same place: /v1/models header-addressed goes to
# the workload Service today (it is not an inference endpoint, so the path
# family catches it), while the service-scoped and publisher paths are rewritten
# and go direct. Worth recording all three rather than assuming.
# ---------------------------------------------------------------------------
gateway_models() {  # path, header
    fresh_body
    local path="$1" header="${2:-}" args=(-sS --max-time 15 -o "$TMPBODY" -w '%{http_code}')
    [[ -n "$header" ]] && args+=(-H "X-Gateway-Model-Name: ${header}")
    local code; code=$(curl "${args[@]}" "${GATEWAY_URL}${path}" 2>/dev/null || echo 000)
    echo "$code"
    cat "$TMPBODY" 2>/dev/null
}

# Parse a /v1/models payload into "id<TAB>parent<TAB>root" lines. vLLM sets
# parent=<base model> on a LoRA entry and leaves it null on a base model, which
# is the only field that distinguishes the two.
parse_models() {
    python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception as e: print("UNPARSEABLE\t\t%s" % e); raise SystemExit
for m in d.get("data", []):
    print("\t".join([m.get("id","?"), str(m.get("parent") or "-"), str(m.get("root") or "-")]))
'
}

# What the ROUTE matches on, as a set of model names. Pulled from the live
# HTTPRoute rather than from the spec, because the two can disagree -- that
# disagreement is the whole point of #279.
#
# Scoped to THIS service's route. The namespace holds one route per service and
# a neighbour, so scanning all of them reports svc-b's model-b as "indexed but
# not served" -- true of svc-a's runtime, meaningless as a finding.
ROUTE="${ROUTE:-${SVC}-kserve-route}"
route_names() {
    kubectl get httproute "$ROUTE" -n "$NS" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
names=set()
for r in (d.get("items") or [d]):
    for rule in r.get("spec", {}).get("rules", []):
        for m in rule.get("matches", []):
            for h in m.get("headers", []):
                if h.get("name","").lower()=="x-gateway-model-name" and h.get("type")!="RegularExpression":
                    names.add(h.get("value",""))
for n in sorted(names): print(n)
'
}

hr() { printf "${CYAN}%s${NC}\n" "------------------------------------------------------------------"; }

# ===========================================================================
# Part A -- what is loaded, and what does each addressing form report
# ===========================================================================
{
  echo "# Does /v1/models report the adapters that are actually loaded?"
  echo "#"
  echo "# The HTTPRoute and the vLLM runtime are two independent registries of the"
  echo "# same adapter set, and nothing reconciles them. This records both."
  echo "#"
  echo "# kserve registers each adapter under TWO names (workload_lora.go:166-167):"
  echo "# the bare name and the fully qualified one. The base is dual-registered too,"
  echo "# via --served-model-name, so the cardinality is 2 x (1 + N)."
  echo "#"
  echo "# gateway ${GATEWAY_URL}   namespace ${NS}   service ${SVC}"
} > "$OUT"

echo -e "${BOLD}Part A: what the runtime says it is serving${NC}"
hr

RAW="$(runtime_models || true)"
if [[ -z "$RAW" ]]; then
    echo -e "${RED}could not reach vLLM /v1/models on the pod${NC}"
    exit 1
fi

echo "" >> "$OUT"
echo "# --- direct on the pod, no gateway in the path (ground truth) ---" >> "$OUT"
printf 'source\tid\tparent\troot\n' >> "$OUT"
echo "$RAW" | parse_models | while IFS=$'\t' read -r id parent root; do
    printf 'pod\t%s\t%s\t%s\n' "$id" "$parent" "$root" >> "$OUT"
    if [[ "$parent" == "-" ]]; then
        printf '  %-52s %bbase%b\n' "$id" "$CYAN" "$NC"
    else
        printf '  %-52s adapter of %s\n' "$id" "$parent"
    fi
done

N_TOTAL=$(echo "$RAW" | parse_models | wc -l)
N_ADAPT=$(echo "$RAW" | parse_models | awk -F'\t' '$2!="-"' | wc -l)
N_BASE=$((N_TOTAL - N_ADAPT))
SPEC_ADAPT=$(kubectl get llminferenceservice "$SVC" -n "$NS" \
    -o jsonpath='{.spec.model.lora.adapters[*].name}' 2>/dev/null | wc -w)

echo ""
printf '  %-30s %s\n' "entries total"          "$N_TOTAL"
printf '  %-30s %s\n' "base models"            "$N_BASE"
printf '  %-30s %s\n' "adapter entries"        "$N_ADAPT"
printf '  %-30s %s\n' "adapters in the spec"   "$SPEC_ADAPT"
EXPECT=$((SPEC_ADAPT * 2))
if [[ "$N_ADAPT" -eq "$EXPECT" ]]; then
    echo -e "  ${GREEN}dual registration confirmed: ${N_ADAPT} entries for ${SPEC_ADAPT} adapters${NC}"
else
    echo -e "  ${YEL}cardinality is ${N_ADAPT} for ${SPEC_ADAPT} adapters, expected ${EXPECT}${NC}"
fi

{
  echo ""
  echo "# entries=${N_TOTAL} base=${N_BASE} adapter-entries=${N_ADAPT} spec-adapters=${SPEC_ADAPT}"
} >> "$OUT"

# --- the same question through each addressing form -------------------------
echo ""
echo -e "${BOLD}and what each addressing form returns${NC}"
hr
{
  echo ""
  echo "# --- /v1/models through the gateway, per addressing form ---"
  printf 'form\tpath\theader\tstatus\tentries\tnote\n'
} >> "$OUT"

probe_form() {  # label, path, header, note
    local label="$1" path="$2" header="$3" note="$4"
    local res code body n
    res="$(gateway_models "$path" "$header")"
    code="$(echo "$res" | head -1)"
    body="$(echo "$res" | tail -n +2)"
    if [[ "$code" == "200" ]]; then
        n=$(echo "$body" | parse_models | wc -l)
    else
        n=0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$path" "${header:--}" "$code" "$n" "$note" >> "$OUT"
    printf '  %-14s %-46s %-4s %s entries  %s\n' "$label" "$path" "$code" "$n" "$note"
}

probe_form "service-path"   "/${NS}/${SVC}/v1/models"                 ""                    "URL names the service"
probe_form "publisher-path" "/publishers/${NS}/models/${BASE}/v1/models" ""                 "URL names the base model"
probe_form "shared+header"  "/v1/models"                              "${QUAL}/${BASE}"     "header names the model"
probe_form "shared+adapter" "/v1/models"                              "${QUAL}/adapter-a1"  "header names an adapter"
probe_form "shared+nohdr"   "/v1/models"                              ""                    "no key at all"

# --- route vs runtime -------------------------------------------------------
echo ""
echo -e "${BOLD}route vs runtime${NC}"
hr
{
  echo ""
  echo "# --- the two registries, compared ---"
  echo "# in-route: the name appears in an X-Gateway-Model-Name Exact match"
  echo "# in-vllm:  the name appears in /v1/models"
  printf 'name\tin-route\tin-vllm\tverdict\n'
} >> "$OUT"

ROUTE_NAMES="$(route_names || true)"
VLLM_NAMES="$(echo "$RAW" | parse_models | awk -F'\t' '{print $1}')"

compare_registries() {
    python3 - "$1" "$2" <<'PY'
import sys
route = set(x for x in sys.argv[1].splitlines() if x.strip())
vllm  = set(x for x in sys.argv[2].splitlines() if x.strip())
for n in sorted(route | vllm):
    r, v = n in route, n in vllm
    if r and v:      verdict = "reachable"
    elif r:          verdict = "ROUTE MATCHES, RUNTIME DOES NOT SERVE"
    else:            verdict = "served but not indexed (service-path only)"
    print("\t".join([n, "yes" if r else "no", "yes" if v else "no", verdict]))
PY
}
# compute once: the function appends to $OUT via the caller, and running it
# twice would duplicate every row in the golden file.
CMP="$(compare_registries "$ROUTE_NAMES" "$VLLM_NAMES")"
echo "$CMP" >> "$OUT"
echo "$CMP" | awk -F'\t' '{printf "  %-52s route=%-4s vllm=%-4s %s\n", $1, $2, $3, $4}'

# ===========================================================================
# Part B -- kserve-level load/unload: patch spec.model.lora.adapters
# ===========================================================================
if $DO_CHURN; then
echo ""
echo -e "${BOLD}Part B: add and remove an adapter through spec.model.lora${NC}"
hr
{
  echo ""
  echo "# --- kserve-level churn: patch spec.model.lora.adapters ---"
  echo "# Does the route follow? Does the runtime follow? Do they agree?"
  printf 'step\tspec-adapters\troute-names\tvllm-entries\tvllm-vs-spec\troute-vs-spec\n'
} >> "$OUT"

# Two separate agreements, because they diverge and that divergence is the
# finding. vLLM carries 2 entries per adapter (dual registration); the route
# indexes the base plus one name per adapter, so 1 + N. A single combined
# "agree" column hid #279 completely -- on the cleared row the runtime agreed
# with the spec at zero while the route was still advertising two adapters
# that no longer exist anywhere.
snapshot() {  # label
    local sa rn ve av ar
    sa=$(kubectl get llminferenceservice "$SVC" -n "$NS" \
        -o jsonpath='{.spec.model.lora.adapters[*].name}' 2>/dev/null | wc -w)
    rn=$(route_names | grep -c . || echo 0)
    ve=$(runtime_models 2>/dev/null | parse_models | awk -F'\t' '$2!="-"' | wc -l || echo 0)
    av=$([[ "$ve" -eq $((sa * 2)) ]] && echo yes || echo no)
    ar=$([[ "$rn" -eq $((sa + 1)) ]] && echo yes || echo no)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$sa" "$rn" "$ve" "$av" "$ar" >> "$OUT"
    printf '  %-22s spec=%-3s route-names=%-4s vllm-adapters=%-4s vllm-ok=%-4s route-ok=%s\n' \
        "$1" "$sa" "$rn" "$ve" "$av" "$ar"
}

# Waiting on `kubectl rollout status` alone is a trap here, and it silently
# produced a run where every row was identical: the controller had not yet
# reconciled, so the deployment was UNCHANGED, rollout status returned instantly,
# and runtime_models answered from the pod that was still running. The whole
# add/remove/clear sequence completed without a single restart.
#
# So wait on the two things that actually have to move, in order:
#   1. the ROUTE's header-value set changes  -> the controller has reconciled
#   2. the POD name changes and goes ready   -> the runtime has picked it up
# Both are compared against a snapshot taken before the patch.
route_fingerprint() { route_names | sort | tr '\n' ','; }
pod_fingerprint()   { pod; }

wait_reconciled() {  # old-route-fingerprint, old-pod, expect-route-change(yes|no)
    local old_route="$1" old_pod="$2" expect="$3" i

    if [[ "$expect" == "yes" ]]; then
        for i in $(seq 60); do
            [[ "$(route_fingerprint)" != "$old_route" ]] && break
            sleep 5
        done
        [[ "$(route_fingerprint)" != "$old_route" ]] || \
            echo -e "    ${YEL}route never changed after 300s${NC}" >&2
    fi

    # the workload only restarts when --lora-modules actually changes
    for i in $(seq 90); do
        local p; p="$(pod_fingerprint)"
        if [[ -n "$p" && "$p" != "$old_pod" ]]; then
            kubectl wait --for=condition=Ready "pod/$p" -n "$NS" --timeout=600s >/dev/null 2>&1 && return 0
        fi
        sleep 5
    done
    # no restart is a legitimate outcome; make sure the runtime still answers
    runtime_models >/dev/null 2>&1
}

ORIG="$(kubectl get llminferenceservice "$SVC" -n "$NS" -o json | \
        python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["spec"]["model"].get("lora",{})))')"

snapshot "before"

echo -e "  ${CYAN}adding adapter-a3${NC}"
R0="$(route_fingerprint)"; P0="$(pod_fingerprint)"
kubectl patch llminferenceservice "$SVC" -n "$NS" --type=merge -p "$(python3 -c '
import json,sys
lora=json.loads(sys.argv[1]); a=lora.setdefault("adapters",[])
if not any(x.get("name")=="adapter-a3" for x in a):
    a.append({"name":"adapter-a3","uri":"pvc://lora-budget-models/adapter-a3"})
print(json.dumps({"spec":{"model":{"lora":lora}}}))
' "$ORIG")" >/dev/null
wait_reconciled "$R0" "$P0" yes; snapshot "after add"

echo -e "  ${CYAN}removing adapter-a3${NC}"
R0="$(route_fingerprint)"; P0="$(pod_fingerprint)"
kubectl patch llminferenceservice "$SVC" -n "$NS" --type=merge \
    -p "{\"spec\":{\"model\":{\"lora\":${ORIG}}}}" >/dev/null
wait_reconciled "$R0" "$P0" yes; snapshot "after remove"

echo -e "  ${CYAN}clearing spec.model.lora entirely (#279)${NC}"
R0="$(route_fingerprint)"; P0="$(pod_fingerprint)"
kubectl patch llminferenceservice "$SVC" -n "$NS" --type=json \
    -p '[{"op":"remove","path":"/spec/model/lora"}]' >/dev/null 2>&1 || true
# #279 says the route does NOT shrink here, so do not require it to change
wait_reconciled "$R0" "$P0" no; snapshot "after clear"

echo -e "  ${CYAN}restoring${NC}"
R0="$(route_fingerprint)"; P0="$(pod_fingerprint)"
kubectl patch llminferenceservice "$SVC" -n "$NS" --type=merge \
    -p "{\"spec\":{\"model\":{\"lora\":${ORIG}}}}" >/dev/null
wait_reconciled "$R0" "$P0" no; snapshot "restored"
fi

# ===========================================================================
# Part C -- vLLM runtime load/unload
# ===========================================================================
if $DO_RUNTIME; then
echo ""
echo -e "${BOLD}Part C: vLLM runtime load / unload${NC}"
hr

P="$(pod)"
HAS_LOAD=$(kubectl exec -n "$NS" "$P" -c main -- \
    curl -sf --max-time 10 localhost:8000/openapi.json 2>/dev/null | \
    python3 -c 'import json,sys; print("yes" if "/v1/load_lora_adapter" in json.load(sys.stdin).get("paths",{}) else "no")' 2>/dev/null || echo no)

{
  echo ""
  echo "# --- vLLM runtime load/unload ---"
} >> "$OUT"

if [[ "$HAS_LOAD" != "yes" ]]; then
    echo -e "  ${YEL}/v1/load_lora_adapter is not registered on this server.${NC}"
    echo   "  vLLM only exposes it when VLLM_ALLOW_RUNTIME_LORA_UPDATING is set."
    echo   "  Patch the workload and re-run:"
    echo   ""
    echo   "    kubectl set env deploy -n ${NS} -l app.kubernetes.io/name=${SVC} \\"
    echo   "        VLLM_ALLOW_RUNTIME_LORA_UPDATING=1"
    echo   ""
    {
      echo "# NOT AVAILABLE: /v1/load_lora_adapter is unregistered."
      echo "# vLLM gates it behind VLLM_ALLOW_RUNTIME_LORA_UPDATING. The fixture does"
      echo "# not set it, which is why the captured openapi.json has 22 paths and none"
      echo "# of them is a LoRA mutation endpoint."
    } >> "$OUT"
else
    printf 'step\thttp\tvllm-entries\troute-names\tnote\n' >> "$OUT"

    rt() {  # label, method, endpoint, payload, note
        local code
        code=$(kubectl exec -n "$NS" "$P" -c main -- curl -sS --max-time 30 \
            -o /dev/null -w '%{http_code}' -X "$2" \
            -H 'Content-Type: application/json' -d "$4" \
            "localhost:8000$3" 2>/dev/null || echo 000)
        local ve rn
        ve=$(runtime_models 2>/dev/null | parse_models | awk -F'\t' '$2!="-"' | wc -l || echo 0)
        rn=$(route_names | grep -c . || echo 0)
        printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$code" "$ve" "$rn" "$5" >> "$OUT"
        printf '  %-26s http=%-4s vllm-adapters=%-4s route-names=%-4s %s\n' "$1" "$code" "$ve" "$rn" "$5"
    }

    # Load an adapter the ROUTE has never heard of. This is the bottom-left
    # quadrant: served by the runtime, absent from the index.
    rt "load ghost-adapter" POST /v1/load_lora_adapter \
       '{"lora_name":"ghost-adapter","lora_path":"/mnt/lora/adapter-a1"}' \
       "runtime knows it; route does not"

    # Can it be reached? Service-scoped path should work (URL names the service,
    # body names the adapter). Shared endpoint should NOT (no index entry).
    #
    # A status code alone is NOT enough here, and reading one cost a wrong
    # result once: the shared endpoint returned 200 and looked like a success,
    # but the 200 came from echo-neighbour's PathPrefix / catching the request
    # after no kserve rule matched. So report WHO served it, the way
    # probe-authz-split.sh does -- the echo answers with its own {path,headers}
    # shape and never carries a "model" field.
    served_by() {  # body -> a short description of who answered
        python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print(raw[:60].replace(chr(10)," ") or "-"); raise SystemExit
if "headers" in d and "path" in d and "model" not in d:
    print("ECHO-NEIGHBOUR (no kserve rule matched)")
elif "model" in d:
    print("vllm served " + str(d["model"]))
elif "error" in d or "detail" in d:
    print(str(d.get("error") or d.get("detail"))[:60])
else:
    print(raw[:60])
'
    }
    for form in "service:/${NS}/${SVC}/v1/chat/completions:" \
                "shared:/v1/chat/completions:${QUAL}/ghost-adapter"; do
        IFS=: read -r label path hdr <<<"$form"
        fresh_body
        args=(-sS --max-time 30 -o "$TMPBODY" -w '%{http_code}' -X POST
              -H 'Content-Type: application/json'
              -d '{"model":"ghost-adapter","messages":[{"role":"user","content":"hi"}],"max_tokens":1}')
        [[ -n "$hdr" ]] && args+=(-H "X-Gateway-Model-Name: ${hdr}")
        code=$(curl "${args[@]}" "${GATEWAY_URL}${path}" 2>/dev/null || echo 000)
        who=$(served_by < "$TMPBODY" 2>/dev/null || echo "-")
        printf 'reach via %s\t%s\t-\t-\t%s\n' "$label" "$code" "$who" >> "$OUT"
        printf '  %-26s http=%-4s %s\n' "reach via ${label}" "$code" "$who"
    done

    rt "unload ghost-adapter" POST /v1/unload_lora_adapter \
       '{"lora_name":"ghost-adapter"}' \
       "back to the spec's set"

    # And the inverse: unload one the ROUTE still indexes. Top-right quadrant.
    rt "unload adapter-a1" POST /v1/unload_lora_adapter \
       '{"lora_name":"adapter-a1"}' \
       "route still matches it"

    fresh_body
    code=$(curl -sS --max-time 30 -o "$TMPBODY" -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' \
        -H "X-Gateway-Model-Name: ${QUAL}/adapter-a1" \
        -d '{"model":"adapter-a1","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
        "${GATEWAY_URL}/v1/chat/completions" 2>/dev/null || echo 000)
    who=$(served_by < "$TMPBODY" 2>/dev/null || echo "-")
    printf 'reach unloaded adapter-a1\t%s\t-\t-\t%s\n' "$code" "$who" >> "$OUT"
    printf '  %-26s http=%-4s %s\n' "reach unloaded a1" "$code" "$who"

    rt "reload adapter-a1" POST /v1/load_lora_adapter \
       '{"lora_name":"adapter-a1","lora_path":"/mnt/lora/adapter-a1"}' \
       "restore"
fi
fi

echo ""
echo -e "${GREEN}recorded${NC} ${OUT}"
