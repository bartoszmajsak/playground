# dynamic-lora-model-listing

Does `/v1/models` report the true state of dynamically loaded LoRA adapters?

Yes, with one exception, covered below.

## Setup

- a PVC with four adapters, none declared in any spec
- an `LLMInferenceService` without `spec.model.lora`, so kserve injects neither
  `--enable-lora` nor a PVC mount; both are supplied by hand
- an HTTPRoute captured from a kserve-managed one for four adapters, supplied
  inline via `spec.router.route.http.spec`

The route indexes `model-dyn` and `adapter-1..4` permanently while the runtime
starts empty, so any combination of indexed and loaded is reachable without
touching the gateway.

The route is captured rather than hand-written: a hand-rolled shape differs from
the managed one, and every result then has to be read through that difference.
To refresh `manifests/route-rules.yaml`, declare the adapters in
`spec.model.lora`, let the controller reconcile, copy `.spec.rules` from the
generated HTTPRoute, and remove the declaration.

## Try it

Plain `curl` through the gateway; no `kubectl exec` or port forward, since the
service-scoped path family already routes `/v1/...` to the workload.

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

No restart, no route change, no controller involvement.

A SageMaker-flavoured alias exists for the same two operations, with a different
payload shape:

```bash
curl -s -X POST   $B/adapters -H 'Content-Type: application/json' \
  -d '{"name":"adapter-1","src":"/mnt/lora/adapter-1"}'
curl -s -X DELETE $B/adapters/adapter-1
```

Both mutate the same table. `/adapters` is POST-only and `/adapters/{name}` is
DELETE-only - neither lists, so `/v1/models` is the only view of loaded adapters.

## Does the listing hold up?

`./check.sh` runs two checks. `-v` echoes every request and response, so the
summary can be checked against the wire:

```
> POST /v1/load_lora_adapter
  {"lora_name":"adapter-1","lora_path":"/mnt/lora/adapter-1"}
  < Success: LoRA adapter 'adapter-1' added successfully.
load adapter-1         adapter-1
```

**It follows every call.** Each step declares the set it expects and compares:

```
  start (reset)          -                                ok
  load adapter-1         adapter-1                        ok
  load adapter-2         adapter-1,adapter-2              ok
  load adapter-3         adapter-1,adapter-2,adapter-3    ok
  unload adapter-2       adapter-1,adapter-3              ok
  re-load adapter-2      adapter-1,adapter-2,adapter-3    ok
```

**It agrees with what serves.** A listing can be internally consistent and still
not match an inference request, so every state is cross-checked:

| adapter | listed | serves direct | via gateway | |
|---|---|---|---|---|
| adapter-1 | yes | 200 | 200 | agrees |
| adapter-2 | yes | 200 | 200 | agrees |
| adapter-3 | yes | 200 | 200 | agrees |
| adapter-4 | no | 404 | 404 | agrees |

adapter-4 is indexed by the route but never loaded: the route matches and
forwards, the runtime 404s. The gateway has no view of what is loaded.

## The exception: unload removes one name, not one adapter

Affects spec-declared adapters only, not the on-demand ones above.

kserve registers each spec-declared adapter under two names
(`workload_lora.go:166-167`): bare and fully qualified. vLLM keys its adapter
table by name and unload takes a single `lora_name`, so it removes one of the
two:

```
                            bare listed  qual listed  bare serves  QUALIFIED via gateway
both names registered       yes          yes          200          200
after naive unload          no           yes          404          200   <-- still serving
after ./lora.sh unload      no           no           404          404
restored                    yes          yes          200          200
```

Row two: `unload adapter-1` returns 200, `/v1/models` drops the bare entry, and
`publishers/{ns}/models/adapter-1` remains loaded and serving. That surviving
name is the one HTTPRoute matches on, so the unload removed the name nothing
routes on and left gateway traffic unaffected.

The listing is accurate - it reports the entry that survived. The wrong
assumption is that one adapter means one name.

### Working around it today

`lora.sh` treats the pair as the unit and verifies afterwards:

```bash
./lora.sh unload adapter-1     # removes BOTH names, then confirms
```

Fails if any name survives, which the raw API does not check. Adapters loaded
through `./lora.sh load` register once and are unaffected.

### The upstream fix

`--lora-modules` would need to accept a list of served names per adapter, so
unload removes the adapter and every name with it. vLLM has no alias concept
and no unload-by-path, so today any unload by single name is partial.

kserve registering once is the alternative, and breaks clients either way:
dropping the bare name breaks `{"model":"adapter-1"}`, dropping the qualified
one breaks the form used on publisher paths. Both have callers.

## Layout

```
setup.sh                      builds everything, --destroy removes it
lora.sh                       list / load / unload  (unload clears both names)
check.sh                      does /v1/models match reality?  -v for the wire
manifests/fixture.yaml        PVC + LLMISVC, no lora block
manifests/route-rules.yaml    route captured once from a kserve-managed one
hack/gen-adapter.py           tiny no-op LoRA adapters, stdlib only
```

## Running it

Self-contained. Needs `kind`, `kubectl`, `helm`, `docker`, `curl`, `python3`.

```bash
./setup.sh                  # kind cluster + everything + fixture
./setup.sh --skip-cluster   # fixture only, against a cluster you already have
./setup.sh --teardown       # drop the namespace
./setup.sh --destroy        # drop the whole kind cluster
```

Builds the cluster (MetalLB, Gateway API, cert-manager, inference extension,
LWS, Istio, kserve), generates the adapters, seeds the PVC through a throwaway
pod, applies the fixture, adds the `DestinationRule`, and waits on a request.
Versions track kserve's `kserve-deps.env`.

Writes a scoped `.kubeconfig` next to the script; `~/.kube/config`'s current
context is untouched.

Then:

```bash
export KUBECONFIG=$PWD/.kubeconfig
./check.sh          # summary
./check.sh -v       # every request and response
```

`setup.sh` handles four constraints that apply outside this spike too:

- **Istio >= 1.29.** Below that the ext_proc filter is installed as a
  placeholder and the per-route override is never attached: the endpoint picker
  is deployed, healthy, resolved and never invoked.
- **The EPP needs a `DestinationRule`** disabling mTLS origination, one per EPP
  Service, or every pool-bound request 500s while the route, pool and EPP all
  report healthy.
- **`--max-loras` defaults to 1.** kserve emits it only when
  `LoRASpec.MaxAdapters` is set. The fixture sets `--max-loras=4`.
- **Route churn can crash istiod.** Several routes merging on one gateway trips
  the `mergeHTTPRoutes` data race; the validating webhook stops answering and
  the next apply fails with connection refused. `setup.sh` restarts it.

## What this does not cover

The HTTPRoute match budget - how many adapters fit in a route before the
apiserver refuses - is the subject of `../lora-httproute-budget`. Here the route
is fixed at four and never changes; that is the control, not the question.
