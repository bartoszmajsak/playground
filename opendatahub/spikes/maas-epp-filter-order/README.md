# MaaS / EPP filter ordering

This spike reproduces two separate problems with Istio-native InferencePools
and Kuadrant's router-anchored Wasm filter:

- **EPP is bypassed.** It runs before `ipp-pre` extracts the model from the
  request body, so its per-route picker configuration is missed. Requests
  succeed through ordinary pool load balancing, without an EPP call.
- **The first ordering fix exposes empty responses.** Moving only `ipp-pre`
  before EPP engages the picker, but with TokenRateLimitPolicy (TRLP) enabled,
  completions can return empty HTTP 200 bodies and SSE can fail to finish.
  Removing TRLP clears the response failure but does not fix the original bypass.

**Why Kuadrant 1.5 exposes this:** Kuadrant 1.4 used a WasmPlugin, placing auth
before EPP. Version 1.5 uses an EnvoyFilter inserted before the router, after
EPP. MaaS anchors `ipp-pre` to auth, so it also lands after EPP, too late to
supply the model header. See the [version comparison](docs/investigation.md#why-the-order-is-wrong).

**The validated workaround moves EPP after `ipp`, with authentication and token
rate limiting before EPP.**

```text
Original:   EPP → ipp-pre → Kuadrant → ipp → router
Superseded: ipp-pre → EPP → Kuadrant → ipp → router
Validated:  ipp-pre → Kuadrant → ipp → EPP → router
```

Here, EPP is `envoy.filters.http.ext_proc`, and Kuadrant is its authentication /
token-rate-limiting Wasm filter. Responses traverse the chain in reverse.
The EPP-before-auth concern applies only to the superseded `pre-only` fix.

## What we verified

Fresh kind cluster, 2026-09-23: **Istio 1.29.2 / Envoy 1.37.2-dev, Kuadrant
1.5.3**, MaaS, IPP, llm-d EPP v0.10.0, and three real vLLM CPU replicas.

| Order | TRLP | Requests / EPP picks | Complete responses |
|---|---|---:|---:|
| Original | Enabled | 38 / 0 | 38 |
| Superseded `pre-only` | Enabled | 38 / 38 | 1 |
| Original | Removed | 38 / 0 | 38 |
| Superseded `pre-only` | Removed | 38 / 38 | 38 |
| Superseded `pre-only` | Restored | 3 / 3 | 0 |
| **EPP after IPP** | **Enabled** | **60 / 60** | **60** |

The final order also passed:

- Six streamed and six fragmented-body requests, plus a concurrent 12-request
  burst. Every EPP-selected endpoint matched the actual upstream.
- Twenty missing/invalid-credential requests: 401, with no EPP or model call.
- Exact accounting: 189 response tokens charged as 189 tokens by Limitador.
- Five requests after quota exhaustion: 429, with no EPP or model call.

The general validation suite separately passed **nine phases / 220 requests**,
including the expected failures. See the [run log](results/verification-20260923/validate.out),
[versions](results/verification-20260923/versions.txt), and
[detailed evidence](docs/findings.md).

**Limit:** the reported cluster uses Istio 1.26.8 / Envoy 1.34.14. Its dumps have
the same faulty order on ports 80 and 443, but this spike has not validated the
workaround's runtime behavior on that exact proxy build.

## Apply or revert the workaround

On the spike cluster:

```bash
./fix.sh apply
./fix.sh status
./fix.sh revert
```

The default (`FIX_VARIANT=epp-after-ipp`) creates a **separate EnvoyFilter**,
`payload-processing-epp-order`. It copies the live EPP configuration, removes
EPP from its original position, and reinserts it after `ipp`. It leaves the
controller-owned MaaS resource and per-route picker overrides unchanged.
Revert deletes the separate resource.

For another cluster, use the [standalone script and raw YAML in the gist](https://gist.github.com/bartoszmajsak/d48011aeefcce424d560b1cad816d91e).
The gist creates `maas-epp-after-ipp-workaround` instead. Its script copies live
configuration; the raw YAML is specific to the inspected `openshift-ingress` /
`maas-default-gateway` dump and assumes MaaS filter priority 10.

To render from this checkout against another gateway without applying:

```bash
KUBECONFIG=/path/to/target-kubeconfig KUBECTL=oc \
  GATEWAY_NAMESPACE=openshift-ingress GATEWAY_NAME=maas-default-gateway \
  ./scripts/render-fix.sh /tmp/maas-epp-order.yaml
```

## Check the result

Read the live chain, or inspect a saved full Envoy dump:

```bash
./scripts/check-filter-order.sh
./scripts/check-filter-order.sh --dump config_dump.json --listener-port 443
```

Check every relevant listener and gateway replica. The required relative order is:

```text
envoy.filters.http.ext_proc.ipp-pre
envoy.filters.http.wasm                   # or the Kuadrant WasmPlugin name
envoy.filters.http.ext_proc.ipp
envoy.filters.http.ext_proc               # EPP
envoy.filters.http.router
```

**A correct order or HTTP 200 alone does not prove working inference.** Verify
nonempty normal responses, complete SSE, EPP picks matching actual upstreams,
authentication rejection before EPP, and token accounting / quota enforcement.
An `EPP_ENGAGED=OK` diagnostic checks a prerequisite; it is not a traffic test.

## Reproduce locally

Use a **disposable kind cluster**. Set `MAAS_REPO` to a local MaaS checkout;
component versions, images, and cluster settings are in [lib.sh](lib.sh).
`setup.sh` checks the required tools. The default backend is real vLLM CPU.

```bash
export MAAS_REPO=/path/to/models-as-a-service
./setup.sh
./validate.sh                         # bypass, TRLP isolation, fix, authentication
./validate.sh --smoke                 # smaller run; still exercises SSE and bursts
./validate.sh --scenario trlp         # policies present → absent → restored
./validate.sh --scenario fix          # complete responses, accounting, then revert
./validate.sh --scenario auth         # missing / invalid credentials
./setup.sh --teardown
```

The TRLP scenario briefly pauses MaaS reconciliation and removes both the model
and inherited gateway token policies. It restores them on exit and requires
the empty-response defect to return under the superseded order. Expected
failures count as passes only in those explicit reproducer phases.

Runs retain raw bodies, configurations, policy snapshots, metrics, logs, and
scores in separate results directories. See [validation details](docs/validation.md)
for restoration behavior, overrides, diagnostic scenarios, and scorer tests.

## Other findings

- **The empty-body problem has an upstream fix.**
  [Envoy #45355](https://github.com/envoyproxy/envoy/pull/45355) removes a premature
  continuation in chained ext_proc processing. The [investigation](docs/investigation.md#why-the-first-fix-empties-responses)
  records the matching trace and affected proxy sources. Proxy-upgrade validation
  was not run here; the ordering fix is still needed for EPP selection and auth.
- **Deleting only the model TRLP is not a no-TRLP control:** the gateway's
  inherited default-deny policy can return 429. The controller can recreate
  deleted policies, which is why the reproducer checks live configuration.
- **Moving `ipp` before authentication breaks credentials:** its header guard
  removes `Authorization`. The `extproc` variant does this; it is not a workaround.
- **Skipping EPP response processing loses token/latency metrics.** The final
  ordering preserves them. Backend distribution alone proves neither EPP use
  nor a cache-performance improvement.
- Older validator logs that accepted empty HTTP 200 responses are insufficient
  evidence. Current checks parse bodies and correlate every request with EPP
  and gateway records.

For the source-level explanation, version comparison, proposed permanent MaaS
fix, and regression-test requirements, see [the investigation](docs/investigation.md).
