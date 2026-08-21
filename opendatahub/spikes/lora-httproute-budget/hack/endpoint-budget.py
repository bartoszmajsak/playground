#!/usr/bin/env python3
"""How the adapter ceiling moves when you add API endpoints.

The budget is paths x models, so every endpoint added to the model-routing rule
is adapters taken away. Nothing else in this spike priced that: the endpoint set
was treated as fixed at the four kserve templates today.

Two structures are compared, because the obvious consolidation is NOT available:

  per-endpoint   what ships. One rule per endpoint per path family, because each
                 rule carries its own URLRewrite (ReplacePrefixMatch back to the
                 endpoint path) and Gateway API filters are per RULE, not per
                 match. Four matches in one rule cannot have four rewrites.

  v1-prefix      one rule per family matching PathPrefix /{...}/v1 and rewriting
                 to /v1. ReplacePrefixMatch replaces the matched prefix, so this
                 strips exactly the same leading segments for every endpoint and
                 needs only one filter. Endpoint-agnostic: new endpoints cost no
                 rules and no matches on the path axis at all.

Validated against the three measured ceilings before it projects anything.
"""
RULE_CAP, ROUTE_CAP, RULES_CAP = 64, 128, 16


def shape(name, E, A, path_family="per-endpoint"):
    M = 1 + A                       # base model plus adapters
    rules, per_rule, total = 0, [], 0

    for _ in ("name-path", "publisher-path"):
        if path_family == "v1-prefix":
            rules += 1; per_rule.append(1); total += 1
        else:
            rules += E; per_rule.append(1); total += E

    rules += 2; per_rule.append(1); total += 2          # the two path catch-alls

    if name == "current":
        rules += 1; per_rule.append(2 * E * M); total += 2 * E * M
    elif name == "split":
        rules += E; per_rule.append(2 * M); total += 2 * E * M
    elif name == "split-noslash":
        rules += E; per_rule.append(M); total += E * M
    elif name == "collapse":
        rules += 1; per_rule.append(M); total += M
    else:
        raise ValueError(name)

    rules += 1; per_rule.append(M); total += M          # header-only catch-all
    return rules, max(per_rule), total


def ceiling(name, E, path_family="per-endpoint"):
    best = None
    for A in range(0, 4000):
        r, pr, t = shape(name, E, A, path_family)
        if r > RULES_CAP or pr > RULE_CAP or t > ROUTE_CAP:
            break
        best = A
    return best


def binds(name, E, path_family="per-endpoint"):
    A = ceiling(name, E, path_family)
    if A is None:
        return "no room for even the base model"
    r, pr, t = shape(name, E, A + 1, path_family)
    if r > RULES_CAP:   return "16 rules"
    if pr > RULE_CAP:   return "64 / rule"
    return "128 / route"


for (nm, E), want in {("current", 4): 7, ("split", 4): 12, ("split-noslash", 4): 22}.items():
    got = ceiling(nm, E)
    assert got == want, "%s E=%d -> %s, cluster measured %s" % (nm, E, got, want)
print("model reproduces the three measured ceilings at 4 endpoints\n")

COLS = (4, 5, 6, 8, 11, 14)
for fam in ("per-endpoint", "v1-prefix"):
    print("adapter ceiling by endpoint count - path families: %s" % fam)
    print("  %-16s %s" % ("endpoints", "  ".join("%-5d" % e for e in COLS)))
    for nm in ("current", "split", "split-noslash", "collapse"):
        cells = []
        for e in COLS:
            c = ceiling(nm, e, fam)
            cells.append("%-5s" % ("none" if c is None else c))
        print("  %-16s %s   binds on %s" % (nm, "  ".join(cells), binds(nm, 4, fam)))
    print()

print("rule slots used (cap %d) - this is what removes the split family" % RULES_CAP)
print("  %-22s %s" % ("endpoints", "  ".join("%-5d" % e for e in COLS)))
for fam in ("per-endpoint", "v1-prefix"):
    for nm in ("current", "split-noslash"):
        cells = ["%-5d" % shape(nm, e, 1, fam)[0] for e in COLS]
        print("  %-22s %s" % ("%s / %s" % (nm, fam), "  ".join(cells)))


# ---------------------------------------------------------------------------
# Sharding: the caps are all PER ROUTE and nothing caps routes per Gateway, so
# the model-routing rules can live in their own HTTPRoutes. Route 0 keeps the
# path families; each shard carries only model-routing.
# ---------------------------------------------------------------------------

def shard_capacity(E, style="split-noslash"):
    """Models per shard route, and what stops it."""
    best, why = 0, ""
    for M in range(1, 4000):
        if style == "split-noslash":
            rules, per_rule, total = E, M, E * M
        elif style == "one-rule":
            rules, per_rule, total = 1, E * M, E * M
        else:
            raise ValueError(style)
        if rules > RULES_CAP:   why = "16 rules"; break
        if per_rule > RULE_CAP: why = "64 / rule"; break
        if total > ROUTE_CAP:   why = "128 / route"; break
        best = M
    return best, why


print("\nsharding: models per shard route (adapters = models - 1 if the shard carries the base)")
print("  %-16s %s" % ("endpoints", "  ".join("%-14d" % e for e in COLS)))
for style in ("one-rule", "split-noslash"):
    cells = []
    for e in COLS:
        m, why = shard_capacity(e, style)
        cells.append("%-14s" % ("%d  (%s)" % (m, why) if m else "none"))
    print("  %-16s %s" % (style, "  ".join(cells)))
print("\n  shards themselves are unbounded: Gateway API caps rules and matches per")
print("  ROUTE and puts no limit on how many routes attach to a Gateway.")
