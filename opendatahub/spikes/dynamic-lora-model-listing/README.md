# dynamic-lora-model-listing

LoRA adapters sitting in a PVC, loaded and unloaded on demand, with a route that
never changes. The question: **does `/v1/models` tell you the truth about what is
actually loaded?**

Short answer: yes, with one sharp exception that this spike also fixes.

## The setup

Three pieces, and the third is the interesting one:

- a **PVC** holding four adapters, none of them declared anywhere
- an **`LLMInferenceService` with no `spec.model.lora`** - so kserve injects
  neither `--enable-lora` nor a PVC mount, and we supply both by hand
- an **HTTPRoute captured verbatim from a kserve-managed one** for four
  adapters, supplied inline via `spec.router.route.http.spec`

So the route indexes `model-dyn` plus `adapter-1..4` permanently, while the
runtime starts with zero adapters. Every combination of *indexed* and *loaded*
is reachable without touching the gateway.

The route is captured rather than hand-written on purpose. A hand-rolled shape
differs from the managed one and then every result has to be read through that
difference. `hack/capture-route.sh` declares the adapters, waits for the
controller, captures what it emitted, and strips the declaration again.

## Try it

Everything below is plain `curl` through the gateway. No `kubectl exec`, no port
forward - the service-scoped path family already routes `/v1/...` to the
workload.

```bash
export GW=http://$(kubectl get gateway kserve-ingress-gateway -n kserve \
  -o jsonpath='{.status.addresses[0].value}')
export B=$GW/dynamic-lora/svc-dyn
```

**List what is loaded**

```bash
curl -s $B/v1/models | jq -r '.data[] | select(.parent) | .id'
```

**Load one from the PVC**

```bash
curl -s -X POST $B/v1/load_lora_adapter \
  -H 'Content-Type: application/json' \
  -d '{"lora_name":"adapter-1","lora_path":"/mnt/lora/adapter-1"}'
# Success: LoRA adapter 'adapter-1' added successfully.
```

**Use it**

```bash
curl -s -X POST $B/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"adapter-1","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' \
  | jq -r .model
# adapter-1
```

**Unload it**

```bash
curl -s -X POST $B/v1/unload_lora_adapter \
  -H 'Content-Type: application/json' \
  -d '{"lora_name":"adapter-1"}'
# Success: LoRA adapter 'adapter-1' removed successfully.
```

That is the whole loop. No restart, no route change, no controller involvement.

There is also a SageMaker-flavoured alias for the same two operations, with a
different payload shape:

```bash
curl -s -X POST   $B/adapters -H 'Content-Type: application/json' \
  -d '{"name":"adapter-1","src":"/mnt/lora/adapter-1"}'
curl -s -X DELETE $B/adapters/adapter-1
```

Both APIs mutate the same table. Note `/adapters` is POST-only and
`/adapters/{name}` is DELETE-only - neither lists anything, so **`/v1/models` is
the only view of loaded adapters that exists**.

## Does the listing tell the truth?

Yes. `./probe-listing.sh` checks it three ways and records `golden/listing.tsv`.

**It follows every call.** Load four, unload two, re-load one - the list matches
at every step, with no lag and no leaked entries.

**It agrees with reality.** A list can be self-consistent and still not describe
what serves, so every state is cross-checked with real inference:

| adapter | listed | serves direct | via gateway | |
|---|---|---|---|---|
| adapter-1 | yes | 200 | 200 | agrees |
| adapter-2 | yes | 200 | 200 | agrees |
| adapter-3 | yes | 200 | 200 | agrees |
| adapter-4 | no | 404 | 404 | agrees |

Note adapter-4 is **indexed in the route but not loaded**: the route matches and
forwards, and the runtime 404s. The gateway has no idea.

**Failed operations do not corrupt it.** Loading an already-loaded name (400),
unloading one that was never loaded (404), a malformed payload (400) - the list
is untouched in every case.

## The exception: unload does not unload

This is the one place the listing becomes a trap, and it only affects adapters
that kserve declared - not the on-demand ones above.

kserve registers every spec-declared adapter under **two** names
(`workload_lora.go:166-167`): the bare name and the fully qualified one. vLLM's
adapter table is a plain dict keyed by name, and unload takes a single
`lora_name`, so it removes **one of the two**:

```
                            bare listed  qual listed  bare serves  QUALIFIED via gateway
both names registered       yes          yes          200          200
after naive unload          no           yes          404          200   <-- still serving
after adapterctl unload     no           no           404          404
restored                    yes          yes          200          200
```

The second row is the problem. `unload adapter-1` returns `200 Success`,
`/v1/models` drops the bare entry, and every local signal says it is gone - but
`publishers/{ns}/models/adapter-1` is still loaded, still serving, and is **the
only name the HTTPRoute indexes**. So the unload broke the name nothing routes
on and left gateway traffic untouched.

`/v1/models` is not lying here. It correctly reports the entry that survived.
The lie is in the mental model that one adapter equals one name.

### The fix, with what we have today

`adapterctl.sh` treats the pair as the unit and verifies afterwards:

```bash
./adapterctl.sh load   adapter-1     # registers both names
./adapterctl.sh unload adapter-1     # removes both, then checks
./adapterctl.sh verify adapter-1     # is it REALLY gone?
./adapterctl.sh list
```

`unload` always ends with `verify`, which fails loudly if any name survived -
which is exactly what the raw API does not do.

### The fix that belongs upstream

`--lora-modules` should accept a list of served names per adapter, so unload
removes the *adapter* and every name goes with it. vLLM has no alias concept
today; two names for one set of weights are two independent entries, and there
is no unload-by-path either. Until that changes, anything unloading by a single
name is half an unload.

The alternative - kserve registering once - is a client-visible break either
way: drop the bare name and `{"model":"adapter-1"}` stops working, drop the
qualified one and the form used on publisher paths stops working. Both have live
callers.

## Layout

```
manifests/fixture.yaml        PVC + LLMISVC, no lora block, route inline
manifests/route-rules.yaml    rules captured from the managed route (do not hand-edit)
hack/capture-route.sh         declare -> capture -> strip, regenerates the above
adapterctl.sh                 load/unload as one adapter, two names
probe-listing.sh              the three checks above -> golden/listing.tsv
golden/listing.tsv            recorded results
```

## Running it

Needs a cluster with kserve, Gateway API, Istio and a `kserve-ingress-gateway` -
`../lora-httproute-budget/setup.sh --with-kserve` builds one, and that spike's
`DEV.md` covers the gotchas.

```bash
kubectl create namespace dynamic-lora
kubectl apply -f manifests/fixture.yaml
# seed the PVC with adapter-1..4, then:
./probe-listing.sh
```

Two things that will otherwise waste an hour:

- **The EPP needs a `DestinationRule`** disabling mTLS origination, or every
  pool-bound request returns 500 while the route, the pool and the EPP all
  report healthy. One per EPP Service.
- **`--max-loras` defaults to 1.** kserve only emits it when
  `LoRASpec.MaxAdapters` is set, so without it vLLM keeps one adapter resident
  and swaps. The fixture sets `--max-loras=4` explicitly.

## What this does not cover

The HTTPRoute match budget - how many adapters fit in a route before the
apiserver refuses - is the subject of `../lora-httproute-budget`. Here the route
is fixed at four and never changes; that is the control, not the question.
