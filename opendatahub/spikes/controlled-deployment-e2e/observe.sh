#!/usr/bin/env bash
# Controlled Deployment Observability Spike
#
# Explores per-version metrics, traces, and headers from a running deployment.
# Run after validate.sh (with both v1 and v2 deployed).
#
# Requires: Prometheus, Jaeger (deployed by setup.sh kind-istio)
#
# Usage:
#   ./observe.sh [GATEWAY_URL]

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-controlled-deployment}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-${CLUSTER_NAME}.config}"

NS="controlled-deployment-spike"
V1="tiny-llama-v1"
V2="tiny-llama-v2"
MODEL="tiny-llama"
REQUESTS="${REQUESTS:-30}"

GATEWAY_URL="${1:-}"
GATEWAY_NAME="kserve-ingress-gateway"
GATEWAY_NS="${GATEWAY_NS:-}"

if [[ -z "$GATEWAY_URL" ]]; then
    if [[ -z "$GATEWAY_NS" ]]; then
        if kubectl get gateway "$GATEWAY_NAME" -n openshift-ingress >/dev/null 2>&1; then
            GATEWAY_NS="openshift-ingress"
        else
            GATEWAY_NS="kserve"
        fi
    fi
    gw_addr=$(kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [[ -n "$gw_addr" ]]; then
        GATEWAY_URL="http://$gw_addr"
    else
        echo "No gateway address found. Pass URL or use port-forward."
        exit 1
    fi
fi

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

section() { echo -e "\n${BOLD}=== $1 ===${NC}"; }
info()    { echo -e "  ${CYAN}$1${NC}"; }
finding() { echo -e "  ${GREEN}FINDING${NC}: $1"; }
gap()     { echo -e "  ${YELLOW}GAP${NC}: $1"; }

# Port-forward helper: starts in background, returns PID, cleans up on exit
PF_PIDS=()
cleanup() { for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

port_forward() {
    local ns="$1" svc="$2" local_port="$3" remote_port="$4"
    kubectl port-forward -n "$ns" "svc/$svc" "${local_port}:${remote_port}" >/dev/null 2>&1 &
    PF_PIDS+=("$!")
    for _ in 1 2 3 4 5; do
        curl -s -o /dev/null --max-time 1 "http://localhost:${local_port}" 2>/dev/null && return 0
        sleep 1
    done
}

prom_query() {
    local query="$1"
    local result
    result=$(curl -sf --max-time 5 "http://localhost:19090/api/v1/query" --data-urlencode "query=$query" 2>/dev/null) || {
        gap "Prometheus query failed (is port-forward alive?)"
        echo '{"data":{"result":[]}}'
        return
    }
    printf '%s' "$result"
}

# -------------------------------------------------------------------------
# Preflight
# -------------------------------------------------------------------------

echo -e "${BOLD}Controlled Deployment - Observability Spike${NC}"
echo "Gateway: $GATEWAY_URL"
echo "Namespace: $NS"
echo ""

v1_ready=$(kubectl get llmisvc "$V1" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
v2_ready=$(kubectl get llmisvc "$V2" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$v1_ready" != "True" || "$v2_ready" != "True" ]]; then
    echo "Both $V1 and $V2 must be Ready. Current: v1=$v1_ready v2=$v2_ready"
    exit 1
fi

has_prometheus="false"
PROM_NS=""
PROM_SVC=""
if kubectl get svc prometheus-operated -n openshift-user-workload-monitoring >/dev/null 2>&1; then
    has_prometheus="true"; PROM_NS="openshift-user-workload-monitoring"; PROM_SVC="prometheus-operated"
elif kubectl get svc prometheus-kube-prometheus-prometheus -n monitoring >/dev/null 2>&1; then
    has_prometheus="true"; PROM_NS="monitoring"; PROM_SVC="prometheus-operated"
fi
has_jaeger="false"
kubectl get svc jaeger -n observability >/dev/null 2>&1 && has_jaeger="true"

# -------------------------------------------------------------------------
# Generate traffic
# -------------------------------------------------------------------------

section "Generating traffic ($REQUESTS requests)"

v1_w=$(kubectl get llmisvc "$V1" -n "$NS" -o jsonpath='{.spec.router.route.weight}')
v2_w=$(kubectl get llmisvc "$V2" -n "$NS" -o jsonpath='{.spec.router.route.weight}')
info "Weights: $V1=$v1_w $V2=$v2_w"

v1_count=0 v2_count=0 err_count=0
for _ in $(seq 1 "$REQUESTS"); do
    tmpfile=$(mktemp)
    if curl -s -D "$tmpfile" --max-time 10 -X POST \
        "$GATEWAY_URL/v1/completions" \
        -H "Content-Type: application/json" \
        -H "X-Gateway-Model-Name: publishers/$NS/models/$MODEL" \
        -d '{"model":"'"$MODEL"'","prompt":"Hello","max_tokens":5}' >/dev/null 2>&1; then
        sb=$(grep -i "x-served-by" "$tmpfile" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)
        case "$sb" in
            *"$V1"*) v1_count=$((v1_count + 1)) ;;
            *"$V2"*) v2_count=$((v2_count + 1)) ;;
        esac
    else
        err_count=$((err_count + 1))
    fi
    rm -f "$tmpfile"
done

total=$((v1_count + v2_count))
if [[ $total -gt 0 ]]; then
    info "x-served-by distribution: $V1=$v1_count ($((v1_count * 100 / total))%) $V2=$v2_count ($((v2_count * 100 / total))%) errors=$err_count"
    finding "x-served-by header provides per-request version attribution"
else
    gap "No successful responses (errors=$err_count)"
fi

# -------------------------------------------------------------------------
# Prometheus metrics
# -------------------------------------------------------------------------

if [[ "$has_prometheus" == "true" ]]; then
    section "Prometheus Metrics"
    port_forward "$PROM_NS" "$PROM_SVC" 19090 9090

    info "Waiting for scrape cycle..."
    sleep 10

    echo ""
    info "vLLM metrics (llm_isvc_name relabeling):"
    prom_query 'vllm:request_success_total{namespace="'"$NS"'"}' | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('data',{}).get('result',[]):
    m = r['metric']
    if m.get('finished_reason') == 'length':
        print(f'    llm_isvc_name={m.get(\"llm_isvc_name\",\"<missing>\")} model={m.get(\"model_name\",\"?\")} requests={r[\"value\"][1]}')
" 2>/dev/null || gap "No vLLM metrics (PodMonitor not configured?)"

    echo ""
    info "EPP scheduler pool metrics (llm_d_epp):"
    prom_query 'llm_d_epp_info{namespace="'"$NS"'"}' | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('data',{}).get('result',[]):
    m = r['metric']
    print(f'    job={m.get(\"job\",\"?\")} build={m.get(\"build_ref\",\"?\")}')
" 2>/dev/null || gap "No EPP info metric"

    prom_query '{__name__=~"llm_d_epp.*",namespace="'"$NS"'"}' | python3 -c "
import json,sys
d=json.load(sys.stdin)
names = set()
for r in d.get('data',{}).get('result',[]):
    names.add(r['metric']['__name__'])
print(f'    Total llm_d_epp metrics: {len(names)}')
for n in sorted(names):
    print(f'      {n}')
" 2>/dev/null

    echo ""
    if prom_query 'istio_requests_total{source_workload="kserve-ingress-gateway-istio"}' | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('data',{}).get('result') else 1)" 2>/dev/null; then
        info "Istio gateway metrics (per-version request counts + effective split):"
        prom_query 'sum by (destination_canonical_service) (istio_requests_total{source_workload="kserve-ingress-gateway-istio",response_code="200",destination_service_namespace="'"$NS"'"})' | python3 -c "
import json,sys
d=json.load(sys.stdin)
results = d.get('data',{}).get('result',[])
counts = {}
for r in results:
    svc = r['metric'].get('destination_canonical_service','?')
    counts[svc] = float(r['value'][1])
total = sum(counts.values())
for svc in sorted(counts):
    pct = counts[svc] / total * 100 if total > 0 else 0
    print(f'    {svc} = {int(counts[svc])} requests ({pct:.1f}%)')
if total > 0:
    print(f'    Total: {int(total)} requests')
" 2>/dev/null || gap "No Istio gateway metrics"
    else
        info "Istio gateway metrics: not available (non-Istio gateway)"
    fi

    echo ""
    info "Traffic split: configured vs effective:"
    configured_total=$((v1_w + v2_w))
    if [[ $configured_total -gt 0 ]]; then
        info "  Configured weights: $V1=$((v1_w * 100 / configured_total))% $V2=$((v2_w * 100 / configured_total))%"
    fi
    if [[ $total -gt 0 ]]; then
        info "  Measured (x-served-by, $total reqs): $V1=$((v1_count * 100 / total))% $V2=$((v2_count * 100 / total))%"
    fi

    echo ""
    finding "Prometheus provides per-version metrics via three channels"
else
    section "Prometheus Metrics"
    gap "Prometheus not deployed (run setup.sh kind-istio to include it)"
fi

# -------------------------------------------------------------------------
# Distributed tracing
# -------------------------------------------------------------------------

if [[ "$has_jaeger" == "true" ]]; then
    section "Distributed Tracing (Jaeger)"
    port_forward observability jaeger 16686 16686

    services=$(curl -s localhost:16686/api/services 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
svcs = [s for s in d.get('data',[]) if s != 'jaeger']
print(' '.join(svcs))
" 2>/dev/null)

    if [[ -n "$services" ]]; then
        info "Services in Jaeger: $services"

        for svc in $services; do
            curl -s "localhost:16686/api/traces?service=$svc&limit=1" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d.get('data',[]):
    processes = t.get('processes',{})
    for pid, proc in processes.items():
        for tag in proc.get('tags',[]):
            if tag.get('key') == 'llmisvc.name':
                print(f'    service=$svc llmisvc.name={tag[\"value\"]} spans={len(t[\"spans\"])}')
" 2>/dev/null
        done

        finding "Traces carry llmisvc.name for per-version attribution"
    else
        gap "No services in Jaeger (spec.tracing not configured on LLMISVCs?)"
    fi
else
    section "Distributed Tracing"
    gap "Jaeger not deployed (run setup.sh kind-istio to include it)"
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------

section "Summary"
echo ""
echo "  Per-version observability channels:"
echo "    1. x-served-by header        - per-request, client-side"
echo "    2. Istio gateway metrics      - native destination_canonical_service label"
echo "    3. vLLM metrics (PodMonitor)  - llm_isvc_name via relabeling"
echo "    4. EPP pool metrics (SM)      - job label = EPP service name"
echo "    5. OTEL traces (Jaeger)       - llmisvc.name resource attribute"
echo ""
echo "  Remaining gap:"
echo "    EPP request-level metrics carry model_name (same for both versions)"
echo "    Fix: add inference_pool label in llm-d-router (Todoist 6gwCWx)"
echo ""
echo "  See docs/observability-findings.md for PromQL examples and details."
