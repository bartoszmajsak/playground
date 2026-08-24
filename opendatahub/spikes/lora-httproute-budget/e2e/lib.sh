#!/usr/bin/env bash
# Shared mechanics for the LoRA routing e2e validator.
#
# Sourced by build.sh / setup.sh / validate.sh / observe.sh / cleanup.sh.
# Everything here honours the isolation contract from
# lora-routing-e2e-validator.md: a validator-owned kubeconfig inside the run
# directory, explicit --kubeconfig on every call, and a guard that refuses to
# mutate anything unless the resolved context is the expected validator-owned
# kind cluster. Exit code 2 means harness failure, 1 means product assertion
# failure, 0 means pass.

set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_ROOT="${ARTIFACT_DIR:-${E2E_DIR}/artifacts}"

# shellcheck disable=SC2034  # BOLD is used by sourcing scripts
GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  ok${NC} $*"; }
warn() { echo -e "${YEL}   !${NC} $*"; }
# Harness failure: setup/dependency problems that prevent a valid verdict.
die()  { echo -e "${RED}HARNESS FAIL${NC} $*" >&2; exit 2; }

# A stale DOCKER_HOST pointing at a dead rootless socket breaks docker and kind
# even when the rootful daemon is healthy. Fall back to the default socket.
if [[ -n "${DOCKER_HOST:-}" ]]; then
    _dh_sock="${DOCKER_HOST#unix://}"
    if [[ ! -S "$_dh_sock" && -S /var/run/docker.sock ]]; then
        unset DOCKER_HOST
    fi
fi

require_bins() {
    for bin in "$@"; do
        command -v "$bin" >/dev/null 2>&1 || die "missing required binary: ${bin}"
    done
}

# ---------------------------------------------------------------------------
# Run identity and layout
# ---------------------------------------------------------------------------
# artifacts/<run-id>/            per-run bundle (kept on failure)
#   metadata.json kubeconfig resources/ logs/ results.json requests.jsonl
# artifacts/build-manifest.json  latest controller build (consumed by setup)
# artifacts/current-run          name of the most recent run directory

new_run_id() {
    echo "$(date -u +%Y%m%dT%H%M%SZ)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

run_dir()        { echo "${ARTIFACTS_ROOT}/$1"; }
current_run_id() {
    [[ -f "${ARTIFACTS_ROOT}/current-run" ]] || die "no current run recorded; run setup.sh first"
    cat "${ARTIFACTS_ROOT}/current-run"
}

# Load a run's identity into RUN_ID / RUN_DIR / KUBECONFIG_PATH / CLUSTER_NAME.
load_run() {
    RUN_ID="${1:-$(current_run_id)}"
    RUN_DIR="$(run_dir "$RUN_ID")"
    [[ -d "$RUN_DIR" ]] || die "run directory ${RUN_DIR} does not exist"
    KUBECONFIG_PATH="${RUN_DIR}/kubeconfig"
    CLUSTER_NAME="$(meta_get "$RUN_DIR" cluster)"
    [[ -n "$CLUSTER_NAME" ]] || die "run ${RUN_ID} has no recorded cluster name"
}

# ---------------------------------------------------------------------------
# Metadata (metadata.json is built up key by key as setup progresses)
# ---------------------------------------------------------------------------
meta_set() { # meta_set <run-dir> <key> <json-value>
    local dir="$1" key="$2" value="$3" f
    f="${dir}/metadata.json"
    [[ -f "$f" ]] || echo '{}' > "$f"
    python3 - "$f" "$key" "$value" <<'PY'
import json, sys
path, key, value = sys.argv[1:4]
with open(path) as fh:
    data = json.load(fh)
try:
    data[key] = json.loads(value)
except json.JSONDecodeError:
    data[key] = value
with open(path, "w") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
PY
}

meta_get() { # meta_get <run-dir> <key>
    python3 - "$1/metadata.json" "$2" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as fh:
    v = json.load(fh).get(sys.argv[2], "")
print(v if isinstance(v, str) else json.dumps(v))
PY
}

# ---------------------------------------------------------------------------
# Guarded kubectl
# ---------------------------------------------------------------------------
# kc: kubectl bound to the validator-owned kubeconfig. Never touches the
# caller's config or context. guard_cluster must pass before any mutation.

kc() { kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"; }

guard_cluster() {
    [[ -f "$KUBECONFIG_PATH" ]] || die "validator kubeconfig ${KUBECONFIG_PATH} missing"
    local ctx
    ctx="$(kc config current-context 2>/dev/null || true)"
    [[ "$ctx" == "kind-${CLUSTER_NAME}" ]] \
        || die "kubeconfig context ${ctx:-<none>} is not the validator-owned kind-${CLUSTER_NAME}; refusing to continue"
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" \
        || die "kind cluster ${CLUSTER_NAME} does not exist"
}

gateway_url() {
    local addr
    addr="$(kc get gateway kserve-ingress-gateway -n kserve \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
    [[ -n "$addr" ]] || die "gateway kserve/kserve-ingress-gateway has no address"
    echo "http://${addr}"
}
