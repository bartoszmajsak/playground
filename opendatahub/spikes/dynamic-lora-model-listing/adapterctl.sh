#!/usr/bin/env bash
# Load and unload LoRA adapters as ONE thing with two names.
#
# THE PROBLEM THIS FIXES
#
# vLLM's adapter table is a plain dict keyed by name:
#
#   self.lora_requests[lora_name] = ...            # load
#   del self.lora_requests[lora_name]              # unload
#
# (vllm/entrypoints/openai/models/serving.py). Two names pointing at the same
# weights are two INDEPENDENT entries; vLLM has no alias concept and no
# unload-by-path.
#
# kserve, meanwhile, registers every spec-declared adapter twice --
# workload_lora.go:166-167:
#
#   {Name: a.name,                              Path: a.mountPath}
#   {Name: fullyQualifiedModelName(ns, a.name), Path: a.mountPath}
#
# so `unload adapter-a1` returns 200 Success, /v1/models drops the bare entry,
# and `publishers/{ns}/models/adapter-a1` is STILL LOADED AND STILL SERVING.
# That is the worse half: the qualified name is the only one the HTTPRoute
# indexes, so an adapter that reports as unloaded stays fully reachable through
# the gateway. Every local signal says it is gone.
#
# THE FIX AVAILABLE TODAY
#
# Treat the pair as the unit. `unload` here removes both names and reports what
# it actually removed; `load` registers both so the two addressing forms that
# work against kserve-managed services keep working here too. No kserve change,
# no vLLM change -- just correct client-side semantics over the API as it is.
#
# The real fix belongs upstream: --lora-modules should accept a list of served
# names per adapter, so unload removes the ADAPTER and every name goes with it.
# Until then, anything that unloads by a single name is half an unload.
#
# Usage:
#   ./adapterctl.sh list
#   ./adapterctl.sh load   adapter-1 [/mnt/lora/adapter-1]
#   ./adapterctl.sh unload adapter-1
#   ./adapterctl.sh reload adapter-1
#   ./adapterctl.sh verify adapter-1     # is it REALLY gone, both names?
#
# Environment: NS, SVC, LORA_ROOT

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"
NS="${NS:-dynamic-lora}"
SVC="${SVC:-svc-dyn}"
LORA_ROOT="${LORA_ROOT:-/mnt/lora}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'

qualified() { echo "publishers/${NS}/models/${1}"; }

pod() {
    kubectl get pod -n "$NS" -l "app.kubernetes.io/name=${SVC}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null | awk '$2=="True"{print $1; exit}'
}
P="$(pod)"
[[ -n "$P" ]] || { echo "no ready ${SVC} pod in ${NS}" >&2; exit 1; }

api() {  # path, json-body -> http code
    kubectl exec -n "$NS" "$P" -c main -- curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 60 -X POST -H 'Content-Type: application/json' -d "$2" \
        "localhost:8000$1" 2>/dev/null
}

models_json() {
    kubectl exec -n "$NS" "$P" -c main -- \
        curl -sf --max-time 15 localhost:8000/v1/models 2>/dev/null
}

# every id currently registered, one per line
ids() { models_json | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for m in d.get("data", []): print(m["id"])
'; }

adapter_ids() { models_json | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for m in d.get("data", []):
    if m.get("parent"): print(m["id"])
'; }

cmd_list() {
    echo -e "${CYAN}registered adapters${NC}  (pod ${P})"
    local n=0
    while read -r id; do
        [[ -z "$id" ]] && continue
        n=$((n+1))
        printf '  %s\n' "$id"
    done < <(adapter_ids)
    [[ "$n" -eq 0 ]] && echo "  (none)"
    echo "  -- ${n} entries"
}

cmd_load() {
    local name="$1" path="${2:-${LORA_ROOT}/${1}}" q
    q="$(qualified "$name")"
    local a b
    a=$(api /v1/load_lora_adapter "{\"lora_name\":\"${name}\",\"lora_path\":\"${path}\"}")
    b=$(api /v1/load_lora_adapter "{\"lora_name\":\"${q}\",\"lora_path\":\"${path}\"}")
    printf '  load %-14s bare=%s qualified=%s\n' "$name" "$a" "$b"
    # 400 means "already loaded", which is not a failure for our purposes
    [[ "$a" =~ ^(200|400)$ && "$b" =~ ^(200|400)$ ]] || return 1
}

cmd_unload() {
    local name="$1" q
    q="$(qualified "$name")"
    local a b
    a=$(api /v1/unload_lora_adapter "{\"lora_name\":\"${name}\"}")
    b=$(api /v1/unload_lora_adapter "{\"lora_name\":\"${q}\"}")
    printf '  unload %-12s bare=%s qualified=%s\n' "$name" "$a" "$b"
    cmd_verify "$name"
}

# The check the naive unload does not do: is EVERY name for this adapter gone?
cmd_verify() {
    local name="$1" q left
    q="$(qualified "$name")"
    left="$(ids | grep -Fx -e "$name" -e "$q" || true)"
    if [[ -z "$left" ]]; then
        echo -e "  ${GREEN}verified: no entry named ${name} or ${q}${NC}"
        return 0
    fi
    echo -e "  ${RED}STILL REGISTERED:${NC}"
    while read -r l; do [[ -n "$l" ]] && echo "    $l"; done <<<"$left"
    return 1
}

cmd_reload() { cmd_unload "$1" >/dev/null 2>&1 || true; cmd_load "$1" "${2:-}"; }

case "${1:-}" in
    list)   cmd_list ;;
    load)   [[ -n "${2:-}" ]] || { echo "usage: $0 load <name> [path]" >&2; exit 2; }
            cmd_load "$2" "${3:-}" ;;
    unload) [[ -n "${2:-}" ]] || { echo "usage: $0 unload <name>" >&2; exit 2; }
            cmd_unload "$2" ;;
    reload) [[ -n "${2:-}" ]] || { echo "usage: $0 reload <name> [path]" >&2; exit 2; }
            cmd_reload "$2" "${3:-}" ;;
    verify) [[ -n "${2:-}" ]] || { echo "usage: $0 verify <name>" >&2; exit 2; }
            cmd_verify "$2" ;;
    *) sed -n '/^# Usage:/,/^# Environment:/p' "$0" | sed 's/^# \?//'; exit 2 ;;
esac
