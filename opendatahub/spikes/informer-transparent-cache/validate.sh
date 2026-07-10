#!/usr/bin/env bash
# Validates that caching is transparent to the handler.
# Idempotent - seeds its own fixture, safe to run repeatedly.
set -euo pipefail

CLUSTER_NAME="informer-cache-spike"
CTX="kind-${CLUSTER_NAME}"
ADDR="http://localhost:8080"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

info()  { echo -e "\n\033[0;33m--- $1 ---\033[0m"; }
fail()  { echo -e "\033[0;31mFAIL\033[0m: $1"; exit 1; }

PIDS=()

wait_ready() {
    local addr="$1"
    for i in $(seq 1 30); do
        curl -sf "${addr}/v1/models" >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    fail "server at ${addr} not ready"
}

start_server() {
    local use_cache="${1:-false}" port="${2:-8080}"
    USE_CACHE="$use_cache" ADDR=":${port}" "$SCRIPT_DIR/server" &
    PIDS+=($!)
    wait_ready "http://localhost:${port}"
}

stop_all() {
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    PIDS=()
    for i in $(seq 1 20); do
        ss -tlnp 2>/dev/null | grep -qE ':(8080|8081) ' || break
        sleep 0.2
    done
}

cleanup() { stop_all; rm -f "$SCRIPT_DIR/server"; }
trap cleanup EXIT

go build -o "$SCRIPT_DIR/server" "$SCRIPT_DIR/main.go"

apply_model() {
    local name="$1" display="$2" provider="$3"
    kubectl --context "$CTX" apply -f - <<EOF
apiVersion: spike.example.io/v1alpha1
kind: Model
metadata:
  name: ${name}
spec:
  displayName: "${display}"
  provider: ${provider}
EOF
}

# -- Seed fixture (idempotent) --------------------------------------------
info "Seeding test fixture"
kubectl --context "$CTX" delete models --all 2>/dev/null || true
apply_model llama-3-70b      "Llama 3 70B"      meta
apply_model granite-3-8b     "Granite 3.1 8B"   ibm
apply_model gpt-4o           "GPT-4o"           openai
apply_model claude-sonnet-5  "Claude Sonnet 5"  anthropic
apply_model mistral-large    "Mistral Large"    mistral

# -- 1. Direct client (no cache) ------------------------------------------
info "Mode: direct (USE_CACHE=false)"
start_server false

echo "GET /v1/models:"
curl -sf "${ADDR}/v1/models" | jq .

stop_all

# -- 2. Cached client (informer-backed) -----------------------------------
info "Mode: cached (USE_CACHE=true)"
start_server true

echo "GET /v1/models (same handler, cached client):"
curl -sf "${ADDR}/v1/models" | jq .

# -- 3. Add a model, verify informer picks it up (server stays running) ----
info "Adding a new model"
apply_model deepseek-r1 "DeepSeek R1" deepseek
sleep 1

echo "GET /v1/models:"
RESULT=$(curl -sf "${ADDR}/v1/models")
echo "$RESULT" | jq .

echo "$RESULT" | jq -e '.models[] | select(.name == "DeepSeek R1")' >/dev/null \
    || fail "New model not found"

# -- 4. Delete a model, verify informer reflects it -----------------------
info "Deleting granite-3-8b"
kubectl --context "$CTX" delete model granite-3-8b
sleep 1

echo "GET /v1/models:"
RESULT=$(curl -sf "${ADDR}/v1/models")
echo "$RESULT" | jq .

echo "$RESULT" | jq -e '.models[] | select(.name == "Granite 3.1 8B")' >/dev/null \
    && fail "Deleted model still present"

stop_all

# -- 5. Two replicas, both stay in sync independently ---------------------
info "Two cached replicas (ports 8080 + 8081)"
start_server true 8080
start_server true 8081

echo "Both replicas see the same data:"
echo "  replica-1:" && curl -sf "http://localhost:8080/v1/models" | jq -c .
echo "  replica-2:" && curl -sf "http://localhost:8081/v1/models" | jq -c .

info "Adding 3 models while both replicas are running"
apply_model granite-3-8b  "Granite 3.1 8B"  ibm
apply_model gemma-2-27b   "Gemma 2 27B"     google
apply_model qwen-2-72b    "Qwen 2 72B"      alibaba
sleep 1

echo "Both replicas picked them up independently:"
R1=$(curl -sf "http://localhost:8080/v1/models")
R2=$(curl -sf "http://localhost:8081/v1/models")
echo "  replica-1:" && echo "$R1" | jq -c .
echo "  replica-2:" && echo "$R2" | jq -c .

for model in "Granite 3.1 8B" "Gemma 2 27B" "Qwen 2 72B"; do
    echo "$R1" | jq -e --arg m "$model" '.models[] | select(.name == $m)' >/dev/null \
        && echo "$R2" | jq -e --arg m "$model" '.models[] | select(.name == $m)' >/dev/null \
        || fail "\"${model}\" missing from a replica"
done

echo ""
