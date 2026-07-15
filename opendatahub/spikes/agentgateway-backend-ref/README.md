# AgentGateway BackendRef Override Spike

Validates the integration described in [kserve/website#697](https://github.com/kserve/website/pull/697) - overriding `backendRef` in KServe-generated HTTPRoutes to point at `AgentgatewayBackend` instead of the default `InferencePool`.

## What this proves

When KServe creates HTTPRoutes for an LLMInferenceService, the `backendRef` normally points to an `InferencePool`. AgentGateway routes this traffic fine but treats it as generic HTTP - no token parsing, no GenAI telemetry, no token-based rate limiting.

By overriding `spec.router.route.http` on the LLMInferenceService (or via a reusable `LLMInferenceServiceConfig`), the `backendRef` switches to `AgentgatewayBackend`. AgentGateway then recognizes the backend as an LLM provider and activates its full LLM pipeline:

- Token usage parsing from OpenAI-format responses
- GenAI semantic convention telemetry (OTel)
- Model tracking
- Token-based rate limiting (via `AgentgatewayPolicy`)

## Setup

Requires `LLMISVC_IMAGE` pointing at a controller image that supports the `spec.router.route.http` override (the traffic-splitting branch on the fork).

```bash
LLMISVC_IMAGE=quay.io/bmajsak/llmisvc-controller:traffic-splitting ./setup.sh
```

This creates a kind cluster with:
- MetalLB (for LoadBalancer IPs)
- cert-manager
- Gateway API + GIE CRDs
- LWS (LeaderWorkerSet)
- AgentGateway v1.3.1 (replaces Istio)
- LLMISVC controller

## Validation

```bash
./validate.sh                 # deploy model + test LLM-aware routing
./validate.sh --ratelimit     # also test token-based rate limiting
```

The validation script:
1. Deploys a `tiny-random-LlamaForCausalLM` model on vLLM CPU (no GPU needed)
2. Creates an `AgentgatewayBackend` pointing to the workload service
3. Overrides the HTTPRoute backendRef via per-service `spec.router.route.http`
4. Sends chat completion requests and checks for valid responses
5. Inspects AgentGateway logs for `protocol=llm` and `gen_ai.*` fields
6. Optionally tests token-based rate limiting (429 after budget exhaustion)

## Key difference from controlled-deployment spike

Same model and workload configs, but AgentGateway instead of Istio. The interesting bit is the `spec.router.route.http` override on the LLMInferenceService that redirects traffic through the `AgentgatewayBackend` path.

## References

- [AgentGateway KServe integration](https://agentgateway.dev/docs/kubernetes/latest/integrations/kserve.md)
- [AgentGateway getting started](https://agentgateway.dev/docs/kubernetes/latest/quickstart/install.md)
- [PR kserve/website#697](https://github.com/kserve/website/pull/697) - the tutorial this spike validates
- [kserve/kserve#5729](https://github.com/kserve/kserve/issues/5729) - upstream issue
