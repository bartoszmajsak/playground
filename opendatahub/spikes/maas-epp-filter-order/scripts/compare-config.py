#!/usr/bin/env python3
"""Verify that a comparison changes only HTTP filter order or Wasm policy config."""
import json
import sys


def normalize(path):
    listeners, routes = {}, {}
    for config in json.load(open(path))["configs"]:
        for entry in config.get("dynamic_listeners", []):
            listener = entry.get("active_state", {}).get("listener", {})
            for number, chain in enumerate(listener.get("filter_chains", [])):
                for filt in chain.get("filters", []):
                    if filt["name"] == "envoy.filters.network.http_connection_manager":
                        listeners[(listener["name"], number)] = filt["typed_config"]["http_filters"]
        for entry in config.get("dynamic_route_configs", []):
            routes[entry["route_config"]["name"]] = entry["route_config"]
    return listeners, routes


before, after, change = sys.argv[1:]
left, lr = normalize(before)
right, rr = normalize(after)
assert left and lr and left.keys() == right.keys(), "missing/changed listeners or routes"
assert lr == rr, "HTTP route configuration changed"
result = {"identical_routes": True, "listeners": {}}
for key, filters in left.items():
    other = right[key]
    a, b = {f["name"]: f for f in filters}, {f["name"]: f for f in other}
    assert len(a) == len(filters) and len(b) == len(other), "duplicate HTTP filter"
    assert a.keys() == b.keys(), "filter added or removed"
    changed = [name for name in a if a[name] != b[name]]
    same_order = list(a) == list(b)
    if change == "order":
        assert not changed, f"filter configuration changed: {changed}"
    elif change == "policies":
        assert same_order, "filter order changed during policy comparison"
        assert all("wasm" in name for name in changed), f"non-Wasm configuration changed: {changed}"
    else:
        raise SystemExit("expected comparison type order or policies")
    result["listeners"][str(key)] = {"identical_order": same_order, "changed_filter_configs": changed}
print(json.dumps(result, indent=2))
