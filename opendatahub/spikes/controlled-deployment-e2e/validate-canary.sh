#!/usr/bin/env bash
# Zero-Downtime Canary Rollout Validation
#
# Runs continuous traffic via k6 while applying canary weight changes,
# then analyzes the output for zero-downtime violations.
#
# Usage:
#   ./validate-canary.sh                              # auto-detect, pool scenario
#   ./validate-canary.sh --scenario service           # service scenario
#   ./validate-canary.sh http://172.18.255.200        # explicit gateway
#
# Self-contained: deploys manifests if not already running.
# Requires: k6, kubectl, python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

RATE="${RATE:-2}"
SCENARIO="${SCENARIO:-pool}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)
            [[ $# -ge 2 ]] || { echo "--scenario requires a value"; exit 1; }
            SCENARIO="$2"; shift 2 ;;
        http://*|https://*) GATEWAY_URL="$1"; shift ;;
        *) echo "Unknown arg: $1. Usage: $0 [--scenario pool|service|mixed] [GATEWAY_URL]"; exit 1 ;;
    esac
done

OVERLAY_DIR="$SCRIPT_DIR/manifests/overlays/$SCENARIO"
discover_gateway
ensure_deployed "$OVERLAY_DIR"

echo -e "${BOLD}Zero-Downtime Canary Rollout Validation${NC}"
echo "Gateway: $GATEWAY_URL"
echo "Namespace: $NS"
echo "Scenario: $SCENARIO"
echo "Rate: ${RATE} req/s"
echo ""

# -------------------------------------------------------------------------
# Output files
# -------------------------------------------------------------------------

WORKDIR=$(mktemp -d)
K6_LOG="$WORKDIR/k6.log"
MUTATIONS="$WORKDIR/mutations.jsonl"
trap "echo ''; echo 'Results: $WORKDIR'" EXIT

echo "[]" > "$MUTATIONS"

record_mutation() {
    local ts action detail
    ts=$(date +%s)
    action="$1"
    detail="$2"
    echo "{\"ts\":$ts,\"action\":\"$action\",\"detail\":\"$detail\"}" >> "$MUTATIONS"
    info "[$ts] $action: $detail"
}

# -------------------------------------------------------------------------
# Start k6 in background
# -------------------------------------------------------------------------

info "Starting k6 traffic generator (${RATE} req/s for 240s)"
k6 run \
    -e "GATEWAY_URL=$GATEWAY_URL" \
    -e "NAMESPACE=$NS" \
    -e "MODEL=$MODEL" \
    -e "DURATION=240s" \
    -e "RATE=$RATE" \
    --log-output=file="$K6_LOG" \
    --quiet \
    "$SCRIPT_DIR/k6-canary-lifecycle.js" > "$WORKDIR/k6-stdout.log" 2>&1 &
K6_PID=$!

wait_and_check() {
    if ! kill -0 "$K6_PID" 2>/dev/null; then
        echo "k6 died unexpectedly. Check $WORKDIR/k6-stdout.log"
        exit 1
    fi
}

sleep 5
wait_and_check

# -------------------------------------------------------------------------
# Warmup: wait for gateway to propagate initial routing
# -------------------------------------------------------------------------

info "Warming up: waiting for both v1 and v2 to receive traffic..."
for i in $(seq 1 60); do
    resp=$(curl -s -D- --max-time 10 \
        -H "Content-Type: application/json" \
        -H "X-Gateway-Model-Name: publishers/$NS/models/$MODEL" \
        -d '{"model":"'"$MODEL"'","prompt":"Hello","max_tokens":5}' \
        "$GATEWAY_URL/v1/completions" 2>/dev/null || true)
    sb=$(echo "$resp" | grep -i "x-served-by" | awk '{print $2}' | tr -d '\r' || true)
    if [[ "$sb" == *"$V2"* ]]; then
        info "Warmup complete: v2 receiving traffic after ${i}s"
        break
    fi
    sleep 1
done

# -------------------------------------------------------------------------
# Canary lifecycle mutations
# -------------------------------------------------------------------------

info "Phase 1: Baseline (v1=9, v2=1) - 30s"
record_mutation "baseline" "v1=9 v2=1"
sleep 30
wait_and_check

info "Phase 2: Canary ramp (v1=7, v2=3) - 30s"
kubectl patch llmisvc "$V1" -n "$NS" --type merge \
    -p '{"spec":{"router":{"route":{"weight":7}}}}' >/dev/null
kubectl patch llmisvc "$V2" -n "$NS" --type merge \
    -p '{"spec":{"router":{"route":{"weight":3}}}}' >/dev/null
record_mutation "canary" "v1=7 v2=3"
sleep 30
wait_and_check

info "Phase 3: 50/50 (v1=5, v2=5) - 30s"
kubectl patch llmisvc "$V1" -n "$NS" --type merge \
    -p '{"spec":{"router":{"route":{"weight":5}}}}' >/dev/null
kubectl patch llmisvc "$V2" -n "$NS" --type merge \
    -p '{"spec":{"router":{"route":{"weight":5}}}}' >/dev/null
record_mutation "split" "v1=5 v2=5"
sleep 30
wait_and_check

info "Phase 4: Promote v2 (v1=0, v2=9) - 30s"
kubectl patch llmisvc "$V1" -n "$NS" --type merge \
    -p '{"spec":{"router":{"route":{"weight":0}}}}' >/dev/null
kubectl patch llmisvc "$V2" -n "$NS" --type merge \
    -p '{"spec":{"router":{"route":{"weight":9}}}}' >/dev/null
record_mutation "promote" "v1=0 v2=9"
sleep 30
wait_and_check

info "Phase 5: Force-stop v1 - 30s"
kubectl annotate llmisvc "$V1" -n "$NS" serving.kserve.io/stop=true --overwrite >/dev/null
record_mutation "force-stop" "v1 stopped"
sleep 30
wait_and_check

info "Phase 6: Decommission v1 - 30s"
kubectl delete llmisvc "$V1" -n "$NS" --wait=false >/dev/null 2>&1 || true
record_mutation "decommission" "v1 deleted"
sleep 30

# -------------------------------------------------------------------------
# Wait for k6 to finish
# -------------------------------------------------------------------------

info "Waiting for k6 to finish..."
wait "$K6_PID" || true

# -------------------------------------------------------------------------
# Analysis
# -------------------------------------------------------------------------

echo ""
echo -e "${BOLD}Analysis${NC}"
echo ""

python3 - "$K6_LOG" "$MUTATIONS" <<'PYEOF'
import sys, json, re

log_file = sys.argv[1]
mutations_file = sys.argv[2]

entries = []
with open(log_file) as f:
    for line in f:
        m = re.search(r'ts=(\d+)\s+served_by=(\S+)\s+status=(\d+)\s+latency=(\d+)ms', line)
        if m:
            entries.append({
                "ts": int(m.group(1)) // 1000,
                "served_by": m.group(2),
                "status": int(m.group(3)),
                "latency": int(m.group(4)),
            })

if not entries:
    print("  No traffic data found in k6 log")
    sys.exit(1)

mutations = []
with open(mutations_file) as f:
    for line in f:
        line = line.strip()
        if line and line != "[]":
            mutations.append(json.loads(line))

mutations.sort(key=lambda x: x["ts"])

first_mutation_ts = mutations[0]["ts"] if mutations else 0
entries = [e for e in entries if e["ts"] >= first_mutation_ts]

print(f"  Total requests: {len(entries)} (after baseline)")
errors = [e for e in entries if e["status"] != 200]
print(f"  Errors: {len(errors)} ({len(errors)*100//max(len(entries),1)}%)")
if errors:
    for e in errors[:5]:
        print(f"    status={e['status']} ts={e['ts']} served_by={e['served_by']}")

EXPECTATIONS = {
    "baseline":      {"v1": (75, 98),  "v2": (2, 25)},
    "canary":        {"v1": (50, 85),  "v2": (15, 50)},
    "split":         {"v1": (30, 70),  "v2": (30, 70)},
    "promote":       {"v1": (0, 5),    "v2": (95, 100)},
    "force-stop":    {"v1": (0, 5),    "v2": (95, 100)},
    "decommission":  {"v1": (0, 5),    "v2": (95, 100)},
}

windows = []
for i, mut in enumerate(mutations):
    start = mut["ts"]
    end = mutations[i+1]["ts"] if i+1 < len(mutations) else entries[-1]["ts"] + 1
    windows.append({"start": start, "end": end, "action": mut["action"], "detail": mut["detail"]})

# --- Propagation delay ---
print("")
print("  Gateway propagation delay:")
for w in windows:
    action = w["action"]
    expect = EXPECTATIONS.get(action, {})
    if not expect or expect["v2"][0] == 0:
        continue

    first_v2 = None
    for e in entries:
        if e["ts"] >= w["start"] and "v2" in e["served_by"]:
            first_v2 = e["ts"]
            break
    if first_v2 is not None:
        delay = first_v2 - w["start"]
        print(f"    {action:15s} | v2 first seen after {delay}s")
    else:
        print(f"    {action:15s} | v2 never received traffic")

# --- Per-phase distribution ---
print("")
print("  Per-phase distribution:")
all_pass = True
for w in windows:
    action = w["action"]
    expect = EXPECTATIONS.get(action, {})

    mid = w["start"] + (w["end"] - w["start"]) // 2
    phase_entries = [e for e in entries if mid <= e["ts"] < w["end"]]
    if not phase_entries:
        print(f"    {action:15s} | no data (window too short)")
        continue

    v1 = sum(1 for e in phase_entries if "v1" in e["served_by"])
    v2 = sum(1 for e in phase_entries if "v2" in e["served_by"])
    errs = sum(1 for e in phase_entries if e["status"] != 200)
    total = len(phase_entries)
    v1_pct = v1 * 100 // max(total, 1)
    v2_pct = v2 * 100 // max(total, 1)

    issues = []
    if errs > 0:
        issues.append(f"errors={errs}")
    if expect:
        v1_lo, v1_hi = expect["v1"]
        v2_lo, v2_hi = expect["v2"]
        if not (v1_lo <= v1_pct <= v1_hi):
            issues.append(f"v1={v1_pct}% outside [{v1_lo}-{v1_hi}%]")
        if not (v2_lo <= v2_pct <= v2_hi):
            issues.append(f"v2={v2_pct}% outside [{v2_lo}-{v2_hi}%]")

    if issues:
        status = "FAIL: " + ", ".join(issues)
        all_pass = False
    else:
        status = "OK"

    print(f"    {action:15s} | v1={v1_pct:3d}% v2={v2_pct:3d}% | n={total:3d} errors={errs} | {status}")

# --- Transition zero-downtime check ---
print("")
print("  Transition windows (errors during mutation):")
transition_errors = 0
for mut in mutations:
    grace_entries = [e for e in entries if mut["ts"] <= e["ts"] < mut["ts"] + 10]
    errs = sum(1 for e in grace_entries if e["status"] != 200)
    transition_errors += errs
    status = "CLEAN" if errs == 0 else f"ERRORS({errs})"
    print(f"    {mut['action']:15s} | requests={len(grace_entries):3d} errors={errs} | {status}")

# --- Verdict ---
print("")
if len(errors) == 0 and all_pass:
    print("  \033[0;32mZERO DOWNTIME: no errors, all phases match expected distribution\033[0m")
elif len(errors) == 0 and not all_pass:
    print("  \033[0;33mZERO DOWNTIME but distribution mismatch in some phases\033[0m")
elif transition_errors > 0:
    print(f"  \033[0;31mDOWNTIME DETECTED: {transition_errors} errors during transitions\033[0m")
else:
    print(f"  \033[0;33m{len(errors)} errors outside transition windows\033[0m")
PYEOF

echo ""
echo "Raw data: $WORKDIR"
