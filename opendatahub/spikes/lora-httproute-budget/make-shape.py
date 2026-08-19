#!/usr/bin/env python3
"""Derive a candidate route shape from the captured baseline.

Every shape is generated from golden/route-current.yaml rather than hand-written,
so the only thing that differs between baseline and candidate is the one
transformation being tested. Backends are swapped to the echo Deployments the
same way swap-backends.sh does it, so the output applies directly and
characterize.sh can replay the same 57 probes against it.

Shapes:

  split           v1-model-routing -> one rule per endpoint, trailing-slash
                  variants kept together. Matches are OR'd and every slice
                  shares one backendRef with no filters, so this is
                  semantically identical to the baseline. The 64-per-rule cap
                  stops binding; the route-wide 128 takes over.

  split-noslash   as above, minus the trailing-slash matches. No OpenAI client
                  emits /v1/completions/, but dropping them IS a behaviour
                  change and should show up as exactly one moved probe.

  collapse        v1-model-routing -> a single header-only rule, no path match.
                  Buys the largest ceiling and moves every header-addressed
                  path from the workload Service to the InferencePool.

  nested          per-adapter header values -> one RegularExpression covering
                  the base model and everything nested under it. Constant size:
                  the adapter axis leaves the route entirely, path scope is
                  kept, and no BBR is required. Costs a served-name change and
                  depends on the data plane anchoring header regexes.

Usage:
  ./make-shape.py split > manifests/route-split.yaml
  ./make-shape.py collapse --real > manifests/route-collapse-real.yaml

--real keeps the original backendRefs (InferencePool / workload Service) instead
of swapping in the echo Deployments. Backend identity stops being observable,
which is the whole point of the swap -- but it puts a real EPP in the path, and
that is the only way to find out what actually answers a request the collapse
newly sends to the pool.
"""
import sys
import copy
import re
import yaml

GOLDEN = "golden/route-current.yaml"
TARGET_RULE = "v1-model-routing"
POOL_KIND = "InferencePool"


def swap(ref):
    """Same substitution as swap-backends.sh: make the destination observable."""
    name = "echo-pool" if ref.get("kind", "Service") == POOL_KIND else "echo-service"
    return {"kind": "Service", "name": name, "port": 8000}


def endpoint_of(match):
    """Group key: the path with any trailing slash removed."""
    return match["path"]["value"].rstrip("/") or "/"


def split_rule(rule, drop_slashes):
    """One rule per endpoint. Names are content-derived, never index-derived:
    index-based names reshuffle every slice whenever an endpoint is added."""
    groups = {}
    for m in rule["matches"]:
        if drop_slashes and m["path"]["value"].endswith("/"):
            continue
        groups.setdefault(endpoint_of(m), []).append(m)

    out = []
    for endpoint, matches in groups.items():
        new = copy.deepcopy(rule)
        new["name"] = "{}-{}".format(TARGET_RULE, endpoint.strip("/").replace("/", "-"))
        new["matches"] = matches
        out.append(new)
    return out


def prefix_rule(rule, split):
    """Exact -> PathPrefix, which makes the trailing-slash twin redundant.

    The path family already uses PathPrefix and needs no twin; the header family
    only carries one because Exact matches a literal string. Switching the match
    type halves the matches per endpoint AND removes the addressing asymmetry --
    /v1/messages/count_tokens currently reaches the pool path-addressed and the
    Service header-addressed, purely because of this.

    Still scoped to the enumerated endpoints, so #5087's decision (health checks
    and model info go to the Service) is untouched.
    """
    groups = {}
    for m in rule["matches"]:
        key = (endpoint_of(m), m["headers"][0]["value"])
        if key in groups:
            continue
        groups[key] = {"path": {"type": "PathPrefix", "value": key[0]},
                       "headers": copy.deepcopy(m["headers"])}

    if not split:
        new = copy.deepcopy(rule)
        new["matches"] = list(groups.values())
        return [new]

    by_ep = {}
    for (ep, _), match in groups.items():
        by_ep.setdefault(ep, []).append(match)
    out = []
    for ep, matches in by_ep.items():
        new = copy.deepcopy(rule)
        new["name"] = "{}-{}".format(TARGET_RULE, ep.strip("/").replace("/", "-"))
        new["matches"] = matches
        out.append(new)
    return out


def nested_rule(rule):
    """Replace the enumerated per-adapter header values with ONE regex.

    Under nested naming an adapter is served as
    `publishers/{ns}/models/{base}/adapters/{name}`, so a single pattern
    `publishers/{ns}/models/{base}(/.*)?` covers the base model and every
    adapter beneath it -- forever, regardless of how many there are. The
    adapter axis leaves the route entirely, with no BBR and no ConfigMap.

    The base value is matches[0]'s header: expandLoRAAdapterMatches appends
    adapter matches after the template's own, so index 0 is always the base.

    The risk this shape carries is anchoring. If the data plane matches header
    regexes as a substring rather than a full match, this also captures
    `publishers/{ns}/models/{base}-instruct` -- a different service. The
    `nested` probe family exists to settle that by observation.
    """
    base = rule["matches"][0]["headers"][0]["value"]
    pattern = re.escape(base) + "(/.*)?"

    seen, matches = set(), []
    for m in rule["matches"]:
        key = m.get("path", {}).get("value", "")
        if key in seen:
            continue
        seen.add(key)
        new = copy.deepcopy(m)
        new["headers"][0]["type"] = "RegularExpression"
        new["headers"][0]["value"] = pattern
        matches.append(new)

    out = copy.deepcopy(rule)
    out["matches"] = matches
    return [out]


def collapse_rule(rule):
    """Header-only: keep one match per distinct header value, drop the path.

    This makes the rule's match set identical to v1-catch-all-model-routing's,
    which sits later in the list with a different backend -- so that rule stops
    being reachable. That is the point of the probe, not an oversight.
    """
    seen, matches = set(), []
    for m in rule["matches"]:
        value = m["headers"][0]["value"]
        if value in seen:
            continue
        seen.add(value)
        matches.append({"headers": copy.deepcopy(m["headers"])})
    new = copy.deepcopy(rule)
    new["matches"] = matches
    return [new]


def transform(shape, rule):
    if shape == "split":
        return split_rule(rule, drop_slashes=False)
    if shape == "split-noslash":
        return split_rule(rule, drop_slashes=True)
    if shape == "nested":
        return nested_rule(rule)
    if shape == "prefix":
        return prefix_rule(rule, split=False)
    if shape == "split-prefix":
        return prefix_rule(rule, split=True)
    if shape in ("collapse", "collapse-dedup"):
        return collapse_rule(rule)
    raise SystemExit("unknown shape: {}".format(shape))


def main():
    args = sys.argv[1:]
    real = "--real" in args
    args = [a for a in args if a != "--real"]
    if len(args) != 1:
        raise SystemExit(__doc__)
    shape = args[0]

    out = []
    for doc in yaml.safe_load_all(open(GOLDEN)):
        if not doc or doc.get("kind") != "HTTPRoute":
            continue

        md = doc["metadata"]
        md["name"] = md["name"] + ("-epp" if real else "-characterize")
        for k in ("ownerReferences", "resourceVersion", "uid", "generation",
                  "creationTimestamp", "managedFields", "annotations"):
            md.pop(k, None)
        doc.pop("status", None)

        rules = []
        for rule in doc["spec"]["rules"]:
            if rule.get("name") == TARGET_RULE:
                rules.extend(transform(shape, rule))
            elif (shape == "nested"
                  and rule.get("name") == "v1-catch-all-model-routing"):
                # nested has to cover BOTH header rules -- leaving the catch-all
                # enumerated would keep the adapter axis in the budget and
                # defeat the point.
                rules.extend(nested_rule(rule))
            elif (shape == "collapse-dedup"
                  and rule.get("name") == "v1-catch-all-model-routing"):
                # Unreachable once TARGET_RULE is header-only: identical match
                # set, earlier in the list. Dropping it should change nothing
                # observable and roughly doubles the ceiling.
                continue
            else:
                rules.append(rule)
        if not real:
            for rule in rules:
                if "backendRefs" in rule:
                    rule["backendRefs"] = [swap(r) for r in rule["backendRefs"]]
        doc["spec"]["rules"] = rules

        counts = [len(r.get("matches", [])) for r in rules]
        print("# {}: {} rules, max {}/rule, {} total".format(
            md["name"], len(rules), max(counts), sum(counts)), file=sys.stderr)
        out.append(doc)

    yaml.safe_dump_all(out, sys.stdout, sort_keys=False, default_flow_style=False)


if __name__ == "__main__":
    main()
