# Findings, with the evidence behind each

All paths relative to `results/kuadrant-1.5.3+istio-1.29.2/`.

## Chain before and after

- Before: `defect/diag.txt`, `defect/config_dump.json`. Istio's ext_proc at
  index 1 (0-based), `ipp-pre` at 7, raw wasm at 8, `ipp` at 9, router at 10.
  Identical indices on the production dump (`~/Downloads/dump.txt`, listener
  443).
- After (`pre-only`): `fix/diag.txt`. `ipp-pre` at 1, Istio's ext_proc at 2,
  wasm at 8, `ipp` at 9. `NO_DUPLICATES=OK`, so the REMOVE in the fix
  EnvoyFilter took and Istio did not re-add the MaaS insert.
- The fix object: `manifests/generated/fix-envoyfilter.yaml`, rendered from the
  live controller-owned EnvoyFilter by `scripts/render-fix.sh`.

## Defect

- `defect/traffic.tsv`: 20 x 200.
- `defect/access.jsonl`: every line `route_name=maas-epp-spike.sim-pool-kserve-route.4`,
  `upstream_cluster=outbound|54321||sim-pool-inference-pool-ip-93c59962...`,
  `model_hdr=publishers/maas-epp-spike/models/facebook/opt-125m`,
  `ep_requested` null. Upstream hosts 10.244.0.34/.35/.36 with 6/7/7 requests:
  Envoy's round robin, no picker.
- `defect/epp-before.prom` vs `defect/epp-after.prom`:
  `inference_extension_plugin_duration_seconds_count{extension_point="Picker"}`
  61 -> 61.

## Fix (`pre-only`)

- `fix/traffic.tsv`: 20 x 200.
- `fix/access.jsonl`: `ep_requested` set on every line and equal to
  `upstream_host`; picks 6/6/8 across the three pods.
- Picker counter 61 -> 81.
- `ep_served` is null on every line: Istio 1.29.2 (Envoy 1.37.2-dev) does not
  populate `envoy.lb:x-gateway-destination-endpoint-served`.

## Why the `extproc` variant is wrong for MaaS

First attempt used `FIX_VARIANT=extproc` (both stages around Istio's
ext_proc). Chain: `ipp-pre, ext_proc, ipp, ..., wasm, router`. Result: 20 x
401 with `ep_requested` set. `ipp`'s first plugin, `maas-headers-guard`,
removes `authorization` (plugin.go:91) because in the designed order it runs
after auth and must not forward the MaaS key to the model server. Ahead of
the wasm it strips the credential before Authorino sees it. `ipp` has to stay
`INSERT_AFTER` the auth filter.

## Real vLLM (default backend), `results/kuadrant-1.5.3+istio-1.29.2+vllm-cpu/`

Same chain, same verdicts, plus routing-quality evidence from the same-prefix
burst (12 requests, 6 concurrent, one shared prefix, `max_tokens: 32`):

- `defect/`: `epp.log` 0 x `EPP received request`; burst 3/5/4 across the
  pods (`access-prefix.jsonl`); `vllm-*-prefix-{before,after}.prom` deltas:
  each pod served 3-5 and had one miss each (hits 512/828, 384/621,
  640/1038 prefix tokens).
- `fix/`: `epp.log` 32 received (20 + 12); picker counter +32; burst 8/4/0;
  the pinned pod's `vllm:prefix_cache_hits_total` +1024 of +1659 queried,
  the second +512/+828, the third +0/+0.
- `auth-order/`: 20 x 401, `epp.log` 20 received, picker +20.
- `vllm:kv_cache_usage_perc` is 0 in every after-scrape: the cache is freed
  before the scrape lands with this model size. Not a contradiction, just not
  a usable signal at this scale.

## `first` variant (the shape of the MaaS fix)

`FIX_VARIANT=first ./validate.sh --scenario fix --smoke`: REMOVE `ipp-pre`,
INSERT_FIRST it with no anchor. Chain `ipp-pre, istio.metadata_exchange,
envoy.filters.http.ext_proc, ...`. 5/5 picker calls, all 200, pick ==
upstream host. Works without an InferencePool on the gateway, which the
INSERT_BEFORE variant cannot.

## auth-order

- `auth-order/traffic.tsv`: 20 x 401 (no `Authorization` header sent).
- `auth-order/access.jsonl`: `ep_requested` set on all 20, route resolved.
- Picker counter 41 -> 61.

## Vendored installer changes (upstream candidates)

`patches/local-deploy.upstream.diff` against `models-as-a-service` `f30307464261`:

1. `KUADRANT_VERSION` 1.3.1 -> 1.5.3; drop the no-op `--set manager.env[0]...`.
2. Compare the istioctl version on PATH with `ISTIO_VERSION`; install on mismatch.
3. Clone `opendatahub-io/kserve` before Istio and apply
   `config/llmisvc/gateway-inference-extension.yaml` before istiod starts.
4. `istioctl install -f` an IstioOperator (JSON access log with the endpoint
   metadata fields).
5. MetalLB pool per slot.
6. cert-manager Certificates for `maas-controller-webhook-cert` and
   `maas-controller-metrics-tls` from `maas-ca-issuer`.
7. LLMISVC CRDs from the clone (`config/crd/full/llmisvc/`) instead of the
   `v1alpha1`-only commit `47894470ea49`.
8. Gateway: `allowedRoutes.namespaces.from: Selector` +
   `maas.opendatahub.io/gateway-access: "true"` labels on `maas-system`,
   `llm`, `llm-internal`; an HTTPS listener (self-signed via cert-manager) so
   maas-api's `ResolveGatewayInternalHost` finds a 443 port.
9. NetworkPolicy `payload-processing-allow-gateway` admitting the gateway
   namespace to the IPP pods (selector `app in (payload-processing,
   payload-pre-processing)`; an empty selector isolates the gateway pod).
10. `behavior: merge` on the wrapper's `maas-parameters` generator.
11. `cert-manager.io/inject-ca-from` on the validating webhook, wait for the
    caBundle, restart the controller once.

## Known noise

- `ExternalModel` status update conflicts in maas-controller and both IPP
  deployments, for the installer's `llm-katan-openai` fixture.
- `maas-api-key-cleanup` CronJob: `CreateContainerConfigError`, non-numeric
  user in `curlimages/curl` under `runAsNonRoot`.
- IPP `setup.trace` export errors: no OTLP collector on kind.
