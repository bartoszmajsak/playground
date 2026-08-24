#!/usr/bin/env bash
# Build the llmisvc controller image from a KServe checkout and record a build
# manifest that setup.sh verifies before deploying. Building is deliberately
# separate from cluster lifecycle so focused reruns can reuse an unchanged
# image.
#
# Usage:
#   ./build.sh [path-to-kserve-checkout]
#
# Environment:
#   KSERVE_SRC     overrides the checkout (same as the positional argument)
#   LLMISVC_IMAGE  skip the build entirely and record this pre-built image;
#                  its digest and provenance are still captured.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

DEFAULT_SRC="/home/bartek/code/work/model-serving/kserve/kserve/main"
KSERVE_SRC="${1:-${KSERVE_SRC:-$DEFAULT_SRC}}"

require_bins docker python3 git make
mkdir -p "$ARTIFACTS_ROOT"

[[ -f "${KSERVE_SRC}/llmisvc-controller.Dockerfile" && -f "${KSERVE_SRC}/Makefile" ]] \
    || die "${KSERVE_SRC} is not a KServe checkout (llmisvc-controller.Dockerfile missing)"

commit="$(git -C "$KSERVE_SRC" rev-parse HEAD)"
dirty=false
if [[ -n "$(git -C "$KSERVE_SRC" status --porcelain)" ]]; then dirty=true; fi

if [[ -n "${LLMISVC_IMAGE:-}" ]]; then
    image="$LLMISVC_IMAGE"
    target="(external image, build skipped)"
    info "using supplied image ${image}"
    docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null \
        || die "image ${image} not found locally and not pullable"
else
    dirty_suffix=""
    if $dirty; then dirty_suffix="-dirty"; fi
    tag="lora-e2e-${commit:0:12}${dirty_suffix}"
    image="kind.local/llmisvc-controller:${tag}"
    target="docker-build-llmisvc"
    info "building ${image} from ${KSERVE_SRC}"
    make -C "$KSERVE_SRC" docker-build-llmisvc \
        KO_DOCKER_REPO=kind.local LLMISVC_CONTROLLER_IMG=llmisvc-controller TAG="$tag" \
        || die "make docker-build-llmisvc failed"
fi

image_id="$(docker image inspect "$image" -f '{{.Id}}')"

python3 - "$ARTIFACTS_ROOT/build-manifest.json" <<PY
import json, sys, datetime
manifest = {
    "source": "${KSERVE_SRC}",
    "commit": "${commit}",
    "dirty": "${dirty}" == "true",
    "target": "${target}",
    "image": "${image}",
    "imageId": "${image_id}",
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(sys.argv[1], "w") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
print(json.dumps(manifest, indent=2))
PY

ok "build manifest written to ${ARTIFACTS_ROOT}/build-manifest.json"
