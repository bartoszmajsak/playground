#!/usr/bin/env python3
"""Scores one scenario's evidence directory.

Usage: score.py <scenario> <dir> --requests N --model-id ID --route-prefix P [--smoke]

Reads diag.json, traffic.tsv, epp-before.prom, epp-after.prom and access.jsonl
as written by validate.sh, prints one line per failed check, writes <dir>/headline
and exits with the number of failures. Every claim is made from a file on disk,
never from the live cluster, so a surprising verdict can be re-derived.
"""
import argparse
import json
import re
import sys
from pathlib import Path

FAILURES = 0


def check(cond, msg):
    global FAILURES
    if cond:
        print(f"    ok   {msg}")
    else:
        FAILURES += 1
        print(f"    FAIL {msg}")
    return cond


def picker_total(text):
    total = 0
    for line in text.splitlines():
        if line.startswith("inference_extension_plugin_duration_seconds_count{") and re.search(r'extension_point="Picker"[,}]', line):
            total += float(line.rsplit(" ", 1)[1])
    return int(total)


def sched_total(text):
    return int(sum(float(l.rsplit(" ", 1)[1]) for l in text.splitlines()
                   if l.startswith("llm_d_epp_scheduler_attempts_total{")))


def family_present(text, family):
    return any(l.startswith(family + "{") or l.startswith(family + " ") for l in text.splitlines())


def empty_md(v):
    return v in (None, "", "-", "null")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("dir")
    ap.add_argument("--requests", type=int, required=True)
    ap.add_argument("--model-id", required=True)
    ap.add_argument("--route-prefix", required=True)
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args()
    d = Path(args.dir)
    n = args.requests

    diag = json.loads((d / "diag.json").read_text())
    verdict = diag["verdicts"]["EPP_ENGAGED"]
    rows = [l.split("\t") for l in (d / "traffic.tsv").read_text().splitlines() if l.strip()]
    codes = [r[1] for r in rows]
    before = (d / "epp-before.prom").read_text()
    after = (d / "epp-after.prom").read_text()
    picker_delta = picker_total(after) - picker_total(before)
    sched_delta = sched_total(after) - sched_total(before)
    access = []
    for line in (d / "access.jsonl").read_text().splitlines():
        try:
            access.append(json.loads(line))
        except ValueError:
            pass

    # --- evidence, before any check: what the gateway looked like and what the
    # requests did, so a verdict never stands alone.
    idx = diag.get("indices", {})
    chain = diag.get("chain", [])
    marks = {idx.get("istio_ext_proc"): "*", idx.get("ipp_pre"): "*", idx.get("ipp"): "*", idx.get("auth"): "*"}
    short = [("[%d]%s%s" % (i + 1, f.replace("envoy.filters.http.", ""), marks.get(i, ""))) for i, f in enumerate(chain)]
    print("    evidence")
    print("      chain: " + " ".join(short))
    print(f"      verdict: EPP_ENGAGED={verdict}: {diag.get('notes', {}).get('EPP_ENGAGED', '')}")
    hit = {}
    for a in access:
        key = (a.get("route_name"), (a.get("upstream_cluster") or "").rstrip(";"))
        hit[key] = hit.get(key, 0) + 1
    pickers = {r["name"]: r.get("picker") for r in diag.get("routes", []) if r.get("name")}
    for (rn, cl), c in sorted(hit.items(), key=lambda kv: -kv[1]):
        print(f"      route hit x{c}: {rn} -> {cl or '-'}; picker override -> {pickers.get(rn) or 'NONE'}")
    hosts = {}
    for a in access:
        hosts[a.get("upstream_host") or "-"] = hosts.get(a.get("upstream_host") or "-", 0) + 1
    picks = {}
    for a in access:
        k = a.get("ep_requested") if not empty_md(a.get("ep_requested")) else "none"
        picks[k] = picks.get(k, 0) + 1
    print(f"      responses: " + ", ".join(f"{c} x{codes.count(c)}" for c in sorted(set(codes))))
    print("      upstream hosts: " + ", ".join(f"{h} x{c}" for h, c in sorted(hosts.items())))
    print("      ep_requested (EPP pick): " + ", ".join(f"{h} x{c}" for h, c in sorted(picks.items())))
    print(f"      EPP picker counter: {picker_total(before)} -> {picker_total(after)} (delta {picker_delta}); scheduler attempts delta {sched_delta}")
    # What the EPP saw from the model servers: the pool-level gauges GIE
    # derives from the vLLM metrics it scrapes. Flat zeros on the simulator,
    # live numbers on vLLM.
    for fam, label in (("inference_pool_average_kv_cache_utilization", "avg kv-cache utilisation"),
                       ("inference_pool_average_queue_size", "avg queue size"),
                       ("inference_pool_ready_pods", "ready pods")):
        vals = [l.rsplit(" ", 1)[1] for l in after.splitlines() if l.startswith(fam + "{") or l.startswith(fam + " ")]
        if vals:
            print(f"      EPP-scraped pool {label} (after): {', '.join(vals)}")
    cfg = d / "epp-config.yaml"
    if cfg.exists() and cfg.stat().st_size:
        weights = re.findall(r"pluginRef:\s*(\S+)\s*\n\s*weight:\s*(\S+)", cfg.read_text())
        if weights:
            print("      EPP scorers: " + ", ".join(f"{p}={w}" for p, w in weights))
    epp_log = (d / "epp.log").read_text() if (d / "epp.log").exists() else ""
    epp_received = epp_log.count('"EPP received request"')
    epp_sent = epp_log.count('"EPP sent request body response(s) to proxy"')
    print(f"      EPP log in the window: {epp_received} x 'EPP received request', {epp_sent} x 'sent request body response'")

    # --- same-prefix burst: where an engaged prefix-cache scorer pins, and
    # what vLLM's own prefix cache saw.
    prows = [l.split("\t") for l in (d / "traffic-prefix.tsv").read_text().splitlines()] if (d / "traffic-prefix.tsv").exists() else []
    paccess = []
    if (d / "access-prefix.jsonl").exists():
        for line in (d / "access-prefix.jsonl").read_text().splitlines():
            try:
                paccess.append(json.loads(line))
            except ValueError:
                pass
    top_share = None
    if paccess:
        ph = {}
        for a in paccess:
            ph[a.get("upstream_host") or "-"] = ph.get(a.get("upstream_host") or "-", 0) + 1
        top_share = max(ph.values()) / len(paccess)
        print(f"      same-prefix burst ({len(prows)} requests, {', '.join(f'{c} x{[r[1] for r in prows].count(c)}' for c in sorted({r[1] for r in prows}))}): "
              + ", ".join(f"{h} x{c}" for h, c in sorted(ph.items())) + f"; top pod share {top_share:.0%}")

    def vllm_delta(pod_file_before, pod_file_after, family):
        def total(text):
            return sum(float(l.rsplit(" ", 1)[1]) for l in text.splitlines() if l.startswith(family + "{") or l.startswith(family + " "))
        return total(pod_file_after) - total(pod_file_before)

    def gauge(text, family):
        vals = [float(l.rsplit(" ", 1)[1]) for l in text.splitlines() if l.startswith(family + "{") or l.startswith(family + " ")]
        return max(vals) if vals else None

    prefix_hits_total = 0.0
    for pb in sorted(d.glob("vllm-*-prefix-before.prom")):
        pod = pb.name[len("vllm-"):-len("-prefix-before.prom")]
        pa = d / f"vllm-{pod}-prefix-after.prom"
        if not pa.exists():
            continue
        b, a = pb.read_text(), pa.read_text()
        served = vllm_delta(b, a, "vllm:request_success_total")
        hits = vllm_delta(b, a, "vllm:prefix_cache_hits_total")
        queries = vllm_delta(b, a, "vllm:prefix_cache_queries_total")
        prefix_hits_total += hits
        kv = gauge(a, "vllm:kv_cache_usage_perc")
        kv_s = f"{kv:.3f}" if kv is not None else "n/a"
        print(f"      vLLM {pod}: served {served:.0f} of the burst, prefix-cache hits {hits:.0f}/{queries:.0f} tokens, kv_cache_usage_perc now {kv_s}")
    print("    checks")

    check(len(rows) == n, f"{n} requests sent ({len(rows)} recorded)")
    check(family_present(after, "llm_d_epp_ready_endpoints"), "EPP scrape carries llm_d_epp_ready_endpoints (scrape sanity)")
    check(len(access) == n, f"{n} access-log lines for this scenario ({len(access)} found)")

    s = args.scenario
    if s in ("defect", "fix", "control"):
        check(all(c == "200" for c in codes), f"every request returned 200 (got {sorted(set(codes))})")
        check(all(a.get("route_name", "").startswith(args.route_prefix) for a in access),
              f"every request served by an HTTPRoute rule of {args.route_prefix}*")
        check(all("-inference-pool-" in a.get("upstream_cluster", "") for a in access),
              "every request went to the InferencePool cluster")
        check(all(a.get("model_hdr") == args.model_id for a in access),
              f"X-Gateway-Model-Name was {args.model_id} on every request (ipp-pre ran)")

    why = diag.get("notes", {}).get("EPP_ENGAGED", "")
    if s == "defect":
        check(verdict == "BROKEN", f"chain order predicts a bypassed EPP: EPP_ENGAGED={verdict} ({why})")
        check(picker_delta == 0, f"EPP picker was never invoked (delta {picker_delta})")
        check(epp_received == 0, f"EPP log shows no request in the window ({epp_received} received)")
        check(sched_delta == 0, f"EPP scheduler attempts unchanged (delta {sched_delta})")
        check(all(empty_md(a.get("ep_requested")) for a in access), "no request carried an endpoint pick (ep_requested empty)")
        hosts = {a.get("upstream_host") for a in access}
        if not args.smoke:
            check(len(hosts) >= 2, f"requests spread across the pool without a picker ({len(hosts)} upstream hosts)")
        burst = f", same-prefix burst {top_share:.0%} on one pod" if top_share is not None else ""
        headline = (f"defect: EPP bypassed - chain {verdict}, picker delta {picker_delta}/{n + len(prows)}, "
                    f"{len(hosts)} upstream hosts, all {sorted(set(codes))}{burst}")
    elif s in ("fix", "control"):
        check(verdict == "OK", f"chain order predicts an engaged EPP: EPP_ENGAGED={verdict} ({why})")
        check(diag["verdicts"]["NO_DUPLICATES"] == "OK", "no duplicated ext_proc filters after the patch")
        check(picker_delta == n + len(prows), f"EPP picker invoked once per request, burst included (delta {picker_delta}/{n + len(prows)})")
        check(epp_received >= n, f"EPP log shows the requests ({epp_received} received in the window)")
        if top_share is not None and not args.smoke:
            check(top_share >= 0.5, f"prefix-cache scorer pinned the same-prefix burst (top pod share {top_share:.0%})")
            check(prefix_hits_total > 0, f"vLLM reports prefix-cache hits for the burst ({prefix_hits_total:.0f} tokens)")
        check(all(not empty_md(a.get("ep_requested")) for a in access), "every request carried an endpoint pick (ep_requested set)")
        # The proxy's own statement of where the request went. Istio 1.29's
        # Envoy does not emit the "-served" metadata; upstream_host carries the
        # same fact on every version.
        if any(not empty_md(a.get("ep_served")) for a in access):
            check(all(a.get("ep_requested") == a.get("ep_served") for a in access),
                  "every pick was honoured (ep_requested == ep_served)")
        else:
            check(all(a.get("ep_requested") == a.get("upstream_host") for a in access),
                  "every pick was honoured (upstream_host == ep_requested; no ep_served metadata on this Istio)")
        label = "fix: EPP engaged" if s == "fix" else "control: EPP engaged without a fix"
        burst = f", same-prefix burst {top_share:.0%} on one pod" if top_share is not None else ""
        headline = f"{label} - chain {verdict}, picker delta {picker_delta}/{n + len(prows)}, all {sorted(set(codes))}{burst}"
    elif s == "auth-order":
        check(all(c == "401" for c in codes), f"unauthenticated requests rejected with 401 (got {sorted(set(codes))})")
        check(picker_delta == n, f"EPP picker still invoked for every unauthenticated request (delta {picker_delta}/{n})")
        check(all(not empty_md(a.get("ep_requested")) for a in access), "each rejected request already carried an endpoint pick")
        headline = (f"auth-order: with the fix the EPP runs before Kuadrant auth - "
                    f"{n} unauthenticated requests got 401 and still cost {picker_delta} picks")
    else:
        print(f"unknown scenario {s}", file=sys.stderr)
        return 2

    (d / "headline").write_text(headline + "\n")
    print(f"    => {headline}")
    return FAILURES


if __name__ == "__main__":
    sys.exit(main())
