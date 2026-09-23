# Running the reproducer

[Back to the overview](../README.md). Run commands from the spike root.

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
The general suite checks accounting; the quota-exhaustion experiment in the
[overview](../README.md#what-we-verified) was a separate check. The suite does not
silently turn off enforcement to make inference pass.

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
[`patches/local-deploy.upstream.diff`](../patches/local-deploy.upstream.diff).

Scorer regression tests:

```bash
python3 -m unittest discover -s tests -v
```
