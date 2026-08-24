#!/usr/bin/env python3
"""Deterministic realistic adapter names — the realistic-v1 naming fixture.

This mirrors, name for name, the fixture committed to KServe at
pkg/controller/v1alpha2/llmisvc/testdata/lora-adapter-names-realistic-v1.txt.
The capacity claim is bound to this exact list (design Q35); regenerating it is
an explicit, reviewed action in both places.

Usage: gen-names.py COUNT   # prints the first COUNT names, one per line
"""

import sys

TEAMS = ["billing", "support", "legal", "medical", "finance",
         "retail", "travel", "gaming", "search", "devops"]
TASKS = ["summarize", "classify", "extract", "rerank", "translate",
         "redact", "triage", "dedupe", "qa", "tone"]
LANGS = ["en", "de", "fr", "es", "pl", "ja", "ko", "pt", "it", "nl"]


def names(count: int):
    out = []
    for i in range(count):
        name = f"{TEAMS[i % 10]}-{TASKS[(i // 10) % 10]}-{LANGS[(i * 7) % 10]}-v{1 + (i % 4)}"
        if i % 7 == 0:
            name = "acme/" + name
        if i % 9 == 0:
            name = name + ".r16"
        out.append(name)
    assert len(set(out)) == count, "fixture names must be unique"
    return out


if __name__ == "__main__":
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    print("\n".join(names(count)))
