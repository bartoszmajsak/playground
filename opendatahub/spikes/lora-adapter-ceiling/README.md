# LoRA Adapter Ceiling Spike

KServe's LLMInferenceService registers every LoRA adapter under two names, so a
pod serves half the adapters its configured budget suggests. This spike measures
the effect end to end.

## Result

Four adapters, eight registrations, 24 requests spanning both public names of
each adapter:

| Arm | `maxCpuAdapters` | Registrations | Request-path reloads |
|---|---|---|---|
| `ceiling-explicit` | 4 | 8 + 2 base names | 23 |
| `ceiling-headroom` | 8 | 8 + 2 base names | 0 |

Identical adapters, image and traffic. The only variable is whether the budget
covers the registrations or half of them. An operator who sizes `maxCpuAdapters`
to the adapters they declared is short by exactly the duplication factor, and 23
of 24 requests then read weights from disk on the request path.

Measured 16 September 2026 on kind with Istio, Gateway API inference extension
and the llmisvc controller from `master`, runtime `vllm/vllm-openai-cpu:v0.19.0`.

## What the controller renders

`pkg/controller/v1alpha2/llmisvc/workload_lora.go` emits two `--lora-modules`
entries per declared adapter, the bare name and the publisher-qualified one,
both pointing at the same directory:

```go
for _, mod := range []loraModuleJSON{
    {Name: a.name, Path: a.mountPath},
    {Name: fullyQualifiedModelName(llmSvc.Namespace, a.name), Path: a.mountPath},
} {
```

Introduced with model-name based routing in kserve/kserve#5521. Serving
`publishers/<ns>/models/<name>` requires vLLM to hold that name, and without a
rewrite layer a second registration is the only way to provide it.

## Why two names cost two slots

vLLM counts registrations, not bytes, and nothing in the path compares file
paths:

- The frontend assigns one id per name. `lora_int_id` is looked up by
  `lora_name` and allocated fresh when absent
  (`entrypoints/openai/models/serving.py`).
- The worker cache is `LoRALRUCache(capacity, ...)` with capacity
  `max_cpu_loras`, an `AdapterLRUCache[int, T]` keyed on `lora.id`
  (`lora/model_manager.py:52`, `:865`).
- `add_adapter` dedupes on id alone (`:812`).

Identical weights at one path therefore occupy two cache entries.

The same duplication makes removal non-atomic: unload takes one name, so
removing an adapter is two calls that can partially fail.

## Findings

**The duplication is exactly 2x.** Four declared adapters render eight entries,
paired on the same path:

```
--enable-lora
--lora-modules
'{"name":"ceil-a1","path":"/mnt/lora/ceil-a1"}'
'{"name":"publishers/lora-ceiling/models/ceil-a1","path":"/mnt/lora/ceil-a1"}'
... x4
```

**With no limits set, the cache holds one slot.** KServe injects `--max-loras`
and `--max-cpu-loras` only when the spec sets them. vLLM defaults `max_loras` to
1 (`config/lora.py:33`) and `max_cpu_loras` to `max_loras` (`:101-102`), and
neither is derived from the `--lora-modules` list. The godoc on `MaxCpuAdapters`
states it defaults to the number of configured adapters; that is incorrect, and
a service with no limits set runs a one-slot cache holding 2N registrations.

**Nothing reports the over-subscription.** The over-subscribed service reports
`HTTPRoutesReady=True InferencePoolReady=True PresetsCombined=True
RouterReady=True SchedulerWorkloadReady=True`. No condition, reason or event
mentions capacity. The ceiling surfaces as latency, never as an error.

**Every publisher-path inference route is pool-backed.** Ten publisher-path
matches across two services:

| Path | Backend |
|---|---|
| `/publishers/<ns>/models/<model>/v1/chat/completions` | InferencePool |
| `/publishers/<ns>/models/<model>/v1/completions` | InferencePool |
| `/publishers/<ns>/models/<model>/v1/messages` | InferencePool |
| `/publishers/<ns>/models/<model>/v1/responses` | InferencePool |
| `/publishers/<ns>/models/<model>` | Service |

Inference traffic passes the endpoint picker, so an `InferenceModelRewrite` rule
can rewrite the body model and the second registration becomes unnecessary. The
two Service-backed entries carry no `/v1/` suffix: they are the model metadata
route, answered from the pod rather than through the router. Dropping the
qualified registration changes what that endpoint reports, which is a listing
contract question rather than a routing failure.

## Running it

```bash
./setup.sh                                                # kind + Istio + GWAPI + GIE + llmisvc
./validate.sh                                             # control plane, seconds, no model pull
kubectl apply -n lora-ceiling -f manifests/adapters.yaml   # claim + adapter generator
./probe-evictions.sh                                       # the two arms above
```

`setup.sh` takes `CLUSTER_NAME` and `NS`; `validate.sh` takes `KEEP=1` to leave
the services running; `probe-evictions.sh` takes `PASSES`.

`validate.sh` reads what the controller renders and never waits for a pod to be
Ready, so it establishes the duplication, the missing budget flags, the silent
status and the route backends without a model download.

## Method notes

**Traffic has to span both public names.** KServe advertises both, so some
clients use the bare name and some the qualified one. They are two cache entries
for identical weights and evict each other. Requesting only bare names shows
nothing: four distinct names fit a four-slot cache, and the four qualified
registrations sit idle after being evicted once at start-up.

**Reloads are counted, not timed.** The adapters are rank-8 no-ops of about
35 KB, so load latency is not measurable on them. Two DEBUG lines carry the
signal instead: `AdapterLRUCache._on_remove` logs
`"Removing adapter int id: N"` (`lora/model_manager.py:58`) and `add_adapter`
logs `"Adding lora. Model id: N"` (`:811`, `:878`). Counting works at any
adapter size.

Two qualifications on reading those lines:

- Only adds after traffic starts are cache misses. `init_static_loras` adds every
  static module at boot, and both arms show identical start-up adds.
- Only adds count. Both LoRA caches are `AdapterLRUCache` and log the same
  removal line, but `_registered_adapters` (capacity `max_cpu_loras`) evicting
  forces a disk reload while `_active_adapters` (capacity `max_loras`) evicting
  is ordinary batch rotation.

**Runtime pin.** `vllm/vllm-openai-cpu:v0.19.0`. The newer CPU release image
cannot serve LoRA: the worker fails at start-up with `'PunicaWrapperCPU' object
has no attribute 'token_mapping_meta'`. The llmisvc preset sets `runAsNonRoot`,
which both images refuse, so each arm overrides it at container level.

## Open items

- What the bare publisher path should report once the qualified name is no
  longer registered.
- Whether the `MaxCpuAdapters` godoc is corrected alongside the duplication fix
  or separately; the default-budget behaviour is a distinct defect.

## References

- kserve/kserve#5521 - model-name based routing, which introduced the second registration
- kserve/kserve#6174 - the HTTPRoute match duplication, a separate layer with no interaction
- vLLM `lora/model_manager.py`, `config/lora.py`, `entrypoints/openai/models/serving.py`
