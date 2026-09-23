#!/usr/bin/env python3
"""Snapshot applicable token policies and verify their live Wasm configuration."""
import argparse
import json
from pathlib import Path


def sources(dump):
    result = set()
    for config in dump["configs"]:
        for listener in config.get("dynamic_listeners", []):
            for chain in listener.get("active_state", {}).get("listener", {}).get("filter_chains", []):
                for network in chain.get("filters", []):
                    for filt in network.get("typed_config", {}).get("http_filters", []):
                        if "wasm" not in filt["name"]:
                            continue
                        tc = filt["typed_config"]
                        value = tc.get("value", tc).get("config", {}).get("configuration", {}).get("value")
                        if not value:
                            continue
                        for action_set in json.loads(value).get("actionSets", []):
                            for action in action_set.get("actions", []):
                                result.update(action.get("sources", []))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    snapshot = sub.add_parser("snapshot")
    snapshot.add_argument("policies")
    snapshot.add_argument("output")
    snapshot.add_argument("--model-namespace", required=True)
    snapshot.add_argument("--route", required=True)
    snapshot.add_argument("--gateway-namespace", required=True)
    snapshot.add_argument("--gateway", required=True)
    check = sub.add_parser("check")
    check.add_argument("snapshot")
    check.add_argument("dump")
    check.add_argument("state", choices=("present", "absent"))
    args = parser.parse_args()
    if args.command == "snapshot":
        items = []
        for policy in json.loads(Path(args.policies).read_text())["items"]:
            target = policy["spec"]["targetRef"]
            identity = (policy["metadata"]["namespace"], target["kind"], target["name"])
            if identity not in ((args.model_namespace, "HTTPRoute", args.route), (args.gateway_namespace, "Gateway", args.gateway)):
                continue
            if policy["metadata"].get("deletionTimestamp"):
                raise SystemExit("a relevant token policy is already being deleted")
            for key in ("creationTimestamp", "generation", "managedFields", "resourceVersion", "uid"):
                policy["metadata"].pop(key, None)
            policy.pop("status", None)
            items.append(policy)
        if not any(p["spec"]["targetRef"]["kind"] == "HTTPRoute" for p in items):
            raise SystemExit("no model TokenRateLimitPolicy found; cannot reproduce TRLP interaction")
        Path(args.output).write_text(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}, indent=2) + "\n")
    else:
        wanted = {f"tokenratelimitpolicy.kuadrant.io:{p['metadata']['namespace']}/{p['metadata']['name']}"
                  for p in json.loads(Path(args.snapshot).read_text())["items"]}
        live = sources(json.loads(Path(args.dump).read_text()))
        if not any(s.startswith("authpolicy.") for s in live):
            raise SystemExit("authentication policy disappeared from the live Wasm configuration")
        ok = wanted <= live if args.state == "present" else wanted.isdisjoint(live)
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
