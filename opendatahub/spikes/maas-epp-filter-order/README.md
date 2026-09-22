# MaaS EPP Filter Order Spike

Reproduces, on kind, why the InferencePool endpoint picker (EPP) is never called
on a MaaS gateway running RHCL 1.4 / Kuadrant 1.5: the MaaS `ipp-pre` ext_proc
filter is inserted after Istio's InferencePool ext_proc filter. Diagnoses it
from the live gateway, applies a fix, and shows the EPP being called.

Analysis this spike verifies:
https://gist.github.com/bartoszmajsak/44644760573111949faf158c68a5c9f4

## TL;DR

- On Kuadrant >= 1.5 (RHCL 1.4) the MaaS `ipp-pre` ext_proc lands after
  Istio's InferencePool ext_proc. Envoy reads that filter's per-route picker
  once, at request headers, when no header-gated route matches yet. The EPP is
  never called and the pool round-robins.
- Reproduced on kind with the real stack (Istio 1.29.2, Kuadrant 1.5.3, MaaS,
  ODH llmisvc, llm-d EPP v0.10.0, IPP `odh-stable`). Same 11-filter chain as
  production; the diagnostic gives the same verdict on the production dump.
- 20 body-routed requests per scenario: defect - 0 picker calls, 3 pods hit
  round robin, all 200. Fix - 20 picker calls, pick == upstream host, all 200.
  Fix without credentials - 401 x20 and still 20 picker calls.
- Fix: re-anchor `ipp-pre` `INSERT_BEFORE envoy.filters.http.ext_proc`. Only
  `ipp-pre`. Moving `ipp` too puts `maas-headers-guard` ahead of auth, it
  strips `Authorization`, and every request 401s (measured).
- Workaround for a live cluster: one extra EnvoyFilter rendered from the
  controller-owned one, `oc apply` to enable, `oc delete` to revert. Survives
  controller reconciles and gateway restarts. See "Workaround on a live
  cluster" below.
- Cost: the EPP runs before Kuadrant auth. That is Istio's placement plus
  Kuadrant's router anchor, not the fix; unauthenticated requests reach the
  picker.
- Diagnostic: `scripts/check-filter-order.sh`. One file, `kubectl`/`oc` +
  `jq` + `python3`, also scores a saved `config_dump`.

## What is measured, per scenario

Real vLLM on CPU, three replicas, 20 body-routed requests one at a time plus a
12-request burst sharing one prompt prefix, 6 concurrent
(`results/kuadrant-1.5.3+istio-1.29.2+vllm-cpu/`):

| | bypassed (`defect`) | engaged (`fix`, `ipp-pre` re-anchored) |
|---|---|---|
| chain verdict from the config dump | BROKEN: `ipp-pre` [8] after `envoy.filters.http.ext_proc` [2] | OK: `ipp-pre` [2] before it [3] |
| EPP log, `EPP received request` in the window | 0 | 32 |
| EPP picker counter delta | 0 / 32 | 32 / 32 |
| `ep_requested` in the gateway access log | empty on all 20 | set on all 20, equal to `upstream_host` |
| the 20 single requests, by pod | 7 / 7 / 6 (round robin) | as picked |
| the same-prefix burst, by pod | 3 / 5 / 4 | 8 / 4 / 0 |
| vLLM `prefix_cache_hits_total` per pod, tokens | every pod misses once: 512/828, 384/621, 640/1038 | pinned pod 1024/1659, second 512/828, third idle 0/0 |
| response codes | 200 x32 | 200 x32 |

Structural and empirical, side by side: the verdict is read off the filter
chain; the counters and logs are what the same traffic did. The EPP scores
with `queue-scorer=2, kv-cache-utilization-scorer=2, prefix-cache-scorer=3,
no-hit-lru-scorer=2` (KServe's preset, captured in `epp-config.yaml`), so an
engaged EPP concentrates same-prefix traffic where the cache holds it, and a
bypassed one makes every pod pay the miss. `vllm:kv_cache_usage_perc` reads 0
after each burst at this model size; the prefix counters are the durable
signal.

## What this proves

Istio implements an InferencePool as one listener-level
`envoy.filters.http.ext_proc` (inert: cluster `dummy`, header mode `SKIP`) plus
a per-route `ExtProcPerRoute` override that names the real picker. Envoy merges
that override exactly once per stream, in `decodeHeaders`. KServe's generated
pool routes match on `X-Gateway-Model-Name`, which MaaS produces from the
request body in `ipp-pre`. So `ipp-pre` has to run before Istio's ext_proc, or
the picker is never bound: the route re-resolves after `ipp-pre`, the router
dials the pool, and `override_host` falls back to round robin.

Who puts `ipp-pre` where: the MaaS EnvoyFilter
(`deployment/base/payload-processing/manager/envoy-filter.yaml`) anchors it
`INSERT_BEFORE` Kuadrant's auth filter. Istio places every WasmPlugin CR before
its InferencePool ext_proc (`pilot/pkg/networking/core/listener_builder.go`),
so with Kuadrant <= 1.4 (WasmPlugin) the anchor lands before the EPP filter and
the chain works. Kuadrant >= 1.5.0 (RHCL 1.4) injects the wasm-shim through an
EnvoyFilter `INSERT_BEFORE` the router (`internal/istio/utils.go`,
`BuildEnvoyFilterWasmPatch`), i.e. after Istio's ext_proc, and the same MaaS
anchor now pulls `ipp-pre` in behind the EPP filter.

Expected outcomes:

- `defect`: diagnostic reports `EPP_ENGAGED BROKEN`; body-routed requests return
  200 on the right model, the EPP picker counter does not move, no request
  carries an endpoint pick, requests spread across the pool.
- `fix`: a priority-20 EnvoyFilter re-anchors `ipp-pre`/`ipp` on
  `envoy.filters.http.ext_proc`; diagnostic reports `OK`; the picker counter
  moves once per request and every request carries a pick that Envoy honoured.
- `auth-order`: with the fix, the EPP runs before Kuadrant auth. Unauthenticated
  requests get 401 and still cost an EPP pick. This is inherent to Istio's
  placement plus Kuadrant's router-anchored injection, not to the fix.

## Setup

```bash
./setup.sh                          # ~15 min: kind + Istio 1.29.2 + Kuadrant 1.5.3 + MaaS + llmisvc + a vLLM CPU pool with EPP
MODEL_BACKEND=sim ./setup.sh        # the same with the llm-d simulator behind the pool instead
./setup.sh --teardown
```

Two model backends, same chain, same verdicts. The default, `vllm-cpu`, is
what the LoRA spikes run: `vllm/vllm-openai-cpu:v0.19.0` on the KServe preset
(`vllm serve /mnt/models --served-model-name <name> publishers/<ns>/models/<name>`),
`hf://hmellor/tiny-random-LlamaForCausalLM` fetched by the storage initializer,
`--enforce-eager`, 1 GiB of CPU KV cache per replica, three replicas. Real
vLLM, so the EPP scores on real queue and KV-cache metrics and the evidence
block prints the pool gauges it scraped. `sim` is
`ghcr.io/llm-d/llm-d-inference-sim` in echo mode for a two-minute run when the
model server is not the question. The LLMInferenceService is named after the
backend (`vllm-pool`, `sim-pool`) and KServe derives every child name from it
(`<name>-kserve-route`, `<name>-inference-pool`, `<name>-epp-service`).
Results land in `results/<kuadrant>+<istio>+<backend>/`.

The MaaS stack comes from `vendor/local-deploy.sh`, a patched copy of the MaaS
repo's own kind installer (`test/e2e/scripts/local-deploy.sh`). The copy is
generated by `patches/vendor-local-deploy.py`; `patches/local-deploy.upstream.diff`
is the resulting diff and the basis for an upstream change. What it patches and why:

| Change | Why |
|---|---|
| Kuadrant chart 1.3.1 -> 1.5.3 | 1.5.x injects the wasm-shim via EnvoyFilter, the RHCL 1.4 data plane |
| GIE CRDs applied before istiod starts | istiod wires InferencePool support only if the CRDs exist at startup |
| LLMISVC CRDs from the same clone as the controller | the pinned commit serves only `v1alpha1`; the controller from `master` stores `v1alpha2` |
| `configMapGenerator ... behavior: merge` | the base kustomization already generates `maas-parameters`; kustomize rejects a second one |
| cert-manager Certificates for `maas-controller-webhook-cert` / `maas-controller-metrics-tls` + CA injection into the validating webhook | the controller hard-mounts both secrets (service-ca on OpenShift) and its webhook is `failurePolicy: Fail` |
| Gateway `allowedRoutes.namespaces.from: Selector` + labelled namespaces | `from: Same` admits neither the maas-api route nor any model route |
| Gateway HTTPS listener with a cert-manager self-signed cert | maas-api refuses to start unless the gateway Service exposes port 443 (`ResolveGatewayInternalHost`) |
| extra NetworkPolicy allowing the gateway namespace to reach the IPP pods | the MaaS policy admits `openshift-ingress` only; kind's CNI enforces it and every ext_proc call times out |
| istioctl version check, IstioOperator file, MetalLB slot | a stale istioctl on PATH installs the wrong Istio; JSON access-log format; two spike clusters on one docker network |

Env overrides (see `lib.sh`): `CLUSTER_NAME`, `NS`, `ISTIO_VERSION`,
`KUADRANT_VERSION`, `METALLB_SLOT`, `KSERVE_ODH_REF`, `SIM_IMAGE`,
`SIM_REPLICAS`, `MODEL_NAME`, `MAAS_REPO`, `FIX_VARIANT`, `REQUESTS`.

Control run (Kuadrant 1.4.x, WasmPlugin, EPP invoked without any fix):

```bash
KUADRANT_VERSION=1.4.7 CLUSTER_NAME=maas-epp-ctl-spike METALLB_SLOT=1 ./setup.sh
KUADRANT_VERSION=1.4.7 CLUSTER_NAME=maas-epp-ctl-spike ./validate.sh --scenario control
```

## Validation

```bash
./validate.sh --scenario defect        # the EPP is bypassed
./validate.sh --scenario fix           # apply fix.sh, EPP engaged, revert
./validate.sh --scenario auth-order    # EPP before auth with the fix
./validate.sh --scenario all           # the three above; exit code = failed checks
./validate.sh --scenario defect --smoke
```

Each authenticated scenario sends 20 body-routed requests one at a time, then
a same-prefix burst: 12 requests sharing a long prompt prefix, 6 at a time,
`max_tokens: 32`. The burst is where routing quality shows: an engaged EPP
with the `prefix-cache-scorer` (weight 3 in the KServe config) pins it to the
pod that already holds the prefix; Envoy's round robin spreads it and every
pod pays its own prefix miss.

Evidence lands in `results/<slug>/<scenario>/` and is scored by `score.py`
(`validate.out` and `versions.txt` are committed):

| file | what it is |
|---|---|
| `config_dump.json`, `filters.tsv`, `routes.tsv`, `clusters.tsv` | the gateway's Envoy config: raw dump, the HTTP filter chain with positions, pool routes with header match and picker override, pool/EPP/IPP clusters with endpoint health |
| `diag.txt`, `diag.json`, `envoyfilters.yaml`, `httproutes.yaml`, `inferencepools.yaml` | the diagnostic's verdicts with reasons, and the objects that produced the chain |
| `epp-config.yaml`, `epp-before.prom`, `epp-after.prom`, `epp.log` | the EPP's scheduler config (scorers, weights), its `/metrics` before and after traffic (picker counter, pool gauges), and its log for the window (`EPP received request` per request) |
| `vllm-<pod>-{before,after,prefix-before,prefix-after}.prom` | every model pod's own `/metrics`: `vllm:request_success_total`, `vllm:prefix_cache_hits_total`, `vllm:prefix_cache_queries_total`, `vllm:kv_cache_usage_perc`, `vllm:num_requests_{running,waiting}` |
| `traffic.tsv`, `access.jsonl`, `traffic-prefix.tsv`, `access-prefix.jsonl` | per-request status and `x-inference-pod`, and the gateway access-log line per request (`route_name`, `upstream_host`, `model_hdr`, `ep_requested`) |
| `score.txt`, `headline` | the printed evidence block and checks, and the one-line result |

The evidence block printed before the checks summarises all of it: chain with
positions, verdict and reason, routes hit with their picker override, response
codes, upstream host distribution, EPP picks, picker counter delta, EPP-scraped
pool gauges, EPP scorers, EPP log counts, the burst distribution and each
vLLM pod's served count and prefix-cache hits.

The diagnostic on its own:

```bash
./scripts/check-filter-order.sh                       # this spike's gateway
./scripts/check-filter-order.sh --dump dump.json --listener-port 443   # a saved config_dump
KUBECTL=oc GATEWAY_NAMESPACE=openshift-ingress ./scripts/check-filter-order.sh --listener-port 443
```

It prints the HTTP filter chain with the three filters that matter marked,
verdict lines (`EPP_ENGAGED`, `AUTH_SEES_MODEL_HEADER`, `IPP_AFTER_AUTH`,
`EPP_AFTER_AUTH`, `NO_DUPLICATES`, `ROUTER_LAST`), the EnvoyFilters selecting the
gateway with each anchor and whether it matched, the MaaS EnvoyFilter's mode
(wasm-anchored vs router-fallback), and the pool routes with their picker
override. Exit 1 on `BROKEN`; `--expect broken|ok` inverts. It is one file with
no dependencies beyond `kubectl`/`oc`, `jq` and `python3`, so it runs on the
production gateway as is.

The fix on its own:

```bash
./fix.sh apply | revert | status       # FIX_VARIANT=pre-only (default) | first (INSERT_FIRST, the MaaS fix) | extproc (also moves ipp: breaks auth)
```

## Workaround on a live cluster

The controller renders `EnvoyFilter/payload-processing` and owns it through
server-side apply, so editing it is a losing race. The workaround is a second
EnvoyFilter, `payload-processing-epp-order`, at the MaaS one's priority + 10:
it REMOVEs `envoy.filters.http.ext_proc.ipp-pre` where the MaaS filter put it
and re-inserts the same typed_config `INSERT_BEFORE envoy.filters.http.ext_proc`.
Istio applies EnvoyFilters in priority order and does not dedupe inserts, so
the result is exactly one `ipp-pre`, ahead of the InferencePool filter.
`render-fix.sh` copies the typed_config from the live object, so timeouts,
cluster name and processing modes stay whatever the controller rendered.

```bash
export KUBECONFIG=~/.kube/config            # lib.sh otherwise points at the spike's kind kubeconfig
export KUBECTL=oc GATEWAY_NAMESPACE=openshift-ingress GATEWAY_NAME=maas-default-gateway
./scripts/check-filter-order.sh --listener-port 443       # expect EPP_ENGAGED BROKEN
./scripts/render-fix.sh fix-envoyfilter.yaml              # from the live payload-processing EnvoyFilter
oc apply -f fix-envoyfilter.yaml
./scripts/check-filter-order.sh --listener-port 443       # expect EPP_ENGAGED OK, NO_DUPLICATES OK
oc delete envoyfilter payload-processing-epp-order -n openshift-ingress   # revert
```

Preconditions and limits:

- The gateway must have an InferencePool attached, otherwise
  `envoy.filters.http.ext_proc` is absent, the REMOVE still applies and nothing
  re-inserts `ipp-pre`. `render-fix.sh` refuses in that case (`FIX_FORCE=1`
  overrides).
- Per-tenant gateways render their own EnvoyFilter: set
  `EF_NAME=payload-processing-<tenant>`.
- The copy is taken at render time. If the controller changes the `ipp-pre`
  typed_config (timeouts, cluster name), re-render and re-apply.
- It is a workaround, not the fix: a new gateway or tenant needs it applied
  again. The change belongs in `deployment/base/payload-processing/manager/envoy-filter.yaml`
  and `tenantreconcile/params.go`.

## Key findings

Runs of 2026-09-22 on Kuadrant chart 1.5.3 (EnvoyFilter, raw
`envoy.filters.http.wasm`), Istio 1.29.2 / Envoy 1.37.2, ODH llmisvc
controller `docker.io/kserve/llmisvc-controller@sha256:55b7a0…` (fork
`7d068b1b`), GIE v1.5.0-rc.2, EPP `llm-d-router-endpoint-picker@sha256:2e516f…`
(v0.10.0), IPP `odh-ai-gateway-payload-processing@sha256:ed1cc3…`. Full
records in `results/kuadrant-1.5.3+istio-1.29.2+vllm-cpu/` and
`results/kuadrant-1.5.3+istio-1.29.2+sim/`.

| backend | scenario | chain | picker calls / requests | EPP log | `ep_requested` | same-prefix burst (12) | vLLM prefix-cache hits | result |
|---|---|---|---|---|---|---|---|---|
| vLLM CPU, tiny-llama x3 | defect | BROKEN | 0 / 32 | 0 received | empty on all 20; 20 requests spread 7/7/6 | 3 / 5 / 4 across pods (top 42%) | every pod misses once: 512/828, 384/621, 640/1038 tokens | EPP bypassed, all 200 |
| vLLM CPU | fix (`pre-only`) | OK | 32 / 32 | 32 received | set on all 20, equal to `upstream_host` | 8 / 4 / 0 (top 67%) | pinned pod 1024/1659, second 512/828, third idle 0/0 | EPP engaged, prefix-aware routing, all 200 |
| vLLM CPU | auth-order (fix, no credentials) | OK | 20 / 20 | 20 received | set on all 20 | n/a | n/a | 401 for all 20, EPP still consulted |
| simulator x3 | defect | BROKEN | 0 / 20 | n/a | empty; 6/7/7 | n/a | n/a | EPP bypassed |
| simulator | fix (`pre-only`) | OK | 20 / 20 | n/a | set, equal to `upstream_host` | n/a | n/a | EPP engaged |
| simulator | auth-order | OK | 20 / 20 | n/a | set | n/a | n/a | 401 x20, 20 picks |

The kind gateway reproduces the production chain filter for filter, and the
diagnostic returns the same verdict on the saved production `config_dump`
(`--dump ~/Downloads/dump.txt --listener-port 443`):

```
[ 1] istio.metadata_exchange
[ 2] envoy.filters.http.ext_proc          <- Istio InferencePool filter, per-route picker read here
[ 3] envoy.filters.http.grpc_stats
[ 4] istio.alpn
[ 5] envoy.filters.http.fault
[ 6] envoy.filters.http.cors
[ 7] istio.stats
[ 8] envoy.filters.http.ext_proc.ipp-pre  <- X-Gateway-Model-Name produced here
[ 9] envoy.filters.http.wasm              <- Kuadrant auth (raw-wasm)
[10] envoy.filters.http.ext_proc.ipp
[11] envoy.filters.http.router
```

After `fix.sh apply` (default `FIX_VARIANT=pre-only`):

```
[ 1] istio.metadata_exchange
[ 2] envoy.filters.http.ext_proc.ipp-pre
[ 3] envoy.filters.http.ext_proc          <- header exists, picker override bound
[ 4..8] grpc_stats, alpn, fault, cors, istio.stats
[ 9] envoy.filters.http.wasm
[10] envoy.filters.http.ext_proc.ipp
[11] envoy.filters.http.router
```

What the run established:

1. **The defect is the filter order, nothing else.** With the same routes,
   policies, EPP and IPP, moving `ipp-pre` in front of Istio's ext_proc takes
   the picker from 0 calls to one call per request, and the endpoint the EPP
   asked for is the endpoint Envoy used.
2. **Only `ipp-pre` may move.** The obvious fix, re-anchoring both stages on
   Istio's ext_proc (`FIX_VARIANT=extproc`), puts `ipp` ahead of the Kuadrant
   wasm, and the post-stage `maas-headers-guard` removes the `Authorization`
   header
   (https://github.com/opendatahub-io/ai-gateway-payload-processing/blob/07727563b63153c410434a20b62f3ebc5f24ed01/pkg/plugins/maas-headers-guard/plugin.go#L91).
   Measured: every request 401 with `ep_requested` already set. The IPP
   hub-mode README's "post stage `INSERT_AFTER` the EPP filter" recipe is
   therefore wrong for MaaS on Istio-native pools; `ipp` has to stay behind
   auth.
3. **The EPP runs before auth on Kuadrant >= 1.5 whenever it runs at all.**
   Twenty requests without credentials cost twenty picker calls and got 401.
   This is Istio's placement plus Kuadrant's router anchor, not the fix; with
   Kuadrant 1.4's WasmPlugin the auth filter sits before Istio's ext_proc.
4. **Istio 1.29's Envoy does not emit `x-gateway-destination-endpoint-served`**
   in dynamic metadata; `upstream_host` carries the same fact. `score.py` falls
   back to it.
4b. **With real vLLM the bypass is a routing-quality loss, not just a missing
   log line.** The EPP runs `queue-scorer=2, kv-cache-utilization-scorer=2,
   prefix-cache-scorer=3, no-hit-lru-scorer=2` (`epp-config.yaml`, from
   KServe's scheduler preset). A 12-request burst sharing one prompt prefix
   spread 3/5/4 over the pods when bypassed and 8/4/0 once the EPP was
   engaged, and vLLM's own counters agree: bypassed, every pod paid its own
   prefix miss; engaged, the pinned pod served 8 with 1024 of 1659 prefix
   tokens hitting its cache and the third pod stayed idle. The EPP log
   (`epp.log`) shows 0 `EPP received request` in the bypassed window and one
   per request afterwards. `vllm:kv_cache_usage_perc` reads 0 after each
   burst: with a tiny model and 32 output tokens the cache empties within the
   sampling gap, so the prefix-cache counters are the durable signal here.
5. **MaaS's own kind installer does not run against today's `main`.** The
   vendored copy needed: Kuadrant 1.5.x, GIE CRDs before istiod, LLMISVC CRDs
   from the same clone as the controller (the pinned commit serves only
   `v1alpha1`), a `behavior: merge` on the duplicated `maas-parameters`
   generator, cert-manager secrets plus CA injection for the controller
   webhook, `from: Selector` on the Gateway, an HTTPS listener because maas-api
   requires a 443 Service port, and an allow NetworkPolicy because the MaaS one
   admits `openshift-ingress` only and kindnet enforces it. All in
   `patches/local-deploy.upstream.diff`.
6. Noise worth knowing about: the IPP and maas-controller log
   `ExternalModel` status conflicts for the installer's llm-katan fixture, and
   the `maas-api-key-cleanup` CronJob cannot start with `curlimages/curl`
   under `runAsNonRoot`. Neither touches the data path.

## The fix for MaaS

Measured on this cluster with `FIX_VARIANT=first` (5/5 picks, all 200,
`ipp-pre` at position 1 ahead of `istio.metadata_exchange`): insert `ipp-pre`
with `INSERT_FIRST` and no anchor at all. It is what the upstream llm-d
`payload-processor` chart does by default, it works on every Kuadrant form,
and it works on gateways that have no InferencePool (ExternalModel-only
tenants), where `envoy.filters.http.ext_proc` does not exist and an anchor on
it would match nothing. `ipp` keeps its `INSERT_AFTER` auth anchors: it must
stay behind the wasm because it strips `Authorization`.

1. `deployment/base/payload-processing/manager/envoy-filter.yaml`: replace the
   three `ipp-pre` patches (INSERT_BEFORE WasmPlugin, INSERT_BEFORE raw wasm,
   INSERT_BEFORE router) with one `operation: INSERT_FIRST` patch whose match
   has no `subFilter`. Keep the three `ipp` patches. Rewrite the "Stage 1 must
   run BEFORE the WasmPlugin" comment: stage 1 is first in the chain, ahead of
   Kuadrant auth in any form and ahead of Istio's InferencePool ext_proc,
   which reads its per-route picker once at request headers.
2. `maas-controller/pkg/platform/tenantreconcile/params.go`,
   `patchPayloadProcessingEnvoyFilter` (lines 949-1073): the patch-slice
   layout becomes `[0]` ipp-pre (always kept, only its grpc `cluster_name`
   rewritten), `[1:3]` ipp after WasmPlugin / raw wasm (kept unless the router
   fallback is on), `[3]` ipp before router (fallback), `[4:]` route disables.
   `wasmFilterPatchCount` 4 -> 2, `routerFallbackPatchCount` 2 -> 1, and the
   `wasmSubFilters` rewrite loop only touches the `ipp` patches. Update
   `patch_test.go` / `params_test.go` accordingly.
3. `scripts/check-payload-ext-proc-filters.sh`: add
   `istio_ext_proc = idx("envoy.filters.http.ext_proc")` and assert
   `pre < istio_ext_proc` when it is present, keep `pre < auth < ipp < router`,
   drop the `spec.targetRefs` assertion the controller already invalidates.
   Or replace the body with `scripts/check-filter-order.sh` from here.
4. Same one-patch change in `praxis-extproc/deploy/overlays/odh/envoy-filter.yaml`
   (four `ipp-pre` anchor variants -> one INSERT_FIRST) and its copy in
   `ai-gateway-controller/config/manifests/praxis-extproc/overlays/odh/`.
5. IPP `deploy/examples/hub-mode/README.md`: pre stage `INSERT_FIRST`, post
   stage `INSERT_AFTER` the auth filter, never "after the EPP filter".

Unchanged by the fix: the EPP runs before Kuadrant auth on Kuadrant >= 1.5. If
that matters, gate inference paths on an `Authorization` header with an Istio
AuthorizationPolicy (RBAC sits before the ext_proc in the base chain) or a
presence check in `ipp-pre`.

Not measured here, but visible in the route table: the path-prefixed
per-model URLs (`/publishers/<ns>/models/<name>/v1/...`) select the pool route
on the first pass and never depended on the order.

## References

- MaaS EnvoyFilter: https://github.com/opendatahub-io/models-as-a-service/blob/fdaa979a3586c759206368939f87895ef915cbc7/deployment/base/payload-processing/manager/envoy-filter.yaml#L80-L95
- MaaS filter-order check (asserts `pre < auth < ipp < router` only): https://github.com/opendatahub-io/models-as-a-service/blob/fdaa979a3586c759206368939f87895ef915cbc7/scripts/check-payload-ext-proc-filters.sh#L145-L157
- Istio base chain order (OSSM release-1.26): https://github.com/openshift-service-mesh/istio/blob/db8b9e53e8897459c5a309148a61d3166128e185/pilot/pkg/networking/core/listener_builder.go#L399-L416
- Istio InferencePool filter: https://github.com/openshift-service-mesh/istio/blob/db8b9e53e8897459c5a309148a61d3166128e185/pilot/pkg/xds/filters/filters.go#L163-L177
- Envoy ext_proc per-route merge (once, in decodeHeaders): https://github.com/envoyproxy/envoy/blob/v1.34.14/source/extensions/filters/http/ext_proc/ext_proc.cc#L540-L542
- Kuadrant switch to EnvoyFilter injection (first in v1.5.0): https://github.com/Kuadrant/kuadrant-operator/pull/1953
- RHCL 1.4 release notes ("migrated from an Istio WasmPlugin to EnvoyFilter"): https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html-single/release_notes/index
- IPP hub-mode README (the "INSERT_BEFORE auth" recipe): https://github.com/opendatahub-io/ai-gateway-payload-processing/blob/07727563b63153c410434a20b62f3ebc5f24ed01/deploy/examples/hub-mode/README.md#L10-L28
- Related Istio multi-pool bug this is not: istio/istio#61594, reproducer https://github.com/bartoszmajsak/istio-multipool-extproc
