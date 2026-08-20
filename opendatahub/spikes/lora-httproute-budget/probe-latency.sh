#!/usr/bin/env bash
# What does a long alternation regex cost at request time?
#
# The alternation shape replaces N Exact header matches with ONE RegularExpression
# listing N names. That trades a linear scan over matches for a single regex
# evaluation. Whether that is cheaper or dearer is an empirical question, and the
# answer decides whether 297 adapters is a real option or a trap.
#
# Isolating the gateway: every rule here points at the echo Deployments, not at
# the InferencePool. A real EPP adds an ext_proc round trip whose variance is far
# larger than anything we are trying to measure, and vLLM on CPU would swamp it
# entirely. What is left in the number is Envoy's own route-matching cost.
#
# Configurations are measured ROUND-ROBIN rather than one after another, so a
# laptop thermal-throttling halfway through shows up as noise in every column
# instead of a trend in one.
#
# Usage: ./probe-latency.sh [reps] [duration]
set -euo pipefail
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"

NS=lora-budget
REPS="${1:-3}"
DUR="${2:-10s}"
GW="http://kserve-ingress-gateway-istio.kserve.svc.cluster.local:80"
OUT="golden/latency.tsv"

# shape:adapters -- pathonly is the floor, current@7 is today's ceiling,
# collapse@58 is the linear-scan comparison at a count only a regex can reach.
CONFIGS=(pathonly:0 current:7 alternation:7 alternation:50 alternation:150 alternation:297 collapse:58)

render() { python3 hack/render-latency-route.py "$1" "$2"; }

# The header value that costs the most to match: the LAST alternative in the
# regex, and the LAST (path, header) pair in the linear scan.
worst_header() {  # shape adapters
    local n="$2"
    if [[ "$1" == pathonly ]]; then echo "publishers/$NS/models/model-a"
    elif [[ "$n" -eq 0 ]];    then echo "publishers/$NS/models/model-a"
    else echo "publishers/$NS/models/adapter-a$n"; fi
}

converged() {  # header -> route is live and matching
    # Same backend identification characterize.sh uses: the echo Deployments
    # report their own pod name, so "which backend" is observable.
    local got
    got=$(kubectl -n "$NS" exec fortio -- fortio curl -quiet \
            -H "X-Gateway-Model-Name: $1" "$GW/v1/messages" 2>/dev/null \
          | sed -n 's/.*"hostname": *"\(echo-[a-z]*\)-[a-z0-9]*-[a-z0-9]*".*/\1/p' | head -1) || true
    [[ "$got" == "echo-pool" ]]
}

apply_cfg() {  # shape adapters
    render "$1" "$2" | kubectl apply -f - >/dev/null
    local hdr; hdr=$(worst_header "$1" "$2")
    for _ in $(seq 1 60); do converged "$hdr" && return 0; sleep 1; done
    echo "  !! $1@$2 never converged" >&2; return 1
}

run_one() {  # shape adapters -> "qps p50 p75 p99"
    local hdr; hdr=$(worst_header "$1" "$2")
    kubectl -n "$NS" exec fortio -- fortio load -c 8 -qps 0 -t "$DUR" -json - \
        -H "X-Gateway-Model-Name: $hdr" "$GW/v1/messages" 2>/dev/null \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
pct = {int(p["Percentile"]): p["Value"] * 1000 for p in d["DurationHistogram"]["Percentiles"]}
print("%.1f\t%.3f\t%.3f\t%.3f" % (d["ActualQPS"], pct.get(50, 0), pct.get(75, 0), pct.get(99, 0)))'
}

echo "config                bytes  rep       qps     p50ms     p75ms     p99ms"
: > "$OUT.raw"
for rep in $(seq 1 "$REPS"); do
    for cfg in "${CONFIGS[@]}"; do
        shape="${cfg%%:*}"; n="${cfg##*:}"
        apply_cfg "$shape" "$n"
        bytes=$(render "$shape" "$n" | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
print(max((len(h["value"]) for r in d["spec"]["rules"] for m in r.get("matches", [])
           for h in m.get("headers", [])), default=0))')
        res=$(run_one "$shape" "$n")
        printf "%-20s %5s  %3s  %s\n" "$shape@$n" "$bytes" "$rep" "$res"
        printf "%s\t%s\t%s\t%s\n" "$shape@$n" "$bytes" "$rep" "$res" >> "$OUT.raw"
    done
done

python3 - "$OUT.raw" "$OUT" <<'PY'
import sys, collections, statistics as st
rows = collections.OrderedDict()
for ln in open(sys.argv[1]):
    f = ln.rstrip("\n").split("\t")
    rows.setdefault((f[0], f[1]), []).append([float(x) for x in f[3:]])
out = open(sys.argv[2], "w")
hdr = "config\tregex-bytes\tqps-median\tp50-median\tp75-median\tp99-median\treps"
print(hdr); out.write(hdr + "\n")
base = None
for (cfg, b), vs in rows.items():
    med = [st.median(c) for c in zip(*vs)]
    if base is None: base = med[0]
    line = "%s\t%s\t%.1f\t%.3f\t%.3f\t%.3f\t%d" % (cfg, b, med[0], med[1], med[2], med[3], len(vs))
    print(line + "\t(%+.1f%% qps vs floor)" % ((med[0] / base - 1) * 100))
    out.write(line + "\n")
out.close()
PY
echo
echo "wrote $OUT"
