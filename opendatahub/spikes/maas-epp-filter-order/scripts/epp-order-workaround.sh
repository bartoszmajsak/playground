#!/usr/bin/env bash
# Workaround for the MaaS gateway EPP bypass on Kuadrant >= 1.5 / RHCL 1.4.
#
# One EnvoyFilter per gateway, no per-model content. It moves Istio's inert
# InferencePool filter (envoy.filters.http.ext_proc: cluster "dummy", header
# modes SKIP; the per-route override carries the real picker) from the front
# of the chain to right after MaaS's post-stage ipp:
#
#   before: ext_proc, ..., ipp-pre, wasm (Kuadrant), ipp, router
#   after:  ..., ipp-pre, wasm (Kuadrant), ipp, ext_proc, router
#
# That is the order Kuadrant <= 1.4 produced. The picker is read after ipp-pre
# has set X-Gateway-Model-Name, auth runs before the EPP, and on the response
# path the EPP filter is first, so it sees end-of-stream before its header
# reply arrives (moving ipp-pre in front of ext_proc instead leaves the EPP
# filter behind the Kuadrant wasm, which pauses on the final frame for the
# TokenRateLimitPolicy report; Envoy then ends the response with an empty
# body). The typed_config below is what Istio renders (identical on OSSM
# 1.26.8 and Istio 1.29.2); the script refuses to apply if the live one differs.
#
# Usage:
#   ./epp-order-workaround.sh status              # print the chain per listener and the verdict
#   ./epp-order-workaround.sh render              # print the EnvoyFilter
#   ./epp-order-workaround.sh apply               # preconditions, apply, wait for the new order
#   ./epp-order-workaround.sh revert              # delete the EnvoyFilter, wait for the old order
#
# Env: GATEWAY_NAME (maas-default-gateway), GATEWAY_NAMESPACE (discovered from
#      the Gateway object), KUBECTL (oc if present, else kubectl), DUMP_FILE
#      (status against a saved config_dump, no cluster access),
#      EF_NAME (payload-processing-epp-order), PRIORITY (20: after Kuadrant's
#      0 and MaaS's 10, whose filters are the anchors).
# Needs: oc/kubectl with exec on the gateway pod, jq.
set -euo pipefail

GATEWAY_NAME="${GATEWAY_NAME:-maas-default-gateway}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-}"
EF_NAME="${EF_NAME:-payload-processing-epp-order}"
PRIORITY="${PRIORITY:-20}"
KUBECTL="${KUBECTL:-$(command -v oc || command -v kubectl)}"

ISTIO_EXT_PROC="envoy.filters.http.ext_proc"
IPP_PRE="envoy.filters.http.ext_proc.ipp-pre"
IPP="envoy.filters.http.ext_proc.ipp"
ROUTER="envoy.filters.http.router"

info() { echo "INFO: $*"; }
ok()   { echo "  OK: $*"; }
err()  { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null || err "jq is required"

if [[ -z "$GATEWAY_NAMESPACE" ]]; then
    GATEWAY_NAMESPACE=$("$KUBECTL" get gateway -A -o json 2>/dev/null \
        | jq -r --arg n "$GATEWAY_NAME" '.items[] | select(.metadata.name==$n) | .metadata.namespace' | head -1)
    [[ -n "$GATEWAY_NAMESPACE" ]] || err "Gateway ${GATEWAY_NAME} not found; set GATEWAY_NAMESPACE"
fi

gateway_pod() {
    "$KUBECTL" get pods -n "$GATEWAY_NAMESPACE" \
        -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" -o json \
        | jq -r '[.items[] | select(.status.phase=="Running")
                  | select([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length > 0)]
                 | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}

config_dump() {
    local pod
    # DUMP_FILE: score a saved config_dump instead (status only), e.g. one taken
    # with `oc exec <gateway-pod> -c istio-proxy -- pilot-agent request GET config_dump`.
    if [[ -n "${DUMP_FILE:-}" ]]; then cat "$DUMP_FILE"; return; fi
    pod=$(gateway_pod)
    [[ -n "$pod" ]] || err "no Ready pod for gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}"
    "$KUBECTL" exec -n "$GATEWAY_NAMESPACE" "$pod" -c istio-proxy -- pilot-agent request GET config_dump
}

# One line per HTTP filter chain: "<listener>\t<filter names joined by space>".
chains() {
    jq -r '.configs[] | select(."@type" | endswith("ListenersConfigDump"))
           | .dynamic_listeners[]? | .name as $l
           | .active_state.listener.filter_chains[]?.filters[]?
           | select(.name=="envoy.filters.network.http_connection_manager")
           | [$l, ([.typed_config.http_filters[].name] | join(" "))] | @tsv'
}

# Verdict over every HTTP chain: ENGAGED when ipp-pre < ipp < ext_proc < router
# on all of them, BYPASSED when ext_proc sits before ipp-pre on any, else MIXED.
verdict() {
    local names l state=ENGAGED any=0
    while IFS=$'\t' read -r l names; do
        [[ -n "$names" ]] || continue
        any=1
        idx() { awk -v n="$1" '{for (i=1;i<=NF;i++) if ($i==n) {print i; exit}}' <<<"$names"; }
        local pre ipp ext rt
        pre=$(idx "$IPP_PRE"); ipp=$(idx "$IPP"); ext=$(idx "$ISTIO_EXT_PROC"); rt=$(idx "$ROUTER")
        printf '  %s\n    %s\n' "$l" "$(tr ' ' '\n' <<<"$names" | awk '{printf "[%d] %s  ", NR, $0}')"
        if [[ -z "$ext" || -z "$pre" || -z "$ipp" ]]; then
            printf '    -> missing: %s%s%s\n' "${ext:+}${ext:-ext_proc }" "${pre:+}${pre:-ipp-pre }" "${ipp:+}${ipp:-ipp }"
            state=MIXED
        elif (( pre < ipp && ipp < ext && ext < rt )); then
            printf '    -> ENGAGED (ipp-pre [%d] < ipp [%d] < ext_proc [%d] < router [%d])\n' "$pre" "$ipp" "$ext" "$rt"
        elif (( ext < pre )); then
            printf '    -> BYPASSED (ext_proc [%d] before ipp-pre [%d])\n' "$ext" "$pre"
            state=BYPASSED
        else
            printf '    -> MIXED (ipp-pre [%d], ipp [%d], ext_proc [%d], router [%d])\n' "$pre" "$ipp" "$ext" "$rt"
            state=MIXED
        fi
    done < <(chains)
    [[ $any == 1 ]] || err "no HTTP connection manager in the config dump"
    echo "$state"
}

render() {
    cat <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: ${EF_NAME}
  namespace: ${GATEWAY_NAMESPACE}
  annotations:
    maas.opendatahub.io/purpose: "workaround: Istio InferencePool ext_proc moved after ipp so the picker is read after ipp-pre and behind auth; see maas-epp-filter-order spike"
spec:
  # After Kuadrant (0) and MaaS payload-processing (10): their filters are the anchors.
  priority: ${PRIORITY}
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: ${GATEWAY_NAME}
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
              subFilter:
                name: ${ISTIO_EXT_PROC}
      patch:
        operation: REMOVE
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
              subFilter:
                name: ${IPP}
      patch:
        operation: INSERT_AFTER
        value:
          name: ${ISTIO_EXT_PROC}
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
            grpc_service:
              envoy_grpc:
                cluster_name: dummy
              timeout: 10s
            failure_mode_allow: true
            processing_mode:
              request_header_mode: SKIP
              response_header_mode: SKIP
            message_timeout: 1000s
            metadata_options:
              forwarding_namespaces:
                untyped:
                  - envoy.lb
              receiving_namespaces:
                untyped:
                  - envoy.lb
EOF
}

# The typed_config the patch re-inserts must be what Istio rendered, or the
# workaround would silently change timeouts or metadata namespaces.
check_native_config() {
    local dump="$1" live want
    live=$(jq -c --arg n "$ISTIO_EXT_PROC" \
        '[.. | objects | select(.name==$n and has("typed_config")) | .typed_config] | unique' "$dump")
    [[ "$(jq 'length' <<<"$live")" == 1 ]] || err "expected exactly one ${ISTIO_EXT_PROC} configuration in the chain, got: ${live}"
    want=$(render | python3 -c 'import sys,yaml,json; d=yaml.safe_load(sys.stdin); print(json.dumps(d["spec"]["configPatches"][1]["patch"]["value"]["typed_config"]))' 2>/dev/null \
        || render | "$KUBECTL" create --dry-run=client -f - -o json | jq -c '.spec.configPatches[1].patch.value.typed_config')
    if [[ "$(jq -cS '.[0]' <<<"$live")" != "$(jq -cS . <<<"$want")" ]]; then
        err "live ${ISTIO_EXT_PROC} typed_config differs from the one this script re-inserts; update the script from: ${live}"
    fi
}

wait_for() {
    local want="$1" timeout="${2:-120}" t=0 got
    while (( t < timeout )); do
        got=$(config_dump | verdict | tail -1)
        [[ "$got" == "$want" ]] && return 0
        sleep 5; t=$((t + 5))
    done
    return 1
}

dumpfile=$(mktemp); trap 'rm -f "$dumpfile"' EXIT

case "${1:-}" in
    status)
        config_dump > "$dumpfile"
        if [[ -n "${DUMP_FILE:-}" ]]; then info "saved dump ${DUMP_FILE}"; else info "gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}, pod $(gateway_pod)"; fi
        verdict < "$dumpfile"
        ;;
    render)
        render
        ;;
    apply)
        config_dump > "$dumpfile"
        grep -q "\"name\": \"${IPP}\"" "$dumpfile" || err "${IPP} is not in the chain: the MaaS payload-processing EnvoyFilter is not applied to this gateway, nothing to anchor on"
        grep -q "\"name\": \"${ISTIO_EXT_PROC}\"" "$dumpfile" || err "${ISTIO_EXT_PROC} is not in the chain: no InferencePool is attached to this gateway, nothing to move"
        check_native_config "$dumpfile"
        info "chain before:"; verdict < "$dumpfile" | sed '$d'
        render | "$KUBECTL" apply -f - >/dev/null
        info "applied EnvoyFilter ${GATEWAY_NAMESPACE}/${EF_NAME}; waiting for the gateway to pick it up"
        if wait_for ENGAGED 120; then
            ok "chain is ipp-pre < ipp < ${ISTIO_EXT_PROC} < router on every listener"
            config_dump | verdict | sed '$d'
        else
            config_dump | verdict
            err "chain did not reach the expected order within 120s; revert with: $0 revert"
        fi
        ;;
    revert)
        "$KUBECTL" delete envoyfilter "$EF_NAME" -n "$GATEWAY_NAMESPACE" --ignore-not-found >/dev/null
        info "deleted EnvoyFilter ${GATEWAY_NAMESPACE}/${EF_NAME}; waiting for the controller-rendered chain"
        if wait_for BYPASSED 120; then ok "back to the original (bypassed) order"; else config_dump | verdict; err "chain did not return within 120s"; fi
        ;;
    *)
        sed -n '2,30p' "$0"; exit 2 ;;
esac
