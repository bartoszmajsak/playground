# Findings, with the evidence behind each

[Overview and current workaround](../README.md) ·
[Source analysis and proposed MaaS fix](investigation.md)

Paths relative to `results/kuadrant-1.5.3+istio-1.29.2+vllm-cpu/` unless
stated. The verification suite added on 2026-09-23 writes to
`results/verification-20260923/`.

## Chain before and after

- Before: `defect/diag.txt`, `defect/config_dump.json`. Istio's ext_proc at
  index 1 (0-based), `ipp-pre` at 7, raw wasm at 8, `ipp` at 9, router at 10.
  Identical indices on the production dump (`~/Downloads/dump.txt`, listener
  443).
- First fix (`pre-only`): `fix/diag.txt`. `ipp-pre` at 1, Istio's ext_proc at
  2, wasm at 8, `ipp` at 9. `NO_DUPLICATES=OK`.
- Final order (`epp-after-ipp`, also `scripts/epp-order-workaround.sh`):
  `ipp-pre` at 6, wasm at 7, `ipp` at 8, Istio's ext_proc at 9, router at 10,
  on both listeners (`epp-after-ipp-probe/run.log`).

## Defect 1: EPP bypassed

- `defect/traffic.tsv`: 20 x 200, every body a parsed completion.
- `defect/access.jsonl`: every line on the `vllm-pool-kserve-route.4` rule and
  the pool cluster, `model_hdr` set (ipp-pre ran), `ep_requested` null.
  Upstream hosts 7/7/6: Envoy's round robin, no picker.
- `defect/epp.log`: 0 x `EPP received request`; picker counter delta 0/32.
- Same-prefix burst 3/5/4 across pods; every pod paid its own prefix miss
  (`vllm-*-prefix-{before,after}.prom`).

## First fix (`pre-only`): EPP engaged, responses empty

- `fix/traffic.tsv` (run of 2026-09-23 with body checks): 20 x 200, 1 parsed
  completion, 19 bodies of 0 bytes. `fix/traffic-prefix.tsv`: 12 x 200, 11 to
  12 empty. `fix/traffic-sse.tsv`: 200, `[DONE]`, sometimes curl exit 18.
- `fix/access.jsonl`: `ep_requested` set on every line and equal to
  `upstream_host`; picker counter +33 (20 + 12 + the streamed request);
  `fix/epp.log` 33 received. Routing is right; the response path is not.
- Burst 8/4/0 with the pinned pod's `prefix_cache_hits_total` +1024 of +1659:
  the picker works, which is what made the empty bodies easy to miss.
- The first version of `score.py` keyed on status codes and passed this. The
  independent review in `results/fresh-review-20260923T054744Z/REPORT.md`
  caught it with a probe that read the payload.

## Why the responses are empty

`empty-body/proxy-debug.log`, `empty-body/headers.txt` (`200`,
`transfer-encoding: chunked`), `empty-body/body.bin` (0 bytes). One request,
ext_proc and wasm at debug, TRLP present, `pre-only` applied. Response path
`router -> ipp -> wasm -> EPP -> ipp-pre`:

1. `ipp` drains the 633-byte body and the end-of-stream frame, re-injects two
   chunks. The first continues the headers: the EPP filter sends its
   ResponseHeaders message, stops, forwards the 633 bytes to the EPP.
2. The wasm gets the re-injected end-of-stream frame, dispatches the TRLP
   `Report` and pauses. The empty frame sits in the filter manager's shared
   buffer with end-of-stream observed.
3. The EPP's header reply arrives; its filter never saw end-of-stream, so it
   continues; `commonContinue()` forwards the parked empty frame as
   end-of-stream past the EPP filter. Response over. `onDestroy` on all three
   ext_proc filters, then `proxy_on_grpc_receive invalid context_id` when the
   `Report` reply lands.

Isolation on the live cluster (controller paused, policies deleted and
restored): no TRLP on the route, complete bodies; EPP response processing
skipped, complete bodies; TRLP restored, empty again. Streaming completes
because the header reply lands before the end frame.

Known and fixed upstream: Envoy #45355 removes exactly the header-reply
continue seen at step 3 (in v1.37.6, v1.38.4, v1.39.1; istio/proxyv2 1.29.8 is
the first Istio 1.29 proxy with it; OSSM 1.26.8's Envoy 1.34.14 has the call
in `handleHeadersResponse`). Kuadrant reproduced the same wasm trace on RHCL
1.4.2 (github.com/adam-cattermole/envoy-eos-pause); MaaS tracks it as
RHOAIENG-94419. #43175 is in the build and does not cover this; #46842 is not
in the build and addresses a Continue-after-drain case, not a Pause.

## Why the `extproc` variant is wrong

Both stages around Istio's ext_proc: `ipp-pre, ext_proc, ipp, ..., wasm,
router`. 20 x 401 with `ep_requested` set. `ipp`'s first plugin,
`maas-headers-guard`, removes `authorization` (plugin.go:91) because in the
designed order it runs after auth. Ahead of the wasm it strips the credential
before Authorino sees it. `ipp` has to stay behind the auth filter.

## `first` variant

`INSERT_FIRST` for `ipp-pre`, no anchor: 5/5 picks in a smoke run, and the
same response defect as `pre-only`, for the same reason (the EPP filter is
still ahead of the wasm). Retracted as the shape of the MaaS fix.

## Final order (`epp-after-ipp`): EPP engaged, responses complete, auth first

Standalone probe with `scripts/epp-order-workaround.sh apply` on kind,
2026-09-23 (`epp-after-ipp-probe/`): 20 x 200 with 20 parsed completions, 0
empty; burst 12 x 200 with 12 completions; streamed request 200, curl exit 0,
2470 bytes, `[DONE]`; picker +33 for 33 authenticated requests; 5 requests
without credentials 401 with picker +0; revert restored the bypassed chain.

The independent fresh-cluster experiments
(`results/fresh-review-20260923T054744Z/REPORT.md`): 60 requests, 60 picks,
60 complete responses, six SSE, six fragmented bodies, a 12-request burst,
189 tokens reported and 189 charged by Limitador, 429 after quota exhaustion
with no EPP call.

The general validation suite separately passed nine phases / 220 requests.
Its final-order phase returned 34 complete responses and charged 7,034 tokens.
See the [recorded run](../results/verification-20260923/validate.out).

## auth-order

- `auth-order/traffic.tsv`: 20 x 401 (no `Authorization` header sent) with
  the `pre-only` order.
- `auth-order/access.jsonl`: `ep_requested` set on all 20, route resolved;
  picker +20. With the final order the same traffic costs 0 picks.

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
- `ep_served` is null on Istio 1.29.2: the proxy does not populate
  `envoy.lb:x-gateway-destination-endpoint-served`; `upstream_host` carries
  the same fact.
