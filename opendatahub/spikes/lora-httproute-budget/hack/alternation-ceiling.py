#!/usr/bin/env python3
"""How many adapters fit in one alternation, by name length and escaping form.

The binding constraint depends on the data plane:

  * HTTPHeaderMatch.Value has maxLength 4096 in the Gateway API CRD. That is a
    hard apiserver limit and applies everywhere.
  * Envoy additionally refuses a regex whose compiled RE2 program exceeds
    re2.max_program_size.error_level. Istio sets 32768, Envoy Gateway sets
    4294967295 (i.e. off), kgateway leaves it unset and gets Envoy's default 100.

So on Istio and Envoy Gateway the 4096-byte cap binds; on kgateway the RE2 limit
binds long before it. Both are byte-driven, which is why the answer is a function
of name length rather than a single headline number.

Superseded golden/realistic-names.tsv's 188/147, which did not correspond to
either escaping form and had no recorded derivation.
"""
CAP = 4096
import re
SAFE = re.compile(r"^[a-z0-9.-]+$")

def esc_full(s):
    """What ships today: re.escape, which also escapes '-'. Adapter names are
    full of hyphens, so this is not a rounding error."""
    return re.escape(s)

def esc_min(s):
    """Escape only what RE2 needs. DNS-1123 names contain nothing else special."""
    return s.replace(".", r"\.") if SAFE.match(s) else re.escape(s)

def name(length, i):
    """A name of exactly `length` characters, hyphenated the way real ones are."""
    word = "abcdefg"
    out = []
    while len("-".join(out)) < length:
        out.append(word)
    s = "-".join(out)[:length].rstrip("-")
    return (s[:-len(str(i))] + str(i)) if len(str(i)) < len(s) else s

def pattern(ns, base_len, ad_len, n, esc):
    tails = [name(base_len, 0)] + [name(ad_len, i) for i in range(1, n + 1)]
    return esc("publishers/%s/models/" % ns) + "(" + "|".join(esc(t) for t in tails) + ")"

def ceiling(ns, base_len, ad_len, esc, cap=CAP):
    n = 0
    while len(pattern(ns, base_len, ad_len, n + 1, esc)) <= cap:
        n += 1
        if n > 5000:
            break
    return n

NS = [("genai-serving", "13-char namespace"),
      ("redhat-ods-applications", "23-char namespace")]

print("adapters in ONE alternation, bound by the 4096-byte header value cap")
print("(Istio and Envoy Gateway. kgateway is bound by RE2 instead, see below.)\n")
for ns, label in NS:
    print("  %s, base model 23 chars" % label)
    print("    %-22s %12s %12s %8s" % ("mean adapter name", "re.escape", "minimal", "gain"))
    for ad in (12, 16, 20, 24, 30, 40):
        a = ceiling(ns, 23, ad, esc_full)
        b = ceiling(ns, 23, ad, esc_min)
        mark = "   <- typical" if ad in (16, 20) else ""
        print("    %-22s %12d %12d %+8d%s" % ("%d chars" % ad, a, b, b - a, mark))
    print()

print("where kgateway lands, same names, RE2 program-size limit 100")
print("(program size tracks pattern bytes at about 0.87x + 8, fitted to three")
print(" rejections measured off the kgw proxy: 114B->107, 126B->117, 151B->139)\n")
prog = lambda b: 0.865 * b + 8.4
for ns, label in NS:
    got = 0
    for n in range(1, 40):
        if prog(len(pattern(ns, 23, 18, n, esc_full))) > 100:
            break
        got = n
    print("  %-22s %d adapters" % (label + ",", got))

print("\nthe RE2 limit kgateway would need to reach the byte ceiling")
for ns, label in NS:
    n = ceiling(ns, 23, 18, esc_full)
    print("  %-22s %4d adapters needs program size >= %d" % (label + ",", n,
          int(prog(len(pattern(ns, 23, 18, n, esc_full)))) + 1))
