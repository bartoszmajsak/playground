#!/usr/bin/env bash
# Do the Istio-only findings hold on a second data plane?
#
# Everything this spike concluded about regexes was measured on Istio, and the
# alternation recommendation rests on one assumption that Gateway API does NOT
# specify: that a RegularExpression header match is a FULL match. If a data plane
# matches partially instead, then a pattern listing `adapter-a1` also matches
# `evil-prefix/adapter-a1/anything`, and the shape stops being an optimisation
# and becomes a way to route another tenant's traffic into your pool.
#
# So this installs kgateway and Envoy Gateway beside Istio - separate
# GatewayClasses, separate Gateways, same cluster - and replays the anchoring
# probes against all three.
#
# Gotcha worth knowing: installing a controller that brings NEW CRD groups (Envoy
# Gateway adds gateway.networking.x-k8s.io) leaves already-running controllers
# with stale informers, and kgateway silently stops attaching routes -
# status.parents goes empty with nothing logged. Restart the other controllers
# after adding one: kubectl -n kgateway-system rollout restart deploy/kgateway
#
# What it checks, in order of how much it would hurt to be wrong about:
#   1. header regex anchoring        full match or partial?
#   2. alternation ceiling           does 4096 bytes still apply, does it program?
#   3. nested prefix anchoring       does model-a(/.*)? capture model-a-instruct?
#   4. RE2 program size              is 32768 an Istio setting or an Envoy one?
#
# Usage: ./probe-dataplane.sh [install|probe|both]
set -euo pipefail
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"

NS=lora-budget
KGW_VERSION="${KGW_VERSION:-v2.1.1}"
MODE="${1:-both}"
OUT="golden/dataplane.tsv"

info() { printf '\033[1m==>\033[0m %s\n' "$*"; }

install_kgateway() {
    info "installing kgateway $KGW_VERSION beside Istio"
    helm upgrade -i --create-namespace --namespace kgateway-system \
        --version "$KGW_VERSION" kgateway-crds \
        oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds --wait
    helm upgrade -i --namespace kgateway-system \
        --version "$KGW_VERSION" kgateway \
        oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
        --set inferenceExtension.enabled=true --wait
    kubectl wait --timeout=180s -n kgateway-system deployment --all \
        --for=condition=Available
    kubectl get gatewayclass
}

# A second Gateway on the kgateway class, and a route carrying exactly the
# patterns the Istio run used, pointed at the echo backends so "which backend"
# stays observable.
apply_fixture() {
    info "creating kgateway Gateway + probe route"
    kubectl apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kgw
  namespace: $NS
spec:
  gatewayClassName: kgateway
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
YAML
    kubectl wait --timeout=180s -n "$NS" gateway/kgw --for=condition=Programmed \
        || echo "  !! kgw gateway not Programmed"
    for gw in istio kgw eg; do python3 hack/render-anchoring-route.py "$gw" | kubectl apply -f -; done
}

# A control plane that is not Ready cannot have programmed anything, so say so
# rather than reporting its stale config as a result.
healthy() {
    case "$1" in
      istio) kubectl -n istio-system get deploy istiod -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^[1-9]' ;;
      kgw)   kubectl -n kgateway-system get deploy kgateway -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^[1-9]' ;;
      eg)    kubectl -n envoy-gateway-system get deploy envoy-gateway -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^[1-9]' ;;
    esac
}

addr_of() {  # gateway -> host:port reachable from the fortio pod
    case "$1" in
      istio) echo "kserve-ingress-gateway-istio.kserve.svc.cluster.local:80" ;;
      kgw)   echo "kgw.$NS.svc.cluster.local:80" ;;
      # Envoy Gateway names the proxy Service after the Gateway, with a hash
      # suffix, so ask the cluster rather than guessing it.
      eg)    echo "$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=eg \
                     -o jsonpath='{.items[0].metadata.name}' </dev/null).envoy-gateway-system.svc.cluster.local:80" ;;
    esac
}

hit() {  # gateway, header-value -> backend name, or "" if it did not answer
    # </dev/null matters: kubectl exec reads stdin, and without it the first
    # probe swallows the whole heredoc the caller is looping over.
    #
    # The || true is not laziness. With four Gateway API controllers stacked on
    # one node, one control plane being unhealthy should degrade its column to
    # "none" rather than abort the whole run under set -e and lose the other two.
    { kubectl -n "$NS" exec fortio -- fortio curl -quiet \
        -H "X-Gateway-Model-Name: $2" "http://$(addr_of "$1")/anchor/messages" </dev/null 2>/dev/null \
      | sed -n 's/.*"hostname": *"\(echo-[a-z]*\)-[a-z0-9]*-[a-z0-9]*".*/\1/p' | head -1; } || true
}

# Every probe states what SHOULD happen if the data plane full-matches. A cell
# reading echo-pool where "miss" is expected is the security-relevant failure.
probe() {
    local P="publishers/$NS/models"
    printf 'probe\tvalue\texpect\tistio\tkgateway\tenvoy-gw\n' | tee "$OUT"
    while IFS='|' read -r label val expect; do
        [[ -z "$label" ]] && continue
        local i k e
        i=$(hit istio "$val"); k=$(hit kgw "$val"); e=$(hit eg "$val")
        healthy istio || i="ctrl-down"; healthy kgw || k="ctrl-down"; healthy eg || e="ctrl-down"
        i="${i:-none}"; k="${k:-none}"; e="${e:-none}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "${val#"$P/"}" "$expect" "$i" "$k" "$e" | tee -a "$OUT"
    done <<EOF
alt-first|$P/model-a|hit
alt-last|$P/adapter-a2|hit
alt-absent|$P/adapter-a9|miss
alt-suffix|$P/adapter-a2x|miss
alt-prefix|$P/xadapter-a2|miss
alt-embedded|$P/evil/adapter-a2/tail|miss
alt-leading|other/$P/adapter-a2|miss
nest-base|$P/model-b|hit
nest-under|$P/model-b/adapters/x|hit
nest-sibling|$P/model-b-instruct|miss
nest-embedded|$P/evil/model-b/tail|miss
EOF
}

case "$MODE" in
  install) install_kgateway ;;
  probe)   apply_fixture; sleep 10; probe ;;
  both)    install_kgateway; apply_fixture; sleep 10; probe ;;
  *) echo "usage: $0 [install|probe|both]"; exit 2 ;;
esac

echo
echo "wrote $OUT"
