# Body-Based Routing Spike

OpenAI clients put the model name in the JSON body. Gateways route on headers.
So to send `{"model": "llama-3-8b"}` somewhere different from
`{"model": "mistral-7b"}`, something has to read the payload first.

The usual answer is an ext_proc service - [GIE's body-based-router](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/v1.2.1/cmd/bbr)
(BBR), now succeeded by [llm-d's Inference Payload Processor](https://github.com/llm-d/llm-d-inference-payload-processor)
(IPP). It works, but it is a pod to run, an extra hop on every request, and a
thing to operate.

Can Envoy do it alone? Yes, two ways, and the choice comes down to one question:
can you live with the gateway buffering the whole request body?

| | how | streams the body |
|---|---|---|
| `json_to_metadata` + `header_mutation` | config, via `EnvoyFilter` | no, buffers all of it |
| proxy-wasm module | a compiled `.wasm` artifact | yes |

Both inject `X-Gateway-Model-Name` *and* steer route matching from the payload
alone. No ext_proc, no extra pod, no extra hop.

## How it works

Setting a header from the body means holding the headers until you have seen
enough body - once headers reach the router they are frozen.

`json_to_metadata` parses the body into dynamic metadata, which is not a header
and so buys you telemetry and rate-limit descriptors, nothing the backend sees.
The trick is a timing detail: when a body is expected its `decodeHeaders`
returns `StopIteration`, so filters *after* it see headers only once the body is
parsed. A `header_mutation` filter behind it can then read
`%DYNAMIC_METADATA(llm:model)%` into a real header. `json_to_metadata` also
clears the route cache when it writes metadata, which is what lets the router
re-match on the injected header.

```
   lua (strip + clearRouteCache)
        |
   json_to_metadata      <- buffers body, {"model": "x"} -> metadata llm.model
        |                   holds headers until the body is parsed
   header_mutation       <- metadata -> X-Gateway-Model-Name
        |
   router                <- re-matches the route, now sees the header
```

Finding 1 covers why the Lua filter is in that chain.

## What's here

| Path | What it is |
|---|---|
| `profiles/*.yaml` | **The source of truth.** One `http_filters` list per design. |
| `profiles/_base.yaml` | Envoy bootstrap the profiles get spliced into for `--docker`. |
| `profiles/wasm-module/` | Rust proxy-wasm source for the `wasm` profile. |
| `render-envoyfilter.sh` | Wraps a profile's filters into Istio `EnvoyFilter` patches. |
| `manifests/envoyfilter.yaml` | Committed output of the above, for the default profile. |
| `manifests/workloads.yaml` | Two echo backends, and an HTTPRoute matching `X-Gateway-Model-Name: model-b`. |
| `setup.sh` | kind + MetalLB + Gateway API + Istio + a Gateway. |
| `build-wasm.sh` | Builds the wasm module in a container. No local toolchain needed. |
| `validate.sh` | One test matrix, run in-cluster or against Envoy in Docker. |

The echo backends reflect the request they received, so "did the header arrive"
is directly observable. Nobody sends `X-Gateway-Model-Name`, so if a request
carrying `{"model": "model-b"}` and no headers lands on `echo-b`, the payload
alone steered the route. That is the whole test.

**Why render the EnvoyFilter instead of copying the filters?** The same list
needs two shapes: an Envoy bootstrap wants a plain `http_filters:` list, an
`EnvoyFilter` wants each filter wrapped in its own `INSERT_BEFORE`-the-router
`configPatch`. Copying means eight hand-maintained files (four profiles x two
shapes) that drift the moment anyone edits one. One source plus a 40-line
transform means `--profile X` is the same chain in both modes - and the
comparison below is only worth anything if that holds.

## Running it

```bash
./validate.sh --docker            # fast loop, no cluster, ~20s

./setup.sh                        # kind + Istio
./validate.sh                     # same matrix, through Istio

./validate.sh --profile lua       # any profile, either mode
./validate.sh --size 8,30,40      # payloads either side of the buffer limit

./build-wasm.sh
./validate.sh --all --buffer 1 --size 2    # compare every design

./validate.sh --help
kind delete cluster --name bbr-spike
```

`--docker` is the fast path. If it fails, the Envoy config is wrong
and there is no point booting kind. If it passes and `--cluster` fails, the
problem is Istio's EnvoyFilter translation, not the filters.

`setup.sh` registers a normal kube context, so you can poke around without the
scoped kubeconfig:

```bash
GW=$(kubectl --context kind-bbr-spike -n bbr-spike \
      get gateway spike-gateway -o jsonpath='{.status.addresses[0].value}')

# Extraction - the echo backend reflects what it received.
curl -s http://$GW/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"llama-3-8b-instruct","messages":[]}' \
  | jq '.headers["x-gateway-model-name"]'          # "llama-3-8b-instruct"

# Routing - no headers sent, the payload picks the backend.
curl -si http://$GW/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"model-b","messages":[]}' | grep x-served-by   # echo-b

# Spoofing - the body wins.
curl -s http://$GW/v1/chat/completions -H 'Content-Type: application/json' \
  -H 'X-Gateway-Model-Name: something-else' \
  -d '{"model":"model-a","messages":[]}' \
  | jq '.headers["x-gateway-model-name"]'          # "model-a"
```

## Findings

Measured on `istio/proxyv2:1.28.1` (Envoy 1.36.3-dev), in-cluster on kind and
standalone in Docker.

`json_to_metadata`, `header_mutation`, `lua`, `wasm` and `golang` are all
compiled into the Istio proxy build - that was the main unknown going in. The
proxy prints its extension list at `--log-level info`, which is the cheap way to
check before betting on one.

### The comparison

`./validate.sh --all --buffer 1 --size 2` - every design at Envoy's **default**
1MiB buffer limit, with a 2MiB payload:

```
  profile          injects   routes  spoofproof  nested  big payload
  ----------------------------------------------------------------------
  metadata-filter  yes       yes     yes         yes     HTTP 413
  lua              yes       yes     yes         no      HTTP 413
  lua-body-chunks  no        no      yes         no      yes
  wasm             yes       yes     yes         yes     yes
```

| column | what it asserts |
|---|---|
| `injects` | the model name from the body reaches the backend as `X-Gateway-Model-Name` |
| `routes` | the payload alone selects the backend, so route matching re-ran on the injected header |
| `spoofproof` | a client-supplied header cannot inject or steer, including on requests the filter skips (finding 1) |
| `nested` | a decoy `model` key in a nested object cannot steer (finding 2) |
| `big payload` | what a payload larger than the buffer limit gets |

Every profile also runs in-cluster and reproduces this exactly, including
`lua-body-chunks` failing to inject and `wasm` serving 2MiB at a 1MiB limit.
Whatever these designs do, they do the same through Istio as on bare Envoy.

### Each path in one paragraph

**`metadata-filter`** - `json_to_metadata` + `header_mutation`, with `lua` in
front to strip and re-route. Works. Config only, nothing to build or ship, and a
real JSON parser underneath so nested decoys do not steer it. Buffers the whole
body in Envoy's connection buffer, so anything above
`per_connection_buffer_limit_bytes` gets a 413 and that limit has to be raised to
fit real traffic. Memory is bounded per connection and back-pressured. Use for
text-only inference up to ~256k context.

**`lua`** - `handle:body()`, no `json_to_metadata`. Works, and needs one
extension instead of three. Same full-body buffering, same 413 ceiling. The JSON
parse is a `string.match` regex that a nested decoy defeats, and Envoy's Lua has
no JSON parser available to fix it. Strictly more fragile than
`metadata-filter` for the same cost, so there is no reason to choose it.

**`lua-body-chunks`** - `handle:bodyChunks()`. Does not work. Streams the body
with no buffering, but header injection is refused: iterating chunks releases the
headers before the first chunk arrives. Fails silently - HTTP 200, no header, and
only the proxy log says why. Kept as a profile so the failure stays reproducible.

**`wasm`** - compiled proxy-wasm module. Works, and the only path that acts on a
prefix of the body rather than all of it, so a 2MiB payload passes at the default
1MiB limit. Costs a `.wasm` artifact to build, ship and version, needs
`allow_on_headers_stop_iteration` and Envoy >= 1.35, and needs a scan cap because
the VM shares the proxy's memory budget. Use for million-token context or
multimodal.

**ext_proc** - BBR, now IPP. Not implemented here; assessed from its source.
Works, and is the only path where the logic is a normal program with normal
tests. Costs a pod and a network hop on every request. Does not avoid buffering -
it accumulates the whole body in the processor, without an upper bound, so the
failure mode is an OOM in that pod rather than a 413 at the gateway. Use when the
logic outgrows a single field lookup.

The pattern behind the table: to set a header from the body you must hold the
headers, and to dodge the buffer ceiling you must release each chunk as it
arrives. Nothing in Envoy forbids both - `StopIteration` on headers, inspect the
first chunk in `decodeData`, set the header, `Continue`. What can't do both is
anything expressed purely in **config**. The split is compiled vs configured,
not in-proxy vs external.

### 1. The naive config is spoofable, and stripping the header is not enough

Envoy resolves the route *before* any filter runs. Send
`X-Gateway-Model-Name: model-b` with `Content-Type: text/plain`, or JSON with no
`model` field, and `json_to_metadata` skips the request entirely - never writes
metadata, so never clears the route cache. The client's header picks the
backend. Removing the header in a filter does not help: the route was already
decided.

Hence the Lua filter in front, which removes the header *and* clears the cache.
That knob is not exposed by `header_mutation`, which is the only reason Lua is
in the chain at all:

```lua
function envoy_on_request(handle)
  handle:headers():remove("x-gateway-model-name")
  handle:clearRouteCache()
end
```

Without it the header never reaches the backend but routing stays
attacker-controlled - the worst kind of half-fix, because from the backend's
point of view everything looks correct.

### 2. "Find the model key" is a JSON problem, not a string-matching one

The client controls the entire body, so it can put a decoy in front of the real
key:

```json
{"x": {"model": "model-b"}, "model": "model-a"}
```

Anything scanning for the *substring* `"model"` finds the decoy first and routes
on it, while the backend serves `model-a`. Both the Lua regex and the wasm
module's original naive scan fell for it. `metadata-filter` never did -
`json_to_metadata` runs a real parser and `selectors: [{key: model}]` is a
top-level lookup, which is a genuine argument for the declarative option.

Prompt text is not a viable carrier: JSON escaping means those bytes arrive as
`\"model\"`, which the substring scan misses. Only the nested *object* needs no
escaping, so a test using a string payload reports a false negative.

The fix is to parse rather than scan. The wasm module now feeds bytes to
[actson](https://github.com/michel-kraemer/actson-rs), a streaming JSON parser,
tracks object depth and only accepts `model` at depth 1. Because parser state
persists across proxy-wasm callbacks it also stops re-scanning the accumulated
buffer on every chunk. `profiles/wasm-module/src/lib.rs` carries unit tests for
the decoy cases, and each one is asserted twice - once on the whole document and
once feeding a byte at a time, so a key split across a chunk boundary cannot
quietly change the answer.

The Lua profile still fails this, and is kept that way deliberately - it is what
"parse JSON with a regex" amounts to, and Envoy's Lua has no JSON parser
available.

### 3. json_to_metadata buffers the whole body and cannot be talked out of it

`model` is the first key in every OpenAI request, so in principle the filter
could stop after a few dozen bytes. It doesn't, and it structurally can't:
[`filter.cc`](https://github.com/envoyproxy/envoy/blob/main/source/extensions/filters/http/json_to_metadata/filter.cc)
returns `StopIterationAndBuffer` from `decodeData` until `end_stream`, then does
a whole-document `Json::Factory::loadFromString` over the complete buffer. Not a
streaming parser that could fire on the first key and bail. The
[`JsonToMetadata` proto](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/json_to_metadata/v3/json_to_metadata.proto.html)
has no max-bytes, partial-buffer or early-exit field either. Every payload the
size tests send has `model` as its *first* key, and they still track the buffer
limit exactly.

Requests the filter *skips* are never buffered at all - `decodeHeaders` returns
`Continue` immediately on a disallowed content-type or a bodyless request, so
the cost lands only on JSON POSTs.

So the ceiling is `per_connection_buffer_limit_bytes`, 1MiB by default. The
`LISTENER` merge patch raises it to 32MiB, and `--size 8,30,40` shows it
enforced exactly where configured: 8MiB and 30MiB pass with the header injected,
40MiB gets a 413.

### 4. So how big do these payloads actually get?

This is the question that picks your design, so it is worth the arithmetic. The
body is dominated by the prompt, at roughly 4 chars per token for English prose.
A **completely full** context window, text only:

| context | model it belongs to | approx body | 1MiB | 4MiB | 8MiB | 32MiB |
|---|---|---|:---:|:---:|:---:|:---:|
| 4k | anything | 0.02 MiB | ok | ok | ok | ok |
| 32k | Mistral, older Llama | 0.12 MiB | ok | ok | ok | ok |
| 128k | Llama 3.1, Qwen 2.5, GPT-4o | 0.49 MiB | ok | ok | ok | ok |
| 200k | Claude | 0.76 MiB | ok | ok | ok | ok |
| 256k | Command R+, Jamba | 0.98 MiB | **edge** | ok | ok | ok |
| 512k | GPT-4.1 class | 1.95 MiB | **413** | ok | ok | ok |
| 1M | Gemini 1.5/2.0, Llama 4 Scout | 3.81 MiB | **413** | **edge** | ok | ok |
| 2M | Gemini 1.5 Pro | 7.63 MiB | **413** | **413** | **edge** | ok |

Add vision and it moves fast - a ~1MP JPEG is around 400KiB once base64 has
inflated it by 4/3. 128k text plus one image is 0.88 MiB, plus four is 2.05 MiB,
plus eight is 3.61 MiB.

Two things fall out. First, prose is the *friendly* case: code and JSON tokenize
denser, nearer 3 chars per token, so the same window is ~30% more bytes. Treat
the table as a floor.

Second, 128k text-only is about half a megabyte and fits the 1MiB default with
room to spare - but 256k lands right on it, and a pasted document reaches that
size easily. A few MiB of headroom covers every text-only model there
except the million-token ones, and is nowhere near the 32MiB this spike uses to
make the limit visible in tests.

Multimodal is where it breaks. Four images already blow past 1MiB, audio is
worse, and there is no sane fixed number: a limit big enough for your largest
legitimate request is by definition one an attacker can fill, on every
connection. Which is the other reason to keep it small - it is a *soft limit on
per-connection read and write buffers*, and Envoy's docs recommend `32768`
(32KiB) with untrusted downstreams. The 32MiB here is a thousand times that.

### 5. Lua can do it, but only by buffering too

`handle:body()` works end to end - extraction, routing, spoof resistance - and
413s on exactly the same payloads, because the docs are explicit that it
suspends the script "until the entire body has been received in a buffer". Same
ceiling, and now the JSON parse is a `string.match` regex (Envoy's Lua has no
`cjson`) that will happily match a `model` key nested anywhere in the payload.

`handle:bodyChunks()` streams, so 2MiB sails through at the default limit. But
the header injection is refused, and only the proxy log tells you:

```
[error][lua] script log: ...:11: header map can no longer be modified
```

Breaking out of the loop after the first chunk does not rescue it. Per
[`lua_filter.cc`](https://github.com/envoyproxy/envoy/blob/main/source/extensions/filters/http/lua/lua_filter.cc),
`StreamHandleWrapper::start()` holds headers back for exactly three states -
`WaitForBody`, `HttpCall`, `Responded` - and `bodyChunks()` yields in
`WaitForBodyChunk`, which is none of them. The filter returns `Continue` and
latches a one-way `headers_continued_` flag before you ever see a chunk.

### 6. Wasm does both, behind one required flag

The `wasm` profile pauses on headers, extracts `model` from the first body
chunk, injects the header, clears the route cache, and lets the remaining
megabytes stream past. At the default 1MiB limit a 2.6MB payload is served and
routed correctly, while an identically sized payload with no `model` key gets a
413 - the control proving the limit is real and the success case genuinely is
not buffering.

This requires one additional setting. `Action::Pause` from
`on_http_request_headers` deadlocks the request out of the box: proxy-wasm-cpp-host
rewrites `StopIteration` into `StopAllIterationAndWatermark` for the 0.2.x ABI,
Envoy then buffers data without ever calling `decodeData`, and the request can
never resume because the callback that would resume it is the one being
withheld. `allow_on_headers_stop_iteration: true` in the plugin config disables
the rewrite. It needs **Envoy >= 1.35** - the field is absent in 1.31-1.34, so
on older proxies this is genuinely impossible with proxy-wasm.

Two further constraints, both in `profiles/wasm-module/src/lib.rs`: the Rust SDK has
no route-cache API, so clearing it means the foreign function
`call_foreign_function("clear_route_cache", None)`; and the "not found yet"
branch must return `Action::Pause`, not `Continue`, or the chain is released
before the model is known.

It reads only as much body as it needs. With `model` in the first chunk it holds
~14KB and releases the rest; if `model` sat at the *end* of a large payload it
would keep pausing and Envoy would keep accumulating, degrading to the buffering
behaviour. OpenAI clients put it first by convention, not guarantee.

Deploying it needs no custom proxy image - `WasmPlugin` pulls an OCI artifact,
or you mount the `.wasm`. Mounting into a Gateway-API gateway has one trap: the
obvious route, `sidecar.istio.io/userVolume` via the Gateway's
`spec.infrastructure.annotations`, *looks* like it works because the annotations
propagate all the way onto the pod template, and then no volume appears. Those
are a sidecar-injection-template feature that Istio's Gateway-API deployment
ignores. Patching the generated Deployment directly works and survives Istio's
reconciliation:

```bash
kubectl patch deploy spike-gateway-istio -n bbr-spike --type=strategic -p '{
  "spec":{"template":{"spec":{
    "volumes":[{"name":"wasm","configMap":{"name":"model-router-wasm"}}],
    "containers":[{"name":"istio-proxy","volumeMounts":[
      {"name":"wasm","mountPath":"/var/local/lib/wasm","readOnly":true}]}]
  }}}}'
```

That is what `validate.sh --profile wasm` does, and it is fine for a spike. For
real use `WasmPlugin` with `oci://` is the supported path - but it does not
expose `allow_on_headers_stop_iteration`, so partial buffering needs the raw
`EnvoyFilter` form in `profiles/wasm.yaml`.

`envoy.filters.http.golang` is in the build too and could do the same job, but
it is `dlopen`'d from the proxy filesystem, so that one really does mean image
surgery plus an ABI rebuild on every Istio bump.

### 7. The wasm VM shares the proxy process and its memory budget

There is no separate process: one `envoy` PID, and the VM's linear memory comes
out of the proxy's heap and its cgroup. `failure_policy` (default `FAIL_CLOSED`)
contains a VM *trap* to a 503 for that plugin, but an out-of-memory is not a
trap - the kernel kills the container and the gateway goes with it.

A streaming parser still buffers the *current token*, and a 30MiB prompt is one
token. With `model` first the module stops after
~14KB and never touches it; with `model` last it scans the whole thing:

| 30MiB request, proxy baseline 95MB | proxy RSS |
|---|---|
| `model` first (normal) | 115 MB |
| `model` last | 188 MB |

Per concurrent request. Twenty-four of them killed a 1GiB gateway outright -
`exitCode: 137`, `reason: OOMKilled`, then CrashLoopBackOff.

The module now stops scanning after 256KiB (`MAX_SCAN_BYTES`). `model` sits in
the first few hundred bytes of any real request, so this only gives up on
pathological ones, and giving up means no header and the default route rather
than a dead gateway. With the cap, `model` first and last cost the same
(140MB vs 141MB) and the same burst is survived.

Measured under identical load - 24 concurrent 30MiB requests, `model` last,
32MiB buffer limit, 1GiB proxy:

| | outcome |
|---|---|
| no body-reading filter (control) | survived |
| `metadata-filter` | survived |
| `lua` | survived |
| `wasm`, uncapped | **OOMKilled** |
| `wasm`, capped | survived |

The control matters: plain proxying of the same bytes is fine, so this is a cost
of reading the body, not of the request size.

`metadata-filter` has no equivalent exposure because its buffering happens in
Envoy's own decoder buffer, which is bounded per connection by
`per_connection_buffer_limit_bytes` and back-pressured by watermarks - above the
limit you get a 413, which is a bounded refusal rather than unbounded growth.
That is still a per-connection budget, so the total is the limit times
concurrency: surviving twenty-four is headroom, not immunity, and it is one more
reason to keep that number closer to the size of a real request than to 32MiB.

### 8. ext_proc does not buffer less - it buffers somewhere else

Easy to assume the external processor is the streaming option. It is not.

BBR's chart sets `request_body_mode: "FULL_DUPLEX_STREAMED"`, so Envoy is not
accumulating the body in its connection buffer. But
[`bbr/handlers/server.go`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.2.1/pkg/bbr/handlers/server.go)
appends every chunk to its own slice and only parses on `EndOfStream`, with a
whole-document `json.Unmarshal`. Its successor
[IPP does the same](https://github.com/llm-d/llm-d-inference-payload-processor/blob/main/pkg/handlers/server.go),
and is candid about the consequence in a `TODO` next to the accumulator:
"both requestBody and responseBody accumulate without an upper bound. An
arbitrarily large body can OOM the code."

So the ext_proc path still waits for the last byte before the header exists.
What it buys is *where* the memory lives - a separately scaled pod instead of
the gateway's per-connection buffer - which is why it needs no buffer-limit
tuning and never 413s. The flip side is that Envoy's bounded 413 is replaced by
an unbounded OOM in a pod on the request path. Envoy's ext_proc does offer a
genuinely partial mode (`BUFFERED_PARTIAL`); neither implementation uses it.

Of everything measured here, the wasm module is the only thing that acts on a
prefix of the body.

## So which one

| if | take | because |
|---|---|---|
| text-only, context up to ~256k | `metadata-filter` | a full 128k window is ~0.5MiB, so a few MiB of buffer covers it; config rather than a binary to version and ship |
| million-token context, or multimodal | `wasm` | a full 1M window is ~3.8MiB before a single image, and no fixed buffer limit is both large enough for real requests and small enough to be safe |
| logic beyond one field lookup | IPP | model aliases, LoRA adapter names, tokenizer-aware decisions are a program, and belong somewhere testable |

Budget the wasm VM's memory as part of the proxy's rather than alongside it - it
has no cgroup of its own (finding 7). Give IPP a memory limit, and do not pick it
expecting to avoid buffering (finding 8).

`EnvoyFilter` is Istio-specific and unversioned against Envoy's API, so an Istio
bump can change the filter chain underneath either in-proxy option.
`./validate.sh --docker` is the cheap regression check - point `PROXY_IMAGE` at
the new proxy image before upgrading.

## Odds and ends

- `allow_content_types: [application/json]` keeps the filter off everything
  else, so GETs, health checks and form posts pay no latency.
- Truncated or malformed JSON is forwarded to the backend as-is, no 5xx. The
  backend rejects it, which is where that belongs.
- `keep_empty_value: false` means a request with no model gets no header at all,
  rather than an empty one.
- The body is buffered, not consumed - the backend receives it intact.
- `json_to_metadata` selectors are JSON keys, nestable as
  `selectors: [{key: a}, {key: b}]`. OpenAI's `model` is top-level anyway.

Unrelated to any of the above: kind puts every cluster on one shared docker
network (`kind`, `172.18.0.0/16`) unless you
set `KIND_EXPERIMENTAL_DOCKER_NETWORK`. The MetalLB pool most spikes here copy,
`172.18.255.200-250`, is therefore handed out by *every* running cluster's
MetalLB, and whichever ARPs first wins. This spike's first run got a `401` from
a completely different spike's Kuadrant AuthPolicy. `setup.sh` now derives a
single LB address from the control-plane node IP, which docker already
guarantees is unique. The other spikes in this repo still have the collision
waiting for them.

## References

- [Envoy `json_to_metadata` filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/json_to_metadata_filter) / [source](https://github.com/envoyproxy/envoy/blob/main/source/extensions/filters/http/json_to_metadata/filter.cc)
- [Envoy `header_mutation` filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/header_mutation_filter) / [custom header formatters](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/headers)
- [Envoy Lua filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/lua_filter) / [source](https://github.com/envoyproxy/envoy/blob/main/source/extensions/filters/http/lua/lua_filter.cc)
- [Listener `per_connection_buffer_limit_bytes`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/listener/v3/listener.proto)
- [proxy-wasm Rust SDK](https://github.com/proxy-wasm/proxy-wasm-rust-sdk) / [Envoy wasm foreign functions](https://github.com/envoyproxy/envoy/blob/main/source/extensions/common/wasm/foreign.cc)
- [GIE body-based-router](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/v1.2.1/cmd/bbr) and [llm-d Inference Payload Processor](https://github.com/llm-d/llm-d-inference-payload-processor)
- [Istio EnvoyFilter](https://istio.io/latest/docs/reference/config/networking/envoy-filter/) / [WasmPlugin](https://istio.io/latest/docs/reference/config/proxy_extensions/wasm-plugin/)
