#!/usr/bin/env bash
# Builds the proxy-wasm module used by the "wasm" profile.
#
# Everything happens in a container, so no local rust/rustup/tinygo needed.
# Runs the unit tests too - extract_model has to refuse a value truncated
# mid-quote, otherwise the streaming path would inject half a model name.
#
# Usage:
#   ./build-wasm.sh
#
# Environment:
#   RUST_IMAGE   Builder image (default: rust:1-slim)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_IMAGE="${RUST_IMAGE:-rust:1-slim}"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${YELLOW}INFO${NC}: building model_router.wasm with ${RUST_IMAGE}"
docker run --rm -v "${SCRIPT_DIR}/profiles/wasm-module:/src" -w /src "$RUST_IMAGE" sh -c '
    set -e
    rustup target add wasm32-wasip1 >/dev/null 2>&1
    cargo test --quiet
    cargo build --release --target wasm32-wasip1
'

WASM="${SCRIPT_DIR}/profiles/wasm-module/target/wasm32-wasip1/release/model_router.wasm"
echo -e "${GREEN}  OK${NC}: $(du -h "$WASM" | cut -f1) -> ${WASM#"${SCRIPT_DIR}/"}"
echo ""
echo -e "  ${BOLD}./validate.sh --docker --profile wasm --buffer 1 --size 2${NC}"
