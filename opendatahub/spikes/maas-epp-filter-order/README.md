# MaaS, EPP and token-rate-limit filter ordering

This spike reproduces two failures on a MaaS gateway with Istio-native
InferencePools and Kuadrant's router-anchored Wasm filter:

1. **EPP bypass:** the picker filter runs before `ipp-pre` extracts
   `X-Gateway-Model-Name` from the request body. Its per-route configuration is
   resolved before the model route matches. Requests reach the pool through
   ordinary load balancing, without an EPP call.
2. **Empty responses after the first ordering fix:** moving only `ipp-pre`
   before EPP engages the picker, but with TokenRateLimitPolicy (TRLP) enabled,
   ordinary completions return HTTP 200 with empty bodies and SSE can hang.
   Removing TRLP restores complete responses; restoring TRLP restores the failure.

The working workaround moves **EPP after `ipp`**, preserving both MaaS stages,
authentication, token accounting and all response processing.

```text
Original request order:
EPP -> ipp-pre -> Kuadrant auth/token rate limiting -> ipp -> router

Earlier, incomplete fix:
ipp-pre -> EPP -> Kuadrant auth/token rate limiting -> ipp -> router

Validated workaround:
ipp-pre -> Kuadrant auth/token rate limiting -> ipp -> EPP -> router
```

Responses traverse these filters in reverse. In the workaround, EPP processes
the response before IPP and Kuadrant. Both order changes preserve the native
EPP configuration and Istio's per-route picker overrides.

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
   full-duplex branch and continues
   ([`processor_state.cc`](https://github.com/envoyproxy/envoy/blob/c5320a6f4e6ff60c4ae33d1c08882092c5c0bd2a/source/extensions/filters/http/ext_proc/processor_state.cc#L239-L260)).
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

Envoy's [#43175](https://github.com/envoyproxy/envoy/pull/43175) (issue
[#41654](https://github.com/envoyproxy/envoy/issues/41654)) is in this proxy
build (`envoy.reloadable_features.ext_proc_inject_data_with_state_update` is
in the binary) and does not cover it: the flag it corrects is current here,
the frame is genuinely parked by a filter between the two ext_procs.
Production OSSM 1.26.8 / Envoy 1.34.14 lacks even that.

The rule that follows: the Kuadrant wasm has to sit before the InferencePool
filter in the chain. That is auth before scheduling, and on the response path
the wasm then pauses behind the EPP filter, which has already seen
end-of-stream. Kuadrant 1.4 had this order for free.

## Measured results

Fresh kind cluster, 2026-09-23: Istio 1.29.2 / Envoy 1.37.2-dev, Kuadrant 1.5.3,
MaaS, IPP, llm-d EPP v0.10.0 and three real vLLM CPU replicas serving tiny-llama.

| Configuration | Requests | EPP picks | Complete inference responses |
|---|---:|---:|---:|
| Original order, TRLP enabled | 38 | 0 | 38 |
| Earlier pre-only fix, TRLP enabled | 38 | 38 | 1; 35 empty non-SSE responses, two SSE timeouts |
| Original order, TRLP removed | 38 | 0 | 38 |
| Earlier pre-only fix, TRLP removed | 38 | 38 | 38 |
| Earlier pre-only fix, TRLP restored | 3 | 3 | 0; all empty HTTP 200 |
| EPP after IPP, TRLP enabled | 60 | 60 | 60 |

The last row includes six SSE requests, six fragmented request bodies and a
12-request burst at concurrency six. Every EPP pick matched the actual upstream.
Twenty requests with missing/invalid credentials returned 401 before EPP or any
model was reached. A seven-request accounting check returned 189 tokens in total;
Limitador charged exactly 189. After exhausting a one-token quota, five subsequent
requests returned 429 without reaching EPP; restoring the quota restored inference.

Configuration comparisons confirm that the ordering experiments change only
filter positions. The TRLP comparisons keep routes and filter order identical;
only Kuadrant's Wasm configuration changes. The mechanism behind the
interaction is in "Why the first fix empties responses" above.

The revised default suite also passed all nine phases (220 requests), including
the expected TRLP failures. Its final-order phase returned 34 complete responses
and charged exactly 7,034 tokens. See the [recorded run](results/verification-20260923/validate.out)
and [versions](results/verification-20260923/versions.txt).

## Setup and validation

```bash
./setup.sh                              # kind + the real MaaS/KServe/vLLM stack
./validate.sh                          # default: defect, TRLP isolation, fix, auth
./validate.sh --smoke                   # fewer ordinary requests; retains SSE/fragment/burst checks
./validate.sh --scenario trlp           # TRLP present -> absent -> restored
./validate.sh --scenario fix            # final order, accounting, then revert and verify bypass
./validate.sh --scenario auth           # missing and invalid credentials with the final order
./validate.sh --scenario auth-order     # demonstrate EPP-before-auth cost of the earlier fix
./setup.sh --teardown
```

Use a **disposable kind cluster** for general validation. The `trlp` scenario:

1. Applies the earlier pre-only order and requires an empty HTTP 200 completion.
2. Saves the model and inherited gateway TRLPs, pauses MaaS reconciliation, and
   deletes those policies. Authentication remains enabled.
3. Waits until their references disappear from the live Wasm configuration.
4. Requires complete ordinary, SSE, fragmented and concurrent responses with EPP
   engaged; then verifies that the original order still bypasses EPP without TRLP.
5. Restores policies and controller replicas, reapplies the pre-only order, and
   requires the empty-response defect to return.

An expected defect counts as a passing reproducer only in the explicit
`trlp-present` and `trlp-restored` phases. Successful inference phases reject empty
or malformed bodies, wrong model names, unfinished SSE, failed burst requests,
missing/duplicate access records and picks that differ from the actual upstream.
Every request, including SSE and bursts, is included in EPP counters and logs.
The scorer reparses retained bodies rather than trusting a precomputed result.

The `fix` phase additionally compares response usage with Limitador counters.
Pod identities/restarts and configuration comparisons guard against confounded
results. Distribution and cache statistics are observations, not pass criteria.
The general suite checks accounting; the quota-exhaustion experiment above was a
separate check. It does not silently turn off enforcement to make inference pass.

Each run writes a new `results/<versions+backend>/validation-<timestamp>-<pid>/`:
raw responses, request records, proxy configuration, policy snapshots, EPP/vLLM
metrics, gateway/EPP logs, per-phase scores, and `validate.out`. `images.json` and
`server-info.json` record the running binaries. The run restores temporary filters,
policies and controller replicas even on failure; `--keep-fix` leaves the final
order applied only after a successful run. Previous evidence is retained.

Configuration comes from `lib.sh`: `KUBECONFIG`, `CLUSTER_NAME`, `NS`,
`GATEWAY_NAMESPACE`, `GATEWAY_NAME`, `RESULTS`, `REQUESTS`, `PREFIX_REQUESTS`,
`PREFIX_CONCURRENCY`, `MAAS_REPO`, and the component versions/images. The default
backend is vLLM CPU. `MODEL_BACKEND=sim` selects the simulator; the complete-response
and accounting checks still apply. Installer adjustments are in
[`patches/local-deploy.upstream.diff`](patches/local-deploy.upstream.diff).

Scorer regression tests:

```bash
python3 -m unittest discover -s tests -v
```

## Applying the workaround

```bash
./fix.sh apply                         # default: FIX_VARIANT=epp-after-ipp
./fix.sh status
./fix.sh revert
```

[`scripts/render-fix.sh`](scripts/render-fix.sh) copies the **live native EPP
typed configuration** from the proxy and renders a separate EnvoyFilter at the
MaaS filter's priority + 10. It removes native EPP and reinserts it after `ipp`.
It rejects missing anchors, inconsistent native configurations across listeners,
and an unscoped workload selector. The controller-owned MaaS resource is not edited.

For another gateway, render and inspect the patch against that gateway first:

```bash
KUBECONFIG=/path/to/target-kubeconfig KUBECTL=oc \
  GATEWAY_NAMESPACE=openshift-ingress GATEWAY_NAME=<gateway> \
  ./scripts/render-fix.sh /tmp/maas-epp-order.yaml
# Apply with the intended kubeconfig/context; delete payload-processing-epp-order to revert.
```

`FIX_VARIANT=pre-only` and `first` retain the earlier response defect in this
stack. `extproc` also moves IPP ahead of auth and breaks valid authentication:
`maas-headers-guard` removes `Authorization`. They remain diagnostic variants.

For a cluster without this checkout,
[`scripts/epp-order-workaround.sh`](scripts/epp-order-workaround.sh) is the
same change as one file: `oc`/`kubectl` plus `jq`, a static EnvoyFilter
(Istio's filter config is identical on OSSM 1.26.8 and Istio 1.29.2, and the
script refuses to apply if the live one differs), `status` per listener, the
same `status` offline against a saved config_dump, `apply`, `revert`. Measured
on kind (`results/kuadrant-1.5.3+istio-1.29.2+vllm-cpu/epp-after-ipp-probe/`):
33/33 picks, 20/20 JSON bodies, 12/12 burst, SSE to `[DONE]`, 401 with 0 picks
without credentials, revert restores the old chain.

```bash
export KUBECTL=oc GATEWAY_NAMESPACE=openshift-ingress GATEWAY_NAME=maas-default-gateway
./scripts/epp-order-workaround.sh status
./scripts/epp-order-workaround.sh apply
./scripts/epp-order-workaround.sh revert
DUMP_FILE=~/Downloads/dump.txt ./scripts/epp-order-workaround.sh status   # no cluster access needed
```

The standalone diagnostic also reads saved dumps:

```bash
./scripts/check-filter-order.sh
./scripts/check-filter-order.sh --dump dump.json --listener-port 443
```

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

Not needed: changes to the EPP, IPP, praxis-extproc or KServe. Follow-ups
elsewhere: Kuadrant (placement regression since 1.5, scheduling before auth
and rate limiting for every Istio-native InferencePool user), Envoy
(filter-manager report with the debug log above), the IPP hub-mode README and
the praxis-extproc overlay comment (the "`INSERT_BEFORE` auth" recipe needs
"and the InferencePool filter after `ipp`").

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

## Other observations and limits

- Removing TRLP alone does not fix EPP bypass: 38 requests still made zero EPP
  calls and distributed 13/13/12 across the backends.
- Deleting only the model TRLP exposes the gateway's inherited default-deny
  token policy and returns 429. A no-TRLP experiment must account for inheritance
  and prevent the MaaS controller from recreating the deleted policy.
- Supplying the model header directly engages EPP in the original order, but
  still exposes the response failure. The publisher-prefixed URL control returned
  403 from subscription model extraction, so it is not a demonstrated workaround.
- Skipping EPP response callbacks restored seven responses, but removed EPP
  response-derived token/latency metrics. Moving EPP after IPP preserves those
  observations and leaves running-request gauges at zero after completion.
- The original validator reported success for empty HTTP 200 responses. Its
  older saved success logs do not prove working inference. Backend concentration
  also does not establish a cache-efficiency or performance improvement.
- The production dump uses Istio 1.26.8 / Envoy 1.34.14. Its bypassing order matches,
  but this workaround still needs testing on that exact proxy. Kuadrant 1.4's
  WasmPlugin placement is a source-based comparison, not a measured control here.

## Related upstream reports

Checked 2026-09-23.

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
- Envoy header-reply continue in full-duplex mode (istio/proxy release-1.29 pin): https://github.com/envoyproxy/envoy/blob/c5320a6f4e6ff60c4ae33d1c08882092c5c0bd2a/source/extensions/filters/http/ext_proc/processor_state.cc#L239-L260
- Envoy filter manager `commonContinue`: https://github.com/envoyproxy/envoy/blob/c5320a6f4e6ff60c4ae33d1c08882092c5c0bd2a/source/common/http/filter_manager.cc#L107-L133
- Kuadrant wasm-shim response-body pause: https://github.com/Kuadrant/wasm-shim/blob/222a42a812e23d5864e3239570c72559b77c5887/crates/wasm-shim/src/filter/kuadrant_filter.rs#L189-L218
- Kuadrant switch to EnvoyFilter injection (first in v1.5.0): https://github.com/Kuadrant/kuadrant-operator/pull/1953
- RHCL 1.4 release notes ("migrated from an Istio WasmPlugin to EnvoyFilter"): https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html-single/release_notes/index
- IPP hub-mode README (the "INSERT_BEFORE auth" recipe): https://github.com/opendatahub-io/ai-gateway-payload-processing/blob/07727563b63153c410434a20b62f3ebc5f24ed01/deploy/examples/hub-mode/README.md#L10-L28
- praxis-extproc ODH overlay (same filter names and anchors): https://github.com/opendatahub-io/praxis-extproc/blob/0fe8f9dff6cd3477f27df35c1aab0c24592f5e39/deploy/overlays/odh/envoy-filter.yaml#L212-L244
