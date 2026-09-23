#!/usr/bin/env python3
"""Score saved evidence, reparsing the actual response bodies for every request."""
import argparse
import collections
import json
import sys
from pathlib import Path


def samples(path, metric, label=None):
    return [float(line.rsplit(" ", 1)[1]) for line in path.read_text().splitlines()
            if (line.startswith(metric + "{") or line.startswith(metric + " "))
            and (label is None or label in line)]


def delta(directory, metric, label=None, prefix="epp"):
    return sum(samples(directory / f"{prefix}-after.prom", metric, label)) - sum(samples(directory / f"{prefix}-before.prom", metric, label))


def completion(raw, kind, models):
    """Return (valid completion, final usage). A status code alone proves neither."""
    try:
        if kind == "stream":
            data = [line[5:].strip() for line in raw.decode().splitlines() if line.startswith("data:")]
            if not data or data[-1] != "[DONE]" or data.count("[DONE]") != 1:
                return False, None
            chunks = [json.loads(value) for value in data[:-1]]
            valid = bool(chunks) and all(isinstance(c, dict) and c.get("model") in models and isinstance(c.get("choices"), list) for c in chunks)
            valid = valid and any(choice.get("finish_reason") is not None for c in chunks for choice in c["choices"])
            usages = [c["usage"] for c in chunks if c.get("usage") is not None]
            return valid, usages[-1] if usages else None
        body = json.loads(raw)
        choices = body.get("choices", [])
        valid = body.get("model") in models and bool(choices) and all(
            isinstance(c, dict) and c.get("finish_reason") is not None
            and (isinstance(c.get("message", {}).get("content"), str) or isinstance(c.get("text"), str)) for c in choices)
        return bool(valid), body.get("usage")
    except (ValueError, UnicodeError, AttributeError, TypeError, KeyError):
        return False, None


def empty(value):
    return value in (None, "", "-", "null")


def score(args):
    d = Path(args.directory)
    rows = json.loads((d / "requests.json").read_text())
    expected = json.loads((d / "expected.json").read_text())
    diag = json.loads((d / "diag.json").read_text())
    failures = []

    def check(condition, message):
        print(f"    {'ok' if condition else 'FAIL'} {message}")
        if not condition:
            failures.append(message)

    ids = [r["id"] for r in rows]
    wanted_ids = set(ids)
    access = []
    for line in (d / "gateway.log").read_text().splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("req_id") in wanted_ids:
            access.append(record)
    (d / "access.jsonl").write_text("".join(json.dumps(a) + "\n" for a in access))
    counts = collections.Counter(r["kind"] for r in rows)
    check(bool(rows) and counts == collections.Counter(expected), "all scheduled ordinary, SSE, fragmented and burst requests were recorded")
    check(len(wanted_ids) == len(rows), "unique request IDs")
    check(collections.Counter(a["req_id"] for a in access) == collections.Counter(ids), "exactly one access record for every request")
    check(all(r["status"] == args.status for r in rows), f"every request returned HTTP {args.status}")
    check(all(a.get("response_code") == args.status for a in access), "gateway and client status agree")
    check(bool(samples(d / "epp-after.prom", "llm_d_epp_ready_endpoints")), "EPP metrics scrape is present")
    picker = delta(d, "inference_extension_plugin_duration_seconds_count", 'extension_point="Picker"')
    wanted_picks = len(rows) if args.picks else 0
    check(picker == wanted_picks, f"EPP picker delta {picker:g}/{wanted_picks}, including SSE and burst")
    received = (d / "epp.log").read_text().count('"EPP received request"')
    check(received == wanted_picks, f"EPP received-request log count {received}/{wanted_picks}")
    check(all((not empty(a.get("ep_requested"))) == args.picks for a in access), "endpoint-pick metadata agrees for every request")
    if not args.picks:
        check(delta(d, "llm_d_epp_scheduler_attempts_total") == 0, "no scheduler attempts while EPP is bypassed or request rejected")
    check(diag["verdicts"]["EPP_ENGAGED"] == args.chain, f"filter-order prediction is {args.chain}")
    check(diag["verdicts"]["NO_DUPLICATES"] == "OK", "no duplicated filters")
    if args.after_ipp:
        i = diag["indices"]
        check(0 <= i["ipp_pre"] < i["auth"] < i["ipp"] < i["istio_ext_proc"] < i["router"], "ipp-pre < auth < ipp < EPP < router")

    valid, usages, empty_200 = [], [], []
    for row in rows:
        raw = (d / row["body_file"]).read_bytes()
        parsed, usage = completion(raw, row["kind"], (args.model_id, args.model_name))
        valid.append(parsed and row["complete"] and row["status"] == 200)
        usages.append(usage)
        if row["kind"] != "stream" and row["status"] == 200 and row["complete"] and not raw:
            empty_200.append(row["id"])
    if args.status == 200:
        check(all(a.get("model_hdr") == args.model_id for a in access), "model header correct on every request")
        check(all(a.get("route_name", "").startswith(args.route_prefix) and "-inference-pool-" in (a.get("upstream_cluster") or "") for a in access), "every request used the model's InferencePool route")
        if args.picks:
            check(all(a.get("ep_requested") == a.get("upstream_host") for a in access), "every selected endpoint equals the actual upstream")
        if args.responses == "complete":
            check(all(valid), f"all JSON/SSE responses complete and valid ({sum(valid)}/{len(rows)})")
        else:
            check(bool(empty_200), f"reproduced empty HTTP 200 completions ({len(empty_200)}/{len(rows)}); incomplete SSE recorded separately")
            check(all(r["complete"] for r in rows if r["kind"] != "stream"), "ordinary response defect is an empty completion, not a transport timeout")
    else:
        check(all(r["complete"] for r in rows), "rejections completed without client timeouts")
        check(all(empty(a.get("upstream_host")) for a in access), "rejected requests never reached a model")

    def pod_state(file):
        return {p["metadata"]["uid"]: [s["restartCount"] for s in p["status"].get("containerStatuses", [])]
                for p in json.loads(file.read_text())["items"]}
    check(pod_state(d / "pods-before.json") == pod_state(d / "pods-after.json"), "model and EPP pods did not restart or change during traffic")
    accounting = None
    if args.accounting:
        usage_ok = all(isinstance(u, dict) and all(type(u.get(k)) is int and u[k] >= 0 for k in ("prompt_tokens", "completion_tokens", "total_tokens"))
                       and u["prompt_tokens"] + u["completion_tokens"] == u["total_tokens"] for u in usages)
        check(usage_ok, "every response supplies consistent token usage, including SSE")
        namespace = args.route_prefix.rstrip(".").replace(".", "/", 1)
        label = f'limitador_namespace="{namespace}"'
        tokens = sum(u["total_tokens"] for u in usages) if usage_ok else None
        hits = delta(d, "authorized_hits", label, "limitador")
        calls = delta(d, "authorized_calls", label, "limitador")
        check(tokens is not None and tokens > 0 and hits == tokens, f"Limitador charged exactly the returned tokens ({hits:g}/{tokens})")
        check(calls == len(rows), f"Limitador admitted every request ({calls:g}/{len(rows)})")
        accounting = {"response_tokens": tokens, "charged_tokens": hits, "authorized_calls": calls}

    hosts = collections.Counter(a.get("upstream_host") for a in access)
    burst_ids = {r["id"] for r in rows if r["kind"] == "burst"}
    burst_hosts = collections.Counter(a.get("upstream_host") for a in access if a["req_id"] in burst_ids)
    summary = {"phase": args.phase, "requests": len(rows), "picker_delta": picker, "complete_responses": sum(valid),
               "empty_200": len(empty_200), "upstream_hosts": dict(hosts), "burst_hosts": dict(burst_hosts),
               "accounting": accounting, "failures": failures}
    (d / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    headline = f"{args.phase}: {'FAIL' if failures else 'PASS'}; {len(rows)} requests, {picker:g} picks, {sum(valid)} complete responses, {len(empty_200)} empty 200s"
    (d / "headline").write_text(headline + "\n")
    print(f"    distribution (observational): {dict(hosts)}; burst: {dict(burst_hosts)}")
    print(headline)
    return bool(failures)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase")
    parser.add_argument("directory")
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--route-prefix", required=True)
    parser.add_argument("--status", type=int, default=200)
    parser.add_argument("--chain", choices=("OK", "BROKEN"), required=True)
    parser.add_argument("--picks", action="store_true")
    parser.add_argument("--responses", choices=("complete", "empty"), default="complete")
    parser.add_argument("--after-ipp", action="store_true")
    parser.add_argument("--accounting", action="store_true")
    sys.exit(score(parser.parse_args()))
