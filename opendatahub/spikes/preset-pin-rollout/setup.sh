#!/usr/bin/env bash
# kind + the llmisvc CRDs and presets, installed from ONE worktree - the
# "pinned baseline". Everything after this swaps only the controller binary,
# which is the whole point: we are asking what a controller upgrade does to a
# workload whose preset did not move.
set -euo pipefail
CLUSTER=${CLUSTER:-kvrollout}
BASE_WT=${1:?usage: setup.sh <baseline-worktree>}
: "${DOCKER_HOST:=unix:///var/run/docker.sock}"; export DOCKER_HOST

info() { echo -e "\033[33mINFO\033[0m: $*"; }

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  info "cluster $CLUSTER exists"
else
  info "creating kind cluster $CLUSTER"
  kind create cluster --name "$CLUSTER" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

info "CRDs (from pinned baseline: $BASE_WT)"
kubectl apply --server-side=true --force-conflicts -k "$BASE_WT/config/crd/full/llmisvc"
kubectl wait --for=condition=established --timeout=90s \
  crd/llminferenceservices.serving.kserve.io crd/llminferenceserviceconfigs.serving.kserve.io

kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$BASE_WT/config/configmap/inferenceservice.yaml"

info "PINNED presets (from $BASE_WT) - never re-applied after this point"
kubectl apply --server-side=true --force-conflicts -k "$BASE_WT/config/llmisvcconfig"

info "webhook certs (controller runs out-of-cluster)"
CERTDIR=/tmp/k8s-webhook-server/serving-certs
mkdir -p "$CERTDIR"
[ -f "$CERTDIR/tls.crt" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$CERTDIR/tls.key" -out "$CERTDIR/tls.crt" -subj "/CN=localhost" 2>/dev/null

kubectl create namespace kvtest --dry-run=client -o yaml | kubectl apply -f -
info "ready"
