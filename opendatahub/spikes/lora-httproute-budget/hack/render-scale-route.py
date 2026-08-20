#!/usr/bin/env python3
"""A full-size alternation on either data plane, in either escaping form.

Two things this settles that the small anchoring route cannot:

  * does a 4KB pattern actually PROGRAM, or does it validate and then get
    silently dropped by the proxy? A route that applies but never matches is the
    failure mode worth ruling out, and it is invisible from the CRD side.
  * is the minimal-escape form (320 adapters) accepted, and does it anchor the
    same way the re.escape form (297) does?

  render-scale-route.py <istio|kgw|eg> <full|minimal|distinct|realistic|longns> <adapters>

`distinct` is the honest case. RE2 factors shared prefixes when it compiles, so
synthetic names like adapter-a1..adapter-a280 produce a far smaller program than
their count suggests. Real adapter names do not rhyme, so this mode generates
names with no common prefix and measures what a data plane with a program-size
limit would actually allow.
"""
import re
import sys

import yaml

NS = "lora-budget"
HDR = "X-Gateway-Model-Name"
prefix = "publishers/%s/models/" % NS
SAFE = re.compile(r"^[a-z0-9.-]+$")

target, form, n = sys.argv[1], sys.argv[2], int(sys.argv[3])


def esc(s):
    if form in ("minimal", "distinct"):
        return s.replace(".", r"\.") if SAFE.match(s) else re.escape(s)
    return re.escape(s)


# Names taken from what real deployments look like rather than what is convenient
# to generate. The pattern is just a string matched against a header value we
# control, so the fixture namespace stays as it is and only the CONTENT is
# realistic - which is the part the byte count and RE2 program size depend on.
PROFILES = {
    "realistic": ("genai-serving", "granite-3-1-8b-instruct",
                  ["sql-generation", "customer-support", "summarizer-legal",
                   "code-review-tuned", "translation-de-en", "sentiment-finance"]),
    "longns": ("redhat-ods-applications", "llama-3-1-8b-instruct",
               ["customer-support-tuned-v2", "sql-generation-finetune",
                "document-summarizer-v3", "legal-clause-extractor",
                "support-triage-classifier", "de-en-translator-v2"]),
}

if form in PROFILES:
    pns, pbase, padapters = PROFILES[form]
    prefix = "publishers/%s/models/" % pns
    tails = [pbase] + [padapters[i % len(padapters)] + ("" if i < len(padapters) else "-%d" % i)
                       for i in range(n)]
elif form == "distinct":
    # Deterministic, no shared prefix: cycles the leading letters so RE2 cannot
    # factor the alternation down to one branch.
    import string
    al = string.ascii_lowercase
    tails = ["model-a"] + ["%s%s%s-lora%d" % (al[i % 26], al[(i // 26) % 26],
                                              al[(i // 676) % 26], i)
                           for i in range(1, n + 1)]
else:
    tails = ["model-a"] + ["adapter-a%d" % i for i in range(1, n + 1)]
pattern = esc(prefix) + "(" + "|".join(esc(t) for t in tails) + ")"

PARENTS = {
    "istio": {"name": "kserve-ingress-gateway", "namespace": "kserve"},
    "kgw":   {"name": "kgw", "namespace": NS},
    "eg":    {"name": "eg", "namespace": NS},
}
parent = dict(PARENTS[target], group="gateway.networking.k8s.io", kind="Gateway")

print(yaml.safe_dump({
    "apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
    "metadata": {"name": "scale-%s" % target, "namespace": NS,
                 "annotations": {"spike/bytes": str(len(pattern)), "spike/form": form,
                                 "spike/adapters": str(n)}},
    "spec": {"parentRefs": [parent],
             "rules": [
                 {"name": "alternation",
                  "backendRefs": [{"kind": "Service", "name": "echo-pool",
                                   "port": 8000, "weight": 1}],
                  "matches": [{"path": {"type": "PathPrefix", "value": "/scale"},
                               "headers": [{"type": "RegularExpression",
                                            "name": HDR, "value": pattern}]}]},
                 {"name": "terminal",
                  "backendRefs": [{"kind": "Service", "name": "echo-service",
                                   "port": 8000, "weight": 1}],
                  "matches": [{"path": {"type": "PathPrefix", "value": "/scale"}}]},
             ]}}, sort_keys=False))
