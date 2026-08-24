#!/usr/bin/env bash
# Load, unload and list LoRA adapters through the gateway.
#
# Thin wrapper over four curls. The one thing it does that raw curl does not:
# UNLOAD REMOVES BOTH NAMES.
#
# vLLM's adapter table is a dict keyed by name and unload takes a single
# lora_name, so two names for one set of weights are two independent entries.
# kserve registers every SPEC-DECLARED adapter twice (workload_lora.go:166-167)
# -- the bare name and the fully qualified one -- so `unload adapter-1` returns
# 200, drops the bare entry, and leaves publishers/{ns}/models/adapter-1 loaded
# and serving. That surviving name is the only one an HTTPRoute indexes, so the
# unload breaks the name nothing routes on and leaves gateway traffic untouched.
#
# Adapters loaded here register under ONE name, so the trap does not arise --
# but unload still clears both, because the pod may also be serving
# spec-declared ones.
#
# Usage:  ./lora.sh list | load NAME | unload NAME
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"
NS="${NS:-dynamic-lora}"; SVC="${SVC:-svc-dyn}"
B="${B:-http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
    -o jsonpath='{.status.addresses[0].value}')/${NS}/${SVC}}"
Q="publishers/${NS}/models"

post() { curl -sS --max-time 60 -X POST "$B$1" -H 'Content-Type: application/json' -d "$2"; }

case "${1:-}" in
  list)
    curl -sS --max-time 20 "$B/v1/models" |
      python3 -c 'import json,sys
d=json.load(sys.stdin)
a=[m["id"] for m in d["data"] if m.get("parent")]
print("\n".join(a) if a else "(none)")' ;;
  load)
    [[ -n "${2:-}" ]] || { echo "usage: $0 load NAME" >&2; exit 2; }
    post /v1/load_lora_adapter "{\"lora_name\":\"$2\",\"lora_path\":\"/mnt/lora/$2\"}"; echo ;;
  unload)
    [[ -n "${2:-}" ]] || { echo "usage: $0 unload NAME" >&2; exit 2; }
    # both names, then confirm nothing survived
    post /v1/unload_lora_adapter "{\"lora_name\":\"$2\"}" >/dev/null || true
    post /v1/unload_lora_adapter "{\"lora_name\":\"${Q}/$2\"}" >/dev/null || true
    left=$("$0" list | grep -Fx -e "$2" -e "${Q}/$2" || true)
    [[ -z "$left" ]] && echo "removed $2 (both names)" || { echo "STILL LOADED: $left"; exit 1; } ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 2 ;;
esac
