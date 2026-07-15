# GIE Conformance Test Runner
#
# Usage:
#   make test-aigw            # Envoy AI Gateway (fresh cluster)
#   make test-istio           # Istio (fresh cluster)
#   make compare              # Both, side by side
#   make test-aigw RUN_TEST=GatewayWeightedAcrossTwoInferencePools

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ── Versions ─────────────────────────────────────────────────────────
EG_VERSION            ?= v1.8.1
AIGW_VERSION          ?= 1.0.0
ISTIO_VERSION         ?= 1.30.2
GATEWAY_API_VERSION   ?= v1.5.0
# Pinned to match the conformance test code + CRDs; the top-level reproducer
# (setup.sh) uses v1.0.2 which matches envoy-ai-gateway's go.mod dependency.
# v1.4.0 is the latest stable release with the weighted split test warmup fix
# and proper EPP images (v1.5.0 ships rc EPP images that cause test failures).
GIE_VERSION           ?= v1.4.0
KUBERNETES_VERSION    ?= v1.36.1
METALLB_VERSION       ?= v0.13.10

# ── GIE repo (auto-cloned into .gie/ if not overridden) ──────────────
GIE_REPO              ?= $(CURDIR)/.gie

# ── Custom images (set to override helm defaults) ────────────────────
AIGW_CONTROLLER_IMAGE ?=

# ── Test options ─────────────────────────────────────────────────────
RUN_TEST              ?=
REPORT_DIR            := $(CURDIR)/reports

# ── Namespaces ───────────────────────────────────────────────────────
AIGW_NS               := envoy-ai-gateway-system
EG_NS                 := envoy-gateway-system

# ── Per-implementation config (keyed by impl name) ───────────────────
# Gateway class
gc.aigw               := inference-pool
gc.istio              := istio
# Report metadata
org.aigw              := envoyproxy
org.istio             := istio
project.aigw          := envoy-ai-gateway
project.istio         := istio
url.aigw              := https://github.com/envoyproxy/ai-gateway
url.istio             := https://istio.io
contact.aigw          := github.com/envoyproxy/ai-gateway/issues
contact.istio         := @istio/maintainers
version.aigw          := v$(AIGW_VERSION)
version.istio         := $(ISTIO_VERSION)
report.aigw           := $(REPORT_DIR)/aigw-v$(AIGW_VERSION)-gateway-report.yaml
report.istio          := $(REPORT_DIR)/istio-$(ISTIO_VERSION)-gateway-report.yaml

# ═══════════════════════════════════════════════════════════════════════
# Embedded manifests
# ═══════════════════════════════════════════════════════════════════════

define EG_VALUES
config:
  envoyGateway:
    gateway:
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
    logging:
      level:
        default: info
    provider:
      type: Kubernetes
    extensionApis:
      enableEnvoyPatchPolicy: true
      enableBackend: true
    extensionManager:
      hooks:
        xdsTranslator:
          translation:
            listener:
              includeAll: true
            route:
              includeAll: true
            cluster:
              includeAll: true
            secret:
              includeAll: true
          post:
            - Translation
            - Cluster
            - Route
      service:
        fqdn:
          hostname: ai-gateway-controller.$(AIGW_NS).svc.cluster.local
          port: 1063
      backendResources:
        - group: inference.networking.k8s.io
          kind: InferencePool
          version: v1
endef

define EG_RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: eg-inference-pool-access
rules:
- apiGroups:
  - inference.networking.k8s.io
  resources:
  - inferencepools
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: eg-inference-pool-access
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: eg-inference-pool-access
subjects:
- kind: ServiceAccount
  name: envoy-gateway
  namespace: $(EG_NS)
endef

export EG_VALUES
export EG_RBAC

# ═══════════════════════════════════════════════════════════════════════

help: ## Show this help
	@echo "GIE Conformance Test Runner"
	@echo ""
	@echo "  make test-aigw           Envoy AI Gateway (fresh cluster)"
	@echo "  make test-istio          Istio (fresh cluster)"
	@echo "  make compare             Both, side by side"
	@echo ""
	@echo "  make test-aigw  RUN_TEST=GatewayWeightedAcrossTwoInferencePools"
	@echo "  make test-istio RUN_TEST=GatewayWeightedAcrossTwoInferencePools"
	@echo ""
	@echo "  make teardown-aigw       Delete Envoy AI Gateway cluster"
	@echo "  make teardown-istio      Delete Istio cluster"
	@echo ""
	@echo "Versions (override with VAR=value):"
	@echo "  AIGW_VERSION=$(AIGW_VERSION)  EG_VERSION=$(EG_VERSION)  ISTIO_VERSION=$(ISTIO_VERSION)"
	@echo "  GIE_VERSION=$(GIE_VERSION)  GATEWAY_API_VERSION=$(GATEWAY_API_VERSION)  K8S=$(KUBERNETES_VERSION)"

# ═══════════════════════════════════════════════════════════════════════
# test-% : parametric entry point
# ═══════════════════════════════════════════════════════════════════════

test-%: ensure-gie ## Run conformance tests (test-aigw, test-istio)
	$(eval impl := $(subst test-,,$@))
	@-kind delete cluster --name gie-$(impl) 2>/dev/null
	@$(MAKE) --no-print-directory _cluster  CLUSTER=gie-$(impl)
	@$(MAKE) --no-print-directory _crds     CLUSTER=gie-$(impl)
	@$(MAKE) --no-print-directory _install-$(impl) CLUSTER=gie-$(impl)
	@$(MAKE) --no-print-directory _wait-gc  CLUSTER=gie-$(impl) GW_CLASS=$(gc.$(impl))
	@$(MAKE) --no-print-directory _run \
		CLUSTER=gie-$(impl) \
		GW_CLASS=$(gc.$(impl)) \
		REPORT=$(report.$(impl)) \
		ORG=$(org.$(impl)) \
		PROJECT=$(project.$(impl)) \
		IMPL_URL=$(url.$(impl)) \
		CONTACT=$(contact.$(impl)) \
		VER=$(version.$(impl))
	@echo ""
	@echo "================================================================"
	@echo "  Done. Report: $(report.$(impl))"
	@echo "  Cluster 'gie-$(impl)' still running. 'make teardown-$(impl)' to remove."
	@echo "================================================================"

# ═══════════════════════════════════════════════════════════════════════
# teardown-% : parametric cleanup
# ═══════════════════════════════════════════════════════════════════════

teardown-%: ## Delete cluster (teardown-aigw, teardown-istio)
	$(eval impl := $(subst teardown-,,$@))
	@-kind delete cluster --name gie-$(impl) 2>/dev/null
	@echo "Cluster 'gie-$(impl)' deleted."

# ═══════════════════════════════════════════════════════════════════════
# compare
# ═══════════════════════════════════════════════════════════════════════

compare: ensure-gie ## Run both implementations in parallel, print comparison
	@echo "==> Running aigw and istio in parallel..."
	@$(MAKE) -j2 --no-print-directory _compare-aigw _compare-istio; \
	echo ""; \
	echo "================================================================"; \
	echo "  Comparison"; \
	echo "================================================================"; \
	echo ""; \
	for f in $(REPORT_DIR)/*.yaml; do \
		impl=$$(grep 'project:' "$$f" | head -1 | awk '{print $$2}'); \
		ver=$$(grep 'version:' "$$f" | head -1 | awk '{print $$2}'); \
		result=$$(grep 'result:' "$$f" | head -1 | awk '{print $$2}'); \
		passed=$$(grep 'Passed:' "$$f" | awk '{print $$2}'); \
		failed=$$(grep 'Failed:' "$$f" | awk '{print $$2}'); \
		printf "  %-25s %s  (passed: %s, failed: %s)\n" "$$impl $$ver" "$$result" "$$passed" "$$failed"; \
		if [ -n "$$failed" ] && [ "$$failed" != "0" ]; then \
			grep -A100 'failedTests:' "$$f" | grep '^ *-' | sed 's/^/    FAIL: /'; \
		fi; \
	done; \
	echo ""

_compare-aigw:
	@$(MAKE) --no-print-directory test-aigw RUN_TEST="$(RUN_TEST)" 2>&1 | sed 's/^/[aigw]  /'

_compare-istio:
	@$(MAKE) --no-print-directory test-istio RUN_TEST="$(RUN_TEST)" 2>&1 | sed 's/^/[istio] /'

# ═══════════════════════════════════════════════════════════════════════
# Internal targets
# ═══════════════════════════════════════════════════════════════════════

ensure-gie:
	@if [ ! -d "$(GIE_REPO)/.git" ]; then \
		echo "==> Cloning gateway-api-inference-extension..."; \
		git clone https://github.com/kubernetes-sigs/gateway-api-inference-extension.git "$(GIE_REPO)"; \
	fi
	@cd "$(GIE_REPO)" && \
		CURRENT=$$(git describe --tags --exact-match 2>/dev/null || echo ""); \
		if [ "$$CURRENT" != "$(GIE_VERSION)" ]; then \
			echo "==> Checking out GIE $(GIE_VERSION)"; \
			git fetch --tags 2>/dev/null; \
			git checkout $(GIE_VERSION) 2>/dev/null; \
		fi

_cluster:
	$(eval KC := kubectl --context kind-$(CLUSTER))
	@echo ""
	@echo "==> [1/4] Creating cluster '$(CLUSTER)' (k8s $(KUBERNETES_VERSION))"
	@kind get clusters 2>/dev/null | grep -q "^$(CLUSTER)$$" || \
		kind create cluster --name $(CLUSTER) --image kindest/node:$(KUBERNETES_VERSION) --wait 120s
	@echo "    Installing MetalLB..."
	@$(KC) apply -f https://raw.githubusercontent.com/metallb/metallb/$(METALLB_VERSION)/config/manifests/metallb-native.yaml 2>&1 | grep -c "created\|configured" | xargs -I{} echo "    {} resources applied"
	@$(KC) wait --namespace metallb-system --for=condition=ready pod --selector=component=controller --timeout=120s 2>/dev/null || true
	@$(KC) wait --namespace metallb-system --for=condition=ready pod --selector=component=speaker --timeout=120s 2>/dev/null || true
	@sleep 3
	@NETWORK_PREFIX=$$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1); \
	printf 'apiVersion: metallb.io/v1beta1\nkind: IPAddressPool\nmetadata:\n  name: kind-pool\n  namespace: metallb-system\nspec:\n  addresses:\n  - %s.200-%s.250\n---\napiVersion: metallb.io/v1beta1\nkind: L2Advertisement\nmetadata:\n  name: kind-l2\n  namespace: metallb-system\nspec:\n  ipAddressPools:\n  - kind-pool\n' "$$NETWORK_PREFIX" "$$NETWORK_PREFIX" | $(KC) apply -f - 2>&1 | grep -v "^$$"

_crds:
	$(eval KC := kubectl --context kind-$(CLUSTER))
	@echo ""
	@echo "==> [2/4] Installing CRDs (Gateway API $(GATEWAY_API_VERSION), GIE $(GIE_VERSION))"
	@$(KC) apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/standard-install.yaml 2>&1 | grep -c "created\|configured" | xargs -I{} echo "    {} Gateway API resources"
	@$(KC) apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$(GIE_VERSION)/manifests.yaml 2>&1 | grep -c "created\|configured" | xargs -I{} echo "    {} GIE resources"

_install-aigw:
	$(eval KC := kubectl --context kind-$(CLUSTER))
	$(eval HC := helm --kube-context kind-$(CLUSTER))
	@echo ""
	@echo "==> [3/4] Installing Envoy Gateway $(EG_VERSION) + AI Gateway $(AIGW_VERSION)"
	@echo "    Installing EG CRDs (server-side apply to avoid field manager conflicts)..."
	@TMPDIR=$$(mktemp -d) && \
	helm pull oci://docker.io/envoyproxy/gateway-helm --version $(EG_VERSION) --untar --untardir "$$TMPDIR" 2>/dev/null && \
	$(KC) apply --server-side --force-conflicts -f "$$TMPDIR/gateway-helm/charts/crds/crds/generated/" 2>&1 \
		| grep -c "serverside-applied\|created\|configured" | xargs -I{} echo "    {} CRDs applied"; \
	rm -rf "$$TMPDIR"
	@TMPVALS=$$(mktemp /tmp/eg-values.XXXXXX.yaml); \
	echo "$$EG_VALUES" > "$$TMPVALS"; \
	$(HC) upgrade -i eg oci://docker.io/envoyproxy/gateway-helm \
		--version $(EG_VERSION) -n $(EG_NS) --create-namespace --skip-crds \
		-f "$$TMPVALS" 2>&1 | tail -1; \
	rm -f "$$TMPVALS"
	@echo "$$EG_RBAC" | $(KC) apply -f - 2>&1 | grep -v "^$$"
	@echo "    Waiting for Envoy Gateway..."
	@$(KC) rollout status deployment/envoy-gateway -n $(EG_NS) --timeout=120s
	@$(HC) upgrade -i ai-eg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
		--version $(AIGW_VERSION) -n $(AIGW_NS) --create-namespace 2>&1 | tail -1
	@$(HC) upgrade -i ai-eg oci://docker.io/envoyproxy/ai-gateway-helm \
		--version $(AIGW_VERSION) -n $(AIGW_NS) --create-namespace 2>&1 | tail -1
	@echo "    Waiting for AI Gateway..."
	@$(KC) rollout status deployment -n $(AIGW_NS) --timeout=120s 2>/dev/null || true
	@if [ -n "$(AIGW_CONTROLLER_IMAGE)" ]; then \
		echo "    Loading custom controller image: $(AIGW_CONTROLLER_IMAGE)"; \
		kind load docker-image $(AIGW_CONTROLLER_IMAGE) --name $(CLUSTER); \
		IMAGE_REPO=$$(echo "$(AIGW_CONTROLLER_IMAGE)" | cut -d: -f1); \
		IMAGE_TAG=$$(echo "$(AIGW_CONTROLLER_IMAGE)" | cut -d: -f2); \
		$(HC) upgrade -i ai-eg oci://docker.io/envoyproxy/ai-gateway-helm \
			--version $(AIGW_VERSION) -n $(AIGW_NS) \
			--set controller.image.repository=$$IMAGE_REPO \
			--set controller.image.tag=$$IMAGE_TAG \
			--set controller.imagePullPolicy=IfNotPresent 2>&1 | tail -1; \
		$(KC) rollout status deployment -n $(AIGW_NS) --timeout=120s 2>/dev/null || true; \
	fi
	@echo ""
	@echo "==> [4/4] Creating GatewayClass 'inference-pool'"
	@printf 'apiVersion: gateway.networking.k8s.io/v1\nkind: GatewayClass\nmetadata:\n  name: inference-pool\nspec:\n  controllerName: gateway.envoyproxy.io/gatewayclass-controller\n' | $(KC) apply -f -

_install-istio:
	$(eval KC := kubectl --context kind-$(CLUSTER))
	$(eval HC := helm --kube-context kind-$(CLUSTER))
	@echo ""
	@echo "==> [3/4] Installing Istio $(ISTIO_VERSION)"
	@helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
	@helm repo update istio 2>&1 | tail -1
	@$(KC) create namespace istio-system 2>/dev/null || true
	@$(HC) upgrade -i istio-base istio/base -n istio-system --version $(ISTIO_VERSION) --wait 2>&1 | tail -1
	@$(HC) upgrade -i istiod istio/istiod -n istio-system --version $(ISTIO_VERSION) \
		--set resources.requests.cpu=5m --set resources.requests.memory=32Mi \
		--set pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true \
		--set pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true \
		--wait 2>&1 | tail -1
	@echo "    Waiting for istiod..."
	@$(KC) rollout status deployment/istiod -n istio-system --timeout=120s
	@echo ""
	@echo "==> [4/4] Configuring EPP DestinationRules"
	@$(KC) create namespace inference-conformance-app-backend 2>/dev/null || true
	@for svc in primary-endpoint-picker-svc secondary-endpoint-picker-svc dp-endpoint-picker-svc; do \
		printf 'apiVersion: networking.istio.io/v1\nkind: DestinationRule\nmetadata:\n  name: %s-tls\n  namespace: inference-conformance-app-backend\nspec:\n  host: "%s.inference-conformance-app-backend.svc.cluster.local"\n  trafficPolicy:\n    tls:\n      mode: SIMPLE\n      insecureSkipVerify: true\n' "$$svc" "$$svc" | $(KC) apply -f - 2>&1 | grep -v "^$$"; \
	done

_wait-gc:
	$(eval KC := kubectl --context kind-$(CLUSTER))
	@echo ""
	@echo "    Waiting for GatewayClass '$(GW_CLASS)'..."
	@for i in $$(seq 1 30); do \
		STATUS=$$($(KC) get gatewayclass $(GW_CLASS) \
			-o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null); \
		if [ "$$STATUS" = "True" ]; then echo "    GatewayClass accepted."; break; fi; \
		if [ "$$i" = "30" ]; then echo "    WARNING: not accepted after 150s"; fi; \
		sleep 5; \
	done

_run:
	@mkdir -p $(REPORT_DIR)
	@echo ""
	@echo "==> Running conformance tests"
	@if [ -n "$(RUN_TEST)" ]; then echo "    Test: $(RUN_TEST)"; else echo "    Running all tests"; fi
	@echo ""
	@KUBECONFIG=$$(kind get kubeconfig --name $(CLUSTER) 2>/dev/null > /tmp/kubeconfig-$(CLUSTER) && echo /tmp/kubeconfig-$(CLUSTER)) && \
	cd $(GIE_REPO) && KUBECONFIG=$$KUBECONFIG \
	go test -v -count=1 -timeout 30m ./conformance/... -args \
		-gateway-class $(GW_CLASS) \
		-cleanup-base-resources=false \
		-allow-crds-mismatch=true \
		-report-output=$(REPORT) \
		-organization="$(ORG)" \
		-project="$(PROJECT)" \
		-url="$(IMPL_URL)" \
		-contact="$(CONTACT)" \
		-version="$(VER)" \
		-mode=default \
		$(if $(RUN_TEST),-run-test="$(RUN_TEST)",)
