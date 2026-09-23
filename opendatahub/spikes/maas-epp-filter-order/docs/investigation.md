# Filter-order investigation and proposed MaaS fix

The [README](../README.md) contains the current workaround and reproduction
commands. This document retains the source analysis, response trace, version
comparison, and proposed permanent fix. The per-experiment evidence is in
[findings.md](findings.md).

Paths and commands below are relative to the spike root.

**Evidence scope:** the ordering workaround was exercised on Istio 1.29.2 /
Envoy 1.37.2-dev. The reported OSSM 1.26.8 configuration was inspected offline.
The upstream-fix and version comparisons below are source-based; this spike
has not run a before/after proxy-upgrade validation.

## Contents

- [Why the order is wrong](#why-the-order-is-wrong)
- [Why the first fix empties responses](#why-the-first-fix-empties-responses)
- [Proposed MaaS fix and regression coverage](#fix-for-maas)
- [Related upstream reports](#related-upstream-reports)
- [Source references](#references)

## Why the order is wrong

Four facts, each with the code that makes it so:

1. Istio implements an InferencePool as one listener-level
   `envoy.filters.http.ext_proc` (cluster `dummy`, header modes `SKIP`) plus a
   per-route `ExtProcPerRoute` override naming the real picker
   ([`filters.go`](https://github.com/openshift-service-mesh/istio/blob/db8b9e53e8897459c5a309148a61d3166128e185/pilot/pkg/xds/filters/filters.go#L163-L177)).
   The base chain puts that filter right after every WasmPlugin phase and
   before `grpc_stats`, `istio.stats` and the router
   ([`listener_builder.go`](https://github.com/openshift-service-mesh/istio/blob/db8b9e53e8897459c5a309148a61d3166128e185/pilot/pkg/networking/core/listener_builder.go#L399-L416)).
2. Envoy merges the per-route ext_proc config once per stream, in
   `decodeHeaders`
   ([`ext_proc.cc`](https://github.com/envoyproxy/envoy/blob/v1.34.14/source/extensions/filters/http/ext_proc/ext_proc.cc#L540-L542)).
   KServe's pool routes match on `X-Gateway-Model-Name`. If the header is not
   there yet, no pool route matches, no picker is merged, and the route refresh
   after `ipp-pre` cannot bring the filter back.
3. MaaS produces that header from the request body in `ipp-pre` and anchors it
   `INSERT_BEFORE` Kuadrant's auth filter
   ([`envoy-filter.yaml`](https://github.com/opendatahub-io/models-as-a-service/blob/fdaa979a3586c759206368939f87895ef915cbc7/deployment/base/payload-processing/manager/envoy-filter.yaml#L80-L95),
   rendered per gateway by
   [`params.go`](https://github.com/opendatahub-io/models-as-a-service/blob/3457194a4d3e612a55ee1a6cfb0f5df39bb8137a/maas-controller/pkg/platform/tenantreconcile/params.go#L1003)).
   Nothing in it references Istio's filter.
4. Kuadrant <= 1.4 installs its filter as a WasmPlugin CR, which Istio places
   in the base chain before the InferencePool filter, so the anchor lands early
   and the chain works. Kuadrant >= 1.5.0 (RHCL 1.4) injects a raw
   `envoy.filters.http.wasm` through an EnvoyFilter `INSERT_BEFORE` the router
   ([kuadrant-operator#1953](https://github.com/Kuadrant/kuadrant-operator/pull/1953),
   [RHCL 1.4 release notes](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html-single/release_notes/index)),
   after Istio's filter. The same MaaS anchor now pulls `ipp-pre` in behind the
   EPP filter.

The production dump (`~/Downloads/dump.txt`, listener 443, OSSM 1.26.8) and
the kind gateway have the same chain, filter for filter:

```
[ 1] istio.metadata_exchange
[ 2] envoy.filters.http.ext_proc          <- Istio InferencePool filter, per-route picker read here
[ 3] envoy.filters.http.grpc_stats
[ 4] istio.alpn
[ 5] envoy.filters.http.fault
[ 6] envoy.filters.http.cors
[ 7] istio.stats
[ 8] envoy.filters.http.ext_proc.ipp-pre  <- X-Gateway-Model-Name produced here
[ 9] envoy.filters.http.wasm              <- Kuadrant auth + token rate limiting (raw wasm)
[10] envoy.filters.http.ext_proc.ipp
[11] envoy.filters.http.router
```

MaaS's own check
([`check-payload-ext-proc-filters.sh`](https://github.com/opendatahub-io/models-as-a-service/blob/fdaa979a3586c759206368939f87895ef915cbc7/scripts/check-payload-ext-proc-filters.sh#L145-L157))
asserts `pre < auth < ipp < router` only and passes this chain.

## Why the first fix empties responses

Moving `ipp-pre` in front of Istio's filter (`FIX_VARIANT=pre-only`, or
`INSERT_FIRST` as the upstream llm-d chart does) engages the EPP: 32/32 picks,
prefix-aware routing. It also makes the EPP filter the second full-duplex
ext_proc on the response path, behind the Kuadrant wasm:

```
response path:  router -> ipp -> kuadrant wasm -> EPP ext_proc -> ipp-pre -> client
```

Sequence for a non-streaming completion, from
`results/kuadrant-1.5.3+istio-1.29.2+vllm-cpu/empty-body/proxy-debug.log`
(ext_proc and wasm at debug, TRLP present):

1. `ipp` drains the 633-byte body and the 0-byte end-of-stream frame to its
   server and re-injects them as two chunks. The first re-injection continues
   the headers: the EPP filter sends its ResponseHeaders message and stops
   iteration waiting for the reply, then forwards the 633 bytes to the EPP and
   drains them (`StopIterationNoBuffer`).
2. The second re-injection is the end-of-stream frame. The wasm-shim has a
   TokenRateLimitPolicy `Report` to make from the body: `on_http_response_body`
   dispatches it and returns `Action::Pause`
   ([`kuadrant_filter.rs`](https://github.com/Kuadrant/wasm-shim/blob/222a42a812e23d5864e3239570c72559b77c5887/crates/wasm-shim/src/filter/kuadrant_filter.rs#L189-L218)).
   The empty frame is parked in the filter manager's shared response buffer
   with end-of-stream observed.
3. The EPP's header reply arrives. Its filter has not seen end-of-stream
   (`complete_body_available_` false), so `handleHeaderContinue()` takes the
   full-duplex branch and continues the filter chain
   ([`processor_state.cc` at v1.37.5](https://github.com/envoyproxy/envoy/blob/v1.37.5/source/extensions/filters/http/ext_proc/processor_state.cc#L251-L255);
   the same call sits in `handleHeadersResponse` on
   [v1.34.14](https://github.com/envoyproxy/envoy/blob/v1.34.14/source/extensions/filters/http/ext_proc/processor_state.cc#L233-L237),
   the production proxy).
   `commonContinue()` pushes the headers and then the parked empty buffer as
   end-of-stream past the EPP filter
   ([`filter_manager.cc`](https://github.com/envoyproxy/envoy/blob/c5320a6f4e6ff60c4ae33d1c08882092c5c0bd2a/source/common/http/filter_manager.cc#L107-L133)).
   The client gets `200`, `transfer-encoding: chunked`, terminator. The stream
   is destroyed, the EPP's gRPC stream is closed with the body never returned,
   and the `Report` reply lands on a destroyed context
   (`proxy_on_grpc_receive invalid context_id`).

The capture reads exactly like that: `Sending a body chunk of 633 bytes,
end_stream false` to the EPP, wasm `on_http_response_body` then `Dispatching
gRPC call to ... RateLimitService.Report`, then `Received response headers
response` carrying `x-went-into-resp-headers`, `Continuing processing`,
`onDestroy`, and the access log line with `response_code: 200`.

Why the isolation runs came out the way they did:

- No TRLP on the route: the wasm returns Continue, the end frame reaches the
  EPP filter before its header reply, `handleCompleteBodyAvailable()` waits
  for the body reply. Complete.
- EPP response processing skipped: no header reply to continue on. Complete.
- Streaming: the header reply lands long before the end frame, so the continue
  forwards nothing. Complete, occasionally without the chunked terminator
  (curl exit 18).
- One JSON request in twenty came back intact: the same race, won the other
  way.

This is a known Envoy bug, fixed upstream. Kuadrant's Adam Cattermole hit the
same trace on RHCL 1.4.2 / OSSM 1.26.8 (`proxy_on_response_body(.., 0, 1)` ->
Report, pause, `proxy_on_done` while the report is in flight,
`proxy_on_grpc_receive invalid context_id`), built a reproducer
([envoy-eos-pause](https://github.com/adam-cattermole/envoy-eos-pause)) and
bisected it to [#45355](https://github.com/envoyproxy/envoy/pull/45355):
"ext-proc: remove unnecessary continueIfNecessary()", one line out of
`handleHeaderContinue`, merged 2026-06-24. Without that continue, the chain
resumes only when the body reply arrives, so the parked frame is never pushed
past the EPP filter early. Envoy releases with it: v1.37.6, v1.38.4, v1.39.1.
MaaS tracks the symptom as RHOAIENG-94419 ("intermittently return 200 with no
body").

Who has it, by reading the pinned ext_proc source of each build:

| proxy | Envoy | header-reply continue |
|---|---|---|
| OSSM 1.26.8 (production) | 1.34.14 | present, no backport on that line |
| istio/proxyv2 1.29.2 to 1.29.7 (this spike: 1.29.2) | 1.37.2-dev to 1.37.6-dev | present |
| istio/proxyv2 1.29.8 | 1.37.7-dev | removed |
| istio/proxyv2 1.30.0 | 1.38.1-dev | present (1.38.4 needed) |

The other fixes in this area do not cover it: [#43175](https://github.com/envoyproxy/envoy/pull/43175)
for [#41654](https://github.com/envoyproxy/envoy/issues/41654) is in the tested
proxy (its runtime guard string is in the binary) and corrects a flag that is
current here; [#46842](https://github.com/envoyproxy/envoy/pull/46842) for
[#46841](https://github.com/envoyproxy/envoy/issues/46841) is absent from the
tested proxy but handles a filter that returns Continue after draining a frame,
not a Pause.

The rule that follows, on any proxy without #45355: the Kuadrant wasm has to
sit before the InferencePool filter in the chain. That is auth before
scheduling, and on the response path the wasm then pauses behind the EPP
filter, which has already seen end-of-stream. Kuadrant 1.4 had this order for
free. With #45355 in the proxy the empty bodies go away in any order; the
ordering fix is still needed for defect 1 and for auth before the EPP.

Production sees defect 2 today wherever the EPP is engaged despite defect 1:
the path-prefixed per-model URLs (`/<publisher>/<model>/v1/chat/completions`)
select the pool route by path on the first pass, which is the URL form in the
RHCL 1.4.2 report above. The bare `/v1/chat/completions` form is bypassed and
so returns full bodies. That is the "intermittent" in RHOAIENG-94419.

## Fix for MaaS

The workaround made permanent: `ipp-pre` and `ipp` stay where they are, Istio's
inert InferencePool filter moves behind `ipp`. Retracted: the earlier
recommendation to re-anchor `ipp-pre` (`INSERT_BEFORE envoy.filters.http.ext_proc`
or `INSERT_FIRST`). It engages the EPP and empties responses.

1. `deployment/base/payload-processing/manager/envoy-filter.yaml`: two more
   `HTTP_FILTER` patches after the existing `ipp` inserts, `REMOVE` with
   `subFilter.name: envoy.filters.http.ext_proc`, then `INSERT_AFTER`
   `envoy.filters.http.ext_proc.ipp` with Istio's static filter config (the
   `value` printed by `scripts/epp-order-workaround.sh render`). Unconditional:
   the anchor is MaaS's own filter name, so the result is the same in all
   three anchor modes (WasmPlugin, raw wasm, router fallback), and on a gateway
   without a pool the REMOVE matches nothing and the inserted filter, every
   mode `SKIP`, never opens a stream, which is Istio's own placement on
   non-pool routes today. Works unchanged with praxis-extproc, whose ODH
   overlay inserts the same two filter names
   ([`envoy-filter.yaml`](https://github.com/opendatahub-io/praxis-extproc/blob/0fe8f9dff6cd3477f27df35c1aab0c24592f5e39/deploy/overlays/odh/envoy-filter.yaml#L212-L244)).
2. `tenantreconcile/params.go` `patchPayloadProcessingEnvoyFilter`
   ([L1003](https://github.com/opendatahub-io/models-as-a-service/blob/3457194a4d3e612a55ee1a6cfb0f5df39bb8137a/maas-controller/pkg/platform/tenantreconcile/params.go#L1003)):
   the patch slice gains the two constant patches between the router-fallback
   pair and the route disables; `wasmFilterPatchCount` and
   `routerFallbackPatchCount` unchanged; the mode switch must keep them in
   every mode. Cases in `params_test.go` for all three modes.
3. `scripts/check-payload-ext-proc-filters.sh`: assert
   `pre < auth < ipp < envoy.filters.http.ext_proc < router` whenever the
   InferencePool filter is present and drop the `spec.targetRefs` assertion.
   `scripts/epp-order-workaround.sh status` is the same check, usable as is.
4. Pin the copied config: an e2e reads the gateway's config_dump and compares
   the re-inserted typed_config with the one Istio rendered elsewhere in the
   chain, so an Istio bump that changes it fails loudly instead of silently
   changing timeouts.

Not needed: changes to the EPP, IPP, praxis-extproc or KServe. The Envoy fix
(#45355) is not a substitute either: OSSM 1.26 ships Envoy 1.34, which will not
get it, and the ordering fix is what restores the EPP and auth-before-EPP; it
also makes MaaS immune to the race on every proxy in the table above.
Follow-ups elsewhere: Kuadrant (placement regression since 1.5, scheduling
before auth and rate limiting for every Istio-native InferencePool user), OSSM
(consume an Envoy with #45355), the IPP hub-mode README and the praxis-extproc
overlay comment (the "`INSERT_BEFORE` auth" recipe needs "and the
InferencePool filter after `ipp`").

### E2E tests MaaS should carry

Every one goes through a pool route with a TokenRateLimitPolicy, from outside
the mesh, and reads the payload: a status code is not a pass. Parameterise the
payload processor (IPP today, praxis-extproc tomorrow) and key the checks on
the filter names `envoy.filters.http.ext_proc.ipp-pre` / `.ipp`, on the EPP
counters and on the access log, never on which implementation answers.

1. Chain order: config_dump of the gateway pod; every HTTP chain has
   `ipp-pre < auth < ipp < envoy.filters.http.ext_proc < router`, exactly one
   of each, and the re-inserted typed_config equals Istio's.
2. EPP engaged: N JSON completions, each `200` with a non-empty
   `choices[0].message.content` and a consistent `usage`; picker counter +N;
   access-log `ep_requested` set and equal to `upstream_host` on every line.
3. Streamed completion: `text/event-stream`, events, `data: [DONE]`, clean
   termination; picker +1.
4. Burst: same-prefix requests, concurrently; all complete. The distribution
   is an observation, not a gate.
5. Auth before scheduling: no credentials and a bad key both give `401`,
   picker +0, no `ep_requested`.
6. Token accounting: sum of `usage.total_tokens` equals Limitador's charge;
   after exhausting a quota, `429` with picker +0.
7. No-pool gateway: the EnvoyFilter renders, the chain has no InferencePool
   filter, ExternalModel traffic unaffected.
8. Negative control, kind only: apply the `pre-only` order and require the
   empty-body defect, so the suite proves it can see it.

## Related upstream reports

Checked 2026-09-23.

- [Envoy #45355](https://github.com/envoyproxy/envoy/pull/45355), the fix for
  this defect (see "Why the first fix empties responses"), with Adam
  Cattermole's reproducer [envoy-eos-pause](https://github.com/adam-cattermole/envoy-eos-pause);
  in Envoy v1.37.6, v1.38.4, v1.39.1; istio/proxyv2 1.29.8 is the first Istio
  1.29 proxy with it. RHOAIENG-94419 tracks the MaaS symptom.
- [Envoy #43175](https://github.com/envoyproxy/envoy/pull/43175) for
  [#41654](https://github.com/envoyproxy/envoy/issues/41654), two ext_proc
  filters in one chain: in the tested proxy (runtime guard string present in
  the binary), does not cover this case.
- [Envoy #46841](https://github.com/envoyproxy/envoy/issues/46841), buffered
  body lost when a wasm filter continues, reported with Kuadrant wasm and
  full-duplex ext_proc: the closest report. Its fix
  ([#46842](https://github.com/envoyproxy/envoy/pull/46842), Envoy 1.37.6) is
  absent from the tested proxy (guard
  `filter_manager_forward_added_data_on_continue` not in the binary), but it
  handles a filter that returns Continue after draining a frame, while the
  wasm-shim here returns Pause on the end-of-stream frame. Unlikely to be the
  same defect; not tested against this reproducer.
- [Envoy #43983](https://github.com/envoyproxy/envoy/issues/43983), two
  full-duplex body processors: same family.
- [wasm-shim #388](https://github.com/Kuadrant/wasm-shim/issues/388) (large
  request bodies, `allow_on_headers_stop_iteration`) and
  [wasm-shim #425](https://github.com/Kuadrant/wasm-shim/issues/425) (TRLP
  hanging on upstream errors): different triggers; this failure is on
  successful model responses.

## References

- MaaS EnvoyFilter: https://github.com/opendatahub-io/models-as-a-service/blob/fdaa979a3586c759206368939f87895ef915cbc7/deployment/base/payload-processing/manager/envoy-filter.yaml#L80-L95
- MaaS renderer: https://github.com/opendatahub-io/models-as-a-service/blob/3457194a4d3e612a55ee1a6cfb0f5df39bb8137a/maas-controller/pkg/platform/tenantreconcile/params.go#L1003
- MaaS filter-order check (asserts `pre < auth < ipp < router` only): https://github.com/opendatahub-io/models-as-a-service/blob/fdaa979a3586c759206368939f87895ef915cbc7/scripts/check-payload-ext-proc-filters.sh#L145-L157
- Istio base chain order (OSSM release-1.26): https://github.com/openshift-service-mesh/istio/blob/db8b9e53e8897459c5a309148a61d3166128e185/pilot/pkg/networking/core/listener_builder.go#L399-L416
- Istio InferencePool filter: https://github.com/openshift-service-mesh/istio/blob/db8b9e53e8897459c5a309148a61d3166128e185/pilot/pkg/xds/filters/filters.go#L163-L177
- Envoy ext_proc per-route merge, once in decodeHeaders: https://github.com/envoyproxy/envoy/blob/v1.34.14/source/extensions/filters/http/ext_proc/ext_proc.cc#L540-L542
- Envoy header-reply continue in full-duplex mode, before the fix: https://github.com/envoyproxy/envoy/blob/v1.37.5/source/extensions/filters/http/ext_proc/processor_state.cc#L251-L255 (v1.34.14: https://github.com/envoyproxy/envoy/blob/v1.34.14/source/extensions/filters/http/ext_proc/processor_state.cc#L233-L237)
- Envoy fix, "ext-proc: remove unnecessary continueIfNecessary()": https://github.com/envoyproxy/envoy/pull/45355
- Kuadrant reproducer for the same trace: https://github.com/adam-cattermole/envoy-eos-pause
- Envoy filter manager `commonContinue`: https://github.com/envoyproxy/envoy/blob/c5320a6f4e6ff60c4ae33d1c08882092c5c0bd2a/source/common/http/filter_manager.cc#L107-L133
- Kuadrant wasm-shim response-body pause: https://github.com/Kuadrant/wasm-shim/blob/222a42a812e23d5864e3239570c72559b77c5887/crates/wasm-shim/src/filter/kuadrant_filter.rs#L189-L218
- Kuadrant switch to EnvoyFilter injection (first in v1.5.0): https://github.com/Kuadrant/kuadrant-operator/pull/1953
- RHCL 1.4 release notes ("migrated from an Istio WasmPlugin to EnvoyFilter"): https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html-single/release_notes/index
- IPP hub-mode README (the "INSERT_BEFORE auth" recipe): https://github.com/opendatahub-io/ai-gateway-payload-processing/blob/07727563b63153c410434a20b62f3ebc5f24ed01/deploy/examples/hub-mode/README.md#L10-L28
- praxis-extproc ODH overlay (same filter names and anchors): https://github.com/opendatahub-io/praxis-extproc/blob/0fe8f9dff6cd3477f27df35c1aab0c24592f5e39/deploy/overlays/odh/envoy-filter.yaml#L212-L244
