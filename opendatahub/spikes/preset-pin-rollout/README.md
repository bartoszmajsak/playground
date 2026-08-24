# Preset pin rollout spike

Does upgrading the llmisvc controller restart pods belonging to a workload whose
preset did not change?

You cannot answer that by reading a diff. Pod restarts happen because
`semanticDeploymentIsEqual` runs `equality.Semantic.DeepEqual` over the whole
`spec.template.spec`, so a byte anywhere in there - a resource request, a volume
`sizeLimit`, one character of the entrypoint script - produces a new ReplicaSet.
The only honest answer comes from a real API server watching a real controller.

This harness stands one up, runs each candidate controller against the same
pinned preset, and reports three numbers per run: the Deployment `generation`,
how many ReplicaSets exist, and a sha256 of the pod template.

## The result that motivated it

Upstream [kserve/kserve#5949](https://github.com/kserve/kserve/pull/5949) fixed a
real bug (`CPUOffloadingSpec` vs `TieringOffloadingSpec`) and, along the way,
resized `/dev/shm` and container memory from the controller.

```
run        generation replicaSets  pod-template sha256 replicaset hashes
BASE1               1           1  fa8f9d312bbdbd03   ['7f678d4cd6']
PR5949              2           2  5e84c7be1022ddb8   ['7f678d4cd6', '884d87446']
BASE2               1           1  fa8f9d312bbdbd03   ['7f678d4cd6']
OURS                1           1  fa8f9d312bbdbd03   ['7f678d4cd6']
```

Reproduce it without a cluster - the captured Deployments are in `results/`:

```bash
python3 report.py results BASE1 PR5949 BASE2 OURS
```

`BASE2` is the control. It re-runs the baseline after a namespace reset and gets
the same hash back, so a difference in a candidate round is the candidate and not
drift in the harness.

What #5949 changed, structurally:

| field | BASE1 | PR5949 |
|---|---|---|
| `dshm.sizeLimit` | 1Gi | 13Gi |
| `main.requests.memory` | 32Gi | 44Gi |
| `main.limits.memory` | 64Gi | 76Gi |

Nobody asked for that. It arrived with a controller upgrade, and it rolled the
pods. `OURS` - the same fix routed through a preset-declared env var slot rather
than controller-side mutation - leaves the pod template bit-identical.

## Running it

Needs `kind`, Docker, `kubectl`, `go`, `python3`. Three worktrees of kserve: a
baseline and two candidates.

```bash
./setup.sh   /path/to/baseline-worktree
./protocol.sh /path/to/baseline /path/to/candidate-a /path/to/candidate-b
```

`setup.sh` installs the CRDs and presets from the baseline worktree and never
touches them again. `protocol.sh` builds all three controllers, then runs
baseline -> candidate twice, snapshotting after each, and prints the table.

## What the harness does not prove

**It models a preset that survives the upgrade.** `setup.sh` installs presets
once and only ever swaps the controller binary. That is the "the release ships
versioned preset objects and the old one stays installed" world.

It is not what `helm upgrade` does today. `configPrefix` is `kserve-` with no
version component, so the preset objects a service is pinned to are overwritten
in place on upgrade. Once the preset object itself moves, its entrypoint text
moves with it and everything rolls regardless of which controller you are
running. A green result here means "the controller did not do it", not "nothing
will".

To extend the harness to that question, re-apply the candidate's
`config/llmisvcconfig` between rounds and watch the same three numbers.

## One trap worth knowing

The first run of this produced a **false negative** - a clean "no rollout" from a
controller that never started.

`go run` compiles to a temp binary and execs it as a child. Killing `go run`
leaves the child alive holding `:9443`, so the next controller dies instantly on
`listen tcp :9443: bind: address already in use` - and a controller that never
reconciles never changes the Deployment, which reads exactly like success.

`protocol.sh` therefore builds real binaries with `go build -o`, kills by PID,
polls `ss -lnt` until the port is actually free, and asserts each controller is
still alive before trusting its snapshot.

Related: deleting an `LLMInferenceService` with no controller running hangs
forever on `serving.kserve.io/llmisvc-finalizer`, so `reset_ns` runs against a
live controller.

## Files

| | |
|---|---|
| `setup.sh` | kind cluster, CRDs, pinned presets, webhook certs |
| `protocol.sh` | build all controllers, run baseline -> candidate twice, snapshot |
| `report.py` | the three numbers, from captured JSON |
| `svc.yaml` | the fixture `LLMInferenceService` (10Gi CPU tier, explicit memory) |
| `results/` | captured Deployments and ReplicaSets from the run above |
