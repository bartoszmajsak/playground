#!/usr/bin/env bash
# What does ONE header-regex evaluation cost, and how does it scale with pattern size?
#
# probe-latency.sh could not answer this: one evaluation against a 1.5ms request
# is far below the run-to-run noise of a kind cluster on a laptop. This amplifies
# it instead. Every configuration forces a known number of header evaluations
# (see hack/render-regex-cost.py) and lands on the same terminal rule, so the
# only difference between two columns is the work done in between.
#
# Two estimators do the de-noising:
#   * each rep ROTATES the configuration order by one. A fixed order looks like
#     interleaving but is not: warm-up or thermal drift within a rep aliases
#     straight onto config position, and whatever ran first wins. With as many
#     reps as configs, every config occupies every position exactly once.
#   * we take the MINIMUM p50 across reps, not the median. Interference can only
#     ever add time to a request, so the fastest observation is the closest one
#     to the real cost. A median just reports how busy the laptop was.
#
# Usage: ./probe-regex-cost.sh [reps] [duration]
set -euo pipefail
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"

NS=lora-budget
REPS="${1:-5}"
DUR="${2:-8s}"
GW="http://kserve-ingress-gateway-istio.kserve.svc.cluster.local:80"
OUT="golden/regex-cost.tsv"
MISS="publishers/lora-budget/models/adapter-a297x"  # diverges at the LAST byte, so RE2 scans it all

# kind:adapters:depth
CONFIGS=(
  regex:297:8    regex:297:40   regex:297:120     # depth sweep, biggest pattern
  regex:0:120    regex:50:120   regex:150:120     # size sweep, deepest scan
  exact:297:120                                   # linear Exact scan, same depth
  regex:297:0                                     # floor: terminal rule only
)

render() { python3 hack/render-regex-cost.py "$1" "$2" "$3"; }

converged() {
    local got
    got=$(kubectl -n "$NS" exec fortio -- fortio curl -quiet \
            -H "X-Gateway-Model-Name: $MISS" "$GW/v1/messages" 2>/dev/null \
          | sed -n 's/.*"hostname": *"\(echo-[a-z]*\)-[a-z0-9]*-[a-z0-9]*".*/\1/p' | head -1) || true
    [[ "$got" == "echo-service" ]]   # terminal rule, i.e. every burn rule missed
}

apply_cfg() {
    # Server-side apply: a client-side apply would store the whole object in a
    # last-applied annotation, and 120 copies of a 4KB pattern blows the 256KB
    # annotation cap long before the route itself is too big.
    render "$1" "$2" "$3" | kubectl apply --server-side --force-conflicts -f - >/dev/null
    for _ in $(seq 1 60); do converged && return 0; sleep 1; done
    echo "  !! $1/$2/$3 never converged" >&2; return 1
}

run_one() {
    kubectl -n "$NS" exec fortio -- fortio load -c 8 -qps 0 -t "$DUR" -json - \
        -H "X-Gateway-Model-Name: $MISS" "$GW/v1/messages" 2>/dev/null \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
pct = {int(p["Percentile"]): p["Value"] * 1000 for p in d["DurationHistogram"]["Percentiles"]}
print("%.1f\t%.4f\t%.4f" % (d["ActualQPS"], pct.get(50, 0), pct.get(75, 0)))'
}

echo "kind   adapters depth  bytes  rep      qps     p50ms     p75ms"
: > "$OUT.raw"
N=${#CONFIGS[@]}
for rep in $(seq 1 "$REPS"); do
    for k in $(seq 0 $((N - 1))); do
        cfg="${CONFIGS[$(( (k + rep - 1) % N ))]}"
        IFS=: read -r kind n depth <<< "$cfg"
        apply_cfg "$kind" "$n" "$depth"
        bytes=$(kubectl -n "$NS" get httproute latency-probe \
                -o jsonpath='{.metadata.annotations.spike/pattern-bytes}')
        [[ "$kind" == exact ]] && bytes=0
        res=$(run_one)
        printf "%-6s %8s %5s %6s %4s  %s\n" "$kind" "$n" "$depth" "$bytes" "$rep" "$res"
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$kind" "$n" "$depth" "$bytes" "$rep" "$res" >> "$OUT.raw"
    done
done

python3 - "$OUT.raw" "$OUT" <<'PY'
import sys, collections
rows = collections.OrderedDict()
for ln in open(sys.argv[1]):
    f = ln.rstrip("\n").split("\t")
    rows.setdefault((f[0], int(f[1]), int(f[2]), int(f[3])), []).append(float(f[6]))

best = {k: min(v) for k, v in rows.items()}          # min p50: noise only ever adds
floor = min(v for (k, n, d, b), v in best.items() if d == 0)

out = open(sys.argv[2], "w")
hdr = "kind\tadapters\tdepth\tpattern-bytes\tp50-min-ms\tover-floor-us\tper-eval-us"
print("\n" + hdr.replace("\t", "  ")); out.write(hdr + "\n")
for (kind, n, d, b), v in sorted(best.items(), key=lambda x: (x[0][0], x[0][2], x[0][3])):
    over = (v - floor) * 1000
    per = over / d if d else 0.0
    print("%-6s %8d %5d %6d %10.4f %13.1f %11.3f" % (kind, n, d, b, v, over, per))
    out.write("%s\t%d\t%d\t%d\t%.4f\t%.1f\t%.3f\n" % (kind, n, d, b, v, over, per))
out.close()
print("\nfloor (terminal rule only): %.4f ms" % floor)
PY
echo
echo "wrote $OUT"
