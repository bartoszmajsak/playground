#!/usr/bin/env python3
"""How big can the alternation get, and what does each way of writing it buy?

The 4096-byte cap on a header match value is the binding constraint, so every
byte spent on escaping is an adapter not served. This compares the forms and
prints the ceiling each one reaches, plus how the ceiling moves with name length.

Nothing here touches the cluster: it is arithmetic on the pattern string, and the
ceilings it prints are checked against probe-ceiling.sh's measured 297.
"""
import re

CAP = 4096
PREFIX = "publishers/lora-budget/models/"

# Kubernetes object names are DNS-1123: lowercase alphanumerics, '-' and '.'.
# Of those only '.' means anything to RE2, so it is the only one that must be
# escaped. Anything outside that alphabet falls back to full escaping rather
# than being trusted.
SAFE = re.compile(r"^[a-z0-9.-]+$")


def esc_full(s):
    """What ships today: Python's re.escape, which also escapes '-'."""
    return re.escape(s)


def esc_minimal(s):
    """Escape only what RE2 needs, and only for names we recognise."""
    return s.replace(".", r"\.") if SAFE.match(s) else re.escape(s)


def pattern(names, esc):
    return esc(PREFIX) + "(" + "|".join(esc(n) for n in names) + ")"


def ceiling(esc, namer):
    """Largest N whose pattern still fits, found the same way the probe does."""
    n = 0
    while True:
        names = ["model-a"] + [namer(i) for i in range(1, n + 2)]
        if len(pattern(names, esc)) > CAP:
            return n
        n += 1


print("== forms, with the synthetic names the ceiling probe uses ==\n")
synthetic = lambda i: "adapter-a%d" % i
for label, esc in (("re.escape (shipped)", esc_full), ("minimal escaping", esc_minimal)):
    c = ceiling(esc, synthetic)
    names = ["model-a"] + [synthetic(i) for i in range(1, c + 1)]
    print("  %-22s %3d adapters   %4d bytes" % (label, c, len(pattern(names, esc))))

print("\n== ceiling vs name length (minimal escaping, realistic names) ==\n")
print("  mean name length   adapters")
for ln in (8, 12, 16, 24, 32, 48):
    namer = lambda i, ln=ln: ("a%0*d" % (ln - 1, i))[:ln]
    print("  %11d      %8d" % (ln, ceiling(esc_minimal, namer)))

print("\n== chunking: spend spare MATCH budget to raise the byte ceiling ==\n")
# Fixed cost of the non-routing rules, read off golden/route-current.yaml:
# 4 name-path + 4 publisher-path + 2 path catch-alls = 10 rules, 10 matches.
FIXED_RULES, FIXED_MATCHES = 10, 10
RULE_CAP, ROUTE_CAP, RULES_CAP = 64, 128, 16
PATHS = 8
best = 0
for c in range(1, 40):
    matches = PATHS * c + c                       # rules[4] chunks + rules[11] chunks
    rules_needed = -(-(PATHS * c) // RULE_CAP) + 1   # ceil, plus the catch-all rule
    if FIXED_MATCHES + matches > ROUTE_CAP:
        break
    if FIXED_RULES + rules_needed > RULES_CAP:
        break
    best = c
print("  max chunks per path: %d" % best)
print("  adapters reachable:  %d  (%d x 297)" % (best * 297, best))
print("  cost: %d regexes to read instead of 1, with arbitrary split points" % best)

print("\n== what sorting buys ==\n")
unsorted_a = ["model-a", "sql-adapter", "chat-adapter"]
unsorted_b = ["model-a", "chat-adapter", "sql-adapter"]   # same SET, listed differently
print("  same adapters, different spec order:")
print("    %s" % pattern(unsorted_a, esc_minimal)[len(PREFIX):])
print("    %s" % pattern(unsorted_b, esc_minimal)[len(PREFIX):])
print("  -> different strings, so the route is rewritten and Envoy reprogrammed")
print("     for a change that altered nothing. Sorting makes the pattern a")
print("     function of the SET rather than the sequence.")
