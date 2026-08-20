#!/usr/bin/env python3
"""What does adding one adapter look like to a human?

The budget question is settled; this is the other half of it. An HTTPRoute is a
thing people review in a pull request, run `kubectl diff` against before
applying, and grep when routing does not work. Those are the operations that
decide whether a shape is pleasant to live with, and none of them appear in a
ceiling table.

Three questions, measured rather than asserted:

  1. diff size      adding ONE adapter, how much of the route changes?
  2. legibility     is the new adapter's name visible in that diff?
  3. greppability   can an operator answer "is sql-adapter routable?" from the
                    route object alone?

Rules mirror probe-ceiling.sh, restricted to the model-routing rules since the
path family is identical in every shape. Names are realistic rather than
generated: real adapters do not share a prefix, and generated ones flatter both
the byte count and the diff.
"""
import difflib
import re

import yaml

NS, MODEL = "lora-budget", "model-a"
HDR = "X-Gateway-Model-Name"
ENDPOINTS = ["/v1/completions", "/v1/chat/completions", "/v1/responses", "/v1/messages"]
PREFIX = "publishers/%s/models/" % NS
SAFE = re.compile(r"^[a-z0-9.-]+$")

BASE = ["sql-coder", "chat-tuned", "summarize-v2", "translate-de", "code-review",
        "json-mode", "safety-filter", "medical-qa"]


def adapters(n):
    """n realistic names. Padded by suffixing the seed list rather than
    generating a1..aN, because names that share a prefix understate both the
    byte count and how bad the diff looks."""
    out = []
    while len(out) < n:
        out += ["%s-%d" % (b, len(out) // len(BASE)) if len(out) >= len(BASE) else b
                for b in BASE[:n - len(out)]]
    return out[:n]


def esc(s):
    return s.replace(".", r"\.") if SAFE.match(s) else re.escape(s)


def render(shape, names):
    """The model-routing rules only, as YAML, for a given adapter list."""
    quoted = [PREFIX + n for n in [MODEL] + names]
    if shape == "current":
        rules = [{"name": "v1-model-routing",
                  "matches": [{"path": {"type": "Exact", "value": p},
                               "headers": [{"type": "Exact", "name": HDR, "value": v}]}
                              for ep in ENDPOINTS for p in (ep, ep + "/") for v in quoted]}]
    elif shape == "alternation":
        pat = esc(PREFIX) + "(" + "|".join(esc(n) for n in [MODEL] + names) + ")"
        rules = [{"name": "v1-model-routing",
                  "matches": [{"path": {"type": "Exact", "value": p},
                               "headers": [{"type": "RegularExpression", "name": HDR, "value": pat}]}
                              for ep in ENDPOINTS for p in (ep, ep + "/")]}]
    elif shape == "nested":
        pat = esc(PREFIX + MODEL) + "(/.*)?"
        rules = [{"name": "v1-model-routing",
                  "matches": [{"path": {"type": "Exact", "value": p},
                               "headers": [{"type": "RegularExpression", "name": HDR, "value": pat}]}
                              for ep in ENDPOINTS for p in (ep, ep + "/")]}]
    else:
        raise SystemExit("unknown shape " + shape)
    return yaml.safe_dump(rules, sort_keys=False, width=10 ** 6)


NEW = "sql-coder-v2"


def measure(shape, existing):
    before = render(shape, existing)
    after = render(shape, existing + [NEW])
    # autojunk=False matters enormously here. On a file of near-identical
    # blocks, SequenceMatcher's default heuristic discards any line occurring in
    # more than 1% of the input as "junk", and reports a scattered mess an order
    # of magnitude larger than the real edit. Myers, which git and kubectl use,
    # does not do that. Leaving it on turned a 56-line change into 495.
    sm = difflib.SequenceMatcher(None, before.splitlines(), after.splitlines(),
                                 autojunk=False)
    added, removed = [], []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ("replace", "delete"):
            removed += ["-" + l for l in before.splitlines()[i1:i2]]
        if tag in ("replace", "insert"):
            added += ["+" + l for l in after.splitlines()[j1:j2]]
    changed = sum(len(d) for d in added + removed)
    longest = max((len(l) for l in after.splitlines()), default=0)
    # "visible" means a reviewer can see the new name without horizontal scrolling
    # past a wall of unrelated text: it appears on a line short enough to read.
    visible = any(NEW in d and len(d) < 200 for d in added)
    return added, removed, changed, longest, visible


for n in (8, 100):
    print("Adding one adapter (%r) to a service that already has %d.\n" % (NEW, n))
    print("%-13s %8s %8s %9s %10s   %s"
          % ("shape", "lines+", "lines-", "bytes ch", "longest", "new name legible in the diff?"))
    for shape in ("current", "alternation", "nested"):
        added, removed, changed, longest, visible = measure(shape, adapters(n))
        verdict = ("yes" if visible else
                   "no: buried in a %d-byte line" % longest if any(NEW in d for d in added) else
                   "absent entirely")
        print("%-13s %8d %8d %9d %10d   %s"
              % (shape, len(added), len(removed), changed, longest, verdict))
    print()

AT = adapters(100)

print("-- what a reviewer sees, at 100 adapters --")
for shape in ("current", "alternation", "nested"):
    added, removed, _, _, _ = measure(shape, AT)
    print("\n%s:" % shape)
    if not added and not removed:
        print("    (no change at all: adding an adapter does not touch the route)")
        continue
    for d in (added + removed)[:3]:
        print("    %s" % (d if len(d) <= 92 else d[:89] + "..."))
    extra = len(added) + len(removed) - 3
    if extra > 0:
        print("    ... %d more" % extra)

print("\n-- can an operator answer 'is %s routable?' from the route object --" % NEW)
for shape in ("current", "alternation", "nested"):
    after = render(shape, AT + [NEW])
    hits = [l for l in after.splitlines() if NEW in l]
    if not hits:
        verdict = "NO: the name never appears in the route at all"
    elif max(len(h) for h in hits) < 200:
        verdict = "yes: %d lines, each readable" % len(hits)
    else:
        verdict = "grep matches, but hands back a %d-byte line" % max(len(h) for h in hits)
    print("    %-13s %s" % (shape, verdict))
