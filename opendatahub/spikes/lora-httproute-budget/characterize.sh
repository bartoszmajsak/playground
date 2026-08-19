#!/usr/bin/env bash
# Routing characterization harness.
#
# Replays probes.tsv against the gateway and records, for each request, which
# backend served it and what path that backend saw. The result is a table that
# gets frozen in golden/ and diffed on every subsequent run, so any change to
# the HTTPRoute shape shows up as a diff instead of a surprise in production.
#
# Nothing here encodes an expectation. Whatever today does IS the baseline --
# including the parts we think are wrong. Those get fixed deliberately, with
# the diff as the record of what moved.
#
# Usage:
#   ./characterize.sh                        # run, diff against golden/current.tsv
#   ./characterize.sh --update               # (re)write the golden file
#   ./characterize.sh --shape collapse       # use golden/collapse.tsv instead
#   ./characterize.sh --diff current collapse  # compare two recorded shapes
#
# Environment:
#   GATEWAY_URL   override gateway discovery (e.g. http://127.0.0.1:8080)
#   CLUSTER_NAME  kind cluster name (default: lora-budget-spike)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-lora-budget-spike}"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"

PROBES="${SCRIPT_DIR}/probes.tsv"
GOLDEN_DIR="${SCRIPT_DIR}/golden"
SHAPE="current"
UPDATE=false
DIFF_PAIR=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "  ${CYAN}INFO${NC}: $1"; }
pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC}: $1"; }
header() { echo -e "\n${BOLD}$1${NC}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)  UPDATE=true; shift ;;
        --shape)   SHAPE="$2"; shift 2 ;;
        --diff)    DIFF_PAIR="$2:$3"; shift 3 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# --diff is offline: just compare two files we already recorded.
if [[ -n "$DIFF_PAIR" ]]; then
    a="${GOLDEN_DIR}/${DIFF_PAIR%%:*}.tsv"
    b="${GOLDEN_DIR}/${DIFF_PAIR##*:}.tsv"
    [[ -f "$a" && -f "$b" ]] || { echo "missing: $a or $b" >&2; exit 1; }
    header "Shape diff: $(basename "$a" .tsv) -> $(basename "$b" .tsv)"
    diff -u "$a" "$b" && pass "identical" || true
    exit 0
fi

# ---------------------------------------------------------------------------
# Gateway discovery
# ---------------------------------------------------------------------------

discover_gateway() {
    [[ -n "${GATEWAY_URL:-}" ]] && return

    local addr
    addr=$(kubectl get gateway -A \
        -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || true)

    if [[ -z "$addr" ]]; then
        echo "could not discover a Gateway address; set GATEWAY_URL" >&2
        exit 1
    fi
    GATEWAY_URL="http://${addr}"
    info "gateway: ${GATEWAY_URL}"
}

# ---------------------------------------------------------------------------
# One probe -> one row
#
# Backends are plain echo Deployments (echo-pool / echo-service /
# echo-neighbour) substituted for the real backendRefs, so "which backend"
# is directly observable instead of being inferred from EPP side effects.
# mendhak/http-https-echo reports the path it received and its own hostname.
# ---------------------------------------------------------------------------

probe() {
    local method="$1" path="$2" hdr="$3"
    local body status backend recv

    body=$(mktemp)
    local -a curl_args=(
        -s -o "$body" -w '%{http_code}'
        -X "$method"
        --max-time 10
        -H 'Content-Type: application/json'
    )
    [[ "$hdr" != "-" ]] && curl_args+=(-H "X-Gateway-Model-Name: ${hdr}")
    [[ "$method" == "POST" ]] && curl_args+=(-d '{"model":"probe","messages":[]}')

    status=$(curl "${curl_args[@]}" "${GATEWAY_URL}${path}" 2>/dev/null || echo "000")

    if jq -e . "$body" >/dev/null 2>&1; then
        backend=$(jq -r '.os.hostname // "-"' "$body" | sed 's/-[a-z0-9]*-[a-z0-9]*$//')
        recv=$(jq -r '.path // "-"' "$body")
    else
        backend="-"
        recv="-"
    fi
    rm -f "$body"

    printf '%-10s %-6s %-62s %-58s %-6s %-16s %s\n' \
        "$FAMILY" "$method" "$path" "$hdr" "$status" "$backend" "$recv"
}

# ---------------------------------------------------------------------------
# Replay
# ---------------------------------------------------------------------------

discover_gateway

# The swapped routes are copies; the controller still owns the originals and will
# recreate them, at which point two routes compete for the same matches and the
# recorded backend depends on which one Istio programmed last. Tier 2 does not
# need the controller at all.
if [[ "$(kubectl get deploy llmisvc-controller-manager -n kserve \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)" != "0" ]]; then
    warn "llmisvc controller is running -- it will recreate the original routes"
    warn "scale it down first: kubectl scale deploy/llmisvc-controller-manager -n kserve --replicas=0"
fi

OUT=$(mktemp)
{
    printf '# recorded shape: %s\n' "$SHAPE"
    printf '%-10s %-6s %-62s %-58s %-6s %-16s %s\n' \
        '#family' 'method' 'path' 'header' 'status' 'backend' 'received-path'
} >"$OUT"

count=0
while read -r FAMILY method path hdr; do
    [[ -z "${FAMILY:-}" || "$FAMILY" == \#* ]] && continue
    probe "$method" "$path" "$hdr" >>"$OUT"
    count=$((count + 1))
done < <(sed 's/#.*$//' "$PROBES" | grep -v '^[[:space:]]*$')

info "replayed ${count} probes"

GOLDEN="${GOLDEN_DIR}/${SHAPE}.tsv"

if [[ "$UPDATE" == true || ! -f "$GOLDEN" ]]; then
    mkdir -p "$GOLDEN_DIR"
    mv "$OUT" "$GOLDEN"
    header "Baseline written: golden/${SHAPE}.tsv"
    warn "review it by hand -- it is now the definition of 'no regression'"
    exit 0
fi

header "Characterization: ${SHAPE}"
if diff -u "$GOLDEN" "$OUT"; then
    pass "routing unchanged (${count} probes)"
    rm -f "$OUT"
    exit 0
else
    fail "routing changed -- review each line above"
    echo
    info "intentional? re-run with --update to move the baseline"
    mv "$OUT" "${GOLDEN_DIR}/${SHAPE}.observed.tsv"
    info "observed run kept at golden/${SHAPE}.observed.tsv"
    exit 1
fi
