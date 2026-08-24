"""Render captured Deployments as the only three numbers that matter.

pod-template sha256 is taken over the same bytes the Deployment controller
hashes to decide whether it needs a new ReplicaSet, so two runs sharing a hash
provably did not roll.
"""

import hashlib
import json
import sys

out = sys.argv[1]
labels = sys.argv[2:] or ["BASE1", "PR5949", "BASE2", "OURS"]

print(f"{'run':10} {'generation':>10} {'replicaSets':>11}  {'pod-template sha256':<18} replicaset hashes")
for label in labels:
    try:
        deployment = json.load(open(f"{out}/deploy-{label}.json"))
    except OSError:
        print(f"{label:10} <no deployment captured>")
        continue
    template = json.dumps(deployment["spec"]["template"]["spec"], sort_keys=True)
    sha = hashlib.sha256(template.encode()).hexdigest()[:16]
    replicasets = json.load(open(f"{out}/rs-{label}.json"))["items"]
    hashes = sorted(r["metadata"]["labels"].get("pod-template-hash", "?") for r in replicasets)
    print(f"{label:10} {deployment['metadata']['generation']:>10} {len(replicasets):>11}  {sha:<18} {hashes}")
