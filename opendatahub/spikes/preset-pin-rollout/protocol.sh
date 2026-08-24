#!/usr/bin/env bash
# A/B/A/B: run each candidate controller against the SAME pinned preset and
# snapshot what it did to the Deployment.
#
#   round 1   BASELINE -> CANDIDATE_A
#   round 2   BASELINE -> CANDIDATE_B     (baseline re-run is the control)
#
# The second baseline round is not ceremony. It proves the harness returns the
# same numbers twice, so a difference in the candidate round means the candidate
# and not the cluster.
set -uo pipefail
: "${DOCKER_HOST:=unix:///var/run/docker.sock}"; export DOCKER_HOST

BASE=${1:?usage: protocol.sh <baseline-wt> <candidate-a-wt> <candidate-b-wt> [outdir]}
CAND_A=${2:?}
CAND_B=${3:?}
OUT=${4:-$(dirname "$0")/out}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

# go build, never go run: go run spawns the compiled binary as a child and
# leaves it holding :9443 when you kill the parent. That produced a FALSE
# "no rollout" once - the second controller never started at all.
build() { echo "  build $2"; ( cd "$1" && go build -o "$OUT/llmisvc-$2" ./cmd/llmisvc ) || exit 1; }
start() { "$OUT/llmisvc-$1" --metrics-addr=0 --health-probe-addr=0 >"$OUT/controller-$1.log" 2>&1 & echo $!; }

stop() {
  kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null
  for _ in $(seq 1 25); do ss -lnt | grep -q ':9443 ' || return 0; sleep 1; done
  echo "FATAL: :9443 still held after stop" >&2; exit 1
}

assert_live() {
  kill -0 "$1" 2>/dev/null && return 0
  echo "FATAL: controller $2 exited early" >&2; tail -20 "$OUT/controller-$2.log" >&2; exit 1
}

snap() { # label
  for _ in $(seq 1 40); do kubectl -n kvtest get deployment kvsvc-kserve >/dev/null 2>&1 && break; sleep 2; done
  sleep 6  # let the last reconcile settle before reading
  kubectl -n kvtest get deployment kvsvc-kserve -o json > "$OUT/deploy-$1.json" 2>/dev/null
  kubectl -n kvtest get replicaset      -o json > "$OUT/rs-$1.json"     2>/dev/null
}

# Deleting an LLMInferenceService with no controller running hangs forever on
# serving.kserve.io/llmisvc-finalizer, so resets run against a live controller.
reset_ns() {
  kubectl -n kvtest delete llminferenceservice --all --wait=false >/dev/null 2>&1
  for _ in $(seq 1 30); do
    kubectl -n kvtest get llminferenceservice kvsvc >/dev/null 2>&1 || break; sleep 2
  done
  kubectl -n kvtest delete deployment,replicaset --all --wait=false >/dev/null 2>&1
  sleep 3
}

round() { # baseline-label candidate-label candidate-wt
  local bl=$1 cl=$2 cwt=$3
  echo "== round: BASELINE($bl) -> $cl =="
  P=$(start BASELINE); sleep 20; assert_live "$P" BASELINE
  reset_ns
  kubectl apply -f "$HERE/svc.yaml" >/dev/null
  snap "$bl"
  stop "$P"

  P=$(start "$cl"); sleep 30; assert_live "$P" "$cl"
  snap "$cl"
  stop "$P"
}

build "$BASE" BASELINE
build "$CAND_A" "$(basename "$CAND_A")"
build "$CAND_B" "$(basename "$CAND_B")"

round BASE1 "$(basename "$CAND_A")" "$CAND_A"
round BASE2 "$(basename "$CAND_B")" "$CAND_B"

echo "== done =="
python3 "$HERE/report.py" "$OUT" BASE1 "$(basename "$CAND_A")" BASE2 "$(basename "$CAND_B")"
