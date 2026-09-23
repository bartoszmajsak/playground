#!/usr/bin/env python3
"""Send tagged requests and retain every response, including partial streams."""
import argparse
import concurrent.futures
import http.client
import json
import os
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit


def send(args):
    out = Path(args.directory)
    out.mkdir(parents=True, exist_ok=True)
    url = urlsplit(os.environ["GW_URL"])
    model = os.environ["MODEL_ID"]
    run_id = uuid.uuid4().hex[:12]

    def request(kind, number):
        rid = f"{args.phase}-{run_id}-{kind}-{number}"
        prefix = (f"Experiment {run_id}. " + "The quick brown fox jumps over the lazy dog. " * 40) if kind == "burst" else ""
        payload = {"model": model, "messages": [{"role": "user", "content": prefix + f"Explain rivers. Question {number}."}],
                   "max_tokens": 32 if kind == "burst" else 8}
        if kind == "stream":
            payload.update(stream=True, stream_options={"include_usage": True})
        body = json.dumps(payload).encode()
        headers = {"Content-Type": "application/json", "x-req-id": rid}
        if args.auth != "none":
            headers["Authorization"] = "Bearer " + (os.environ["API_KEY"] if args.auth == "valid" else "invalid-spike-key")
        cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
        conn = cls(url.hostname, url.port, timeout=args.timeout)
        record = {"id": rid, "kind": kind, "status": None, "complete": False, "body_file": rid + ".body"}
        raw = bytearray()
        start = time.monotonic()
        try:
            path = url.path.rstrip("/") + "/v1/chat/completions"
            if kind == "fragment":
                conn.putrequest("POST", path)
                for key, value in headers.items():
                    conn.putheader(key, value)
                conn.putheader("Transfer-Encoding", "chunked")
                conn.endheaders()
                split = len(body) // 2
                for part in (body[:split], body[split:]):
                    conn.send(f"{len(part):x}\r\n".encode() + part + b"\r\n")
                    time.sleep(0.15)
                conn.send(b"0\r\n\r\n")
            else:
                conn.request("POST", path, body, headers)
            response = conn.getresponse()
            record.update(status=response.status, content_type=response.getheader("content-type"))
            while chunk := response.read1(65536):
                raw.extend(chunk)
            record["complete"] = True
        except (OSError, http.client.HTTPException) as exc:
            if isinstance(exc, http.client.IncompleteRead):
                raw.extend(exc.partial)
            record["error"] = str(exc)
        finally:
            conn.close()
        (out / record["body_file"]).write_bytes(raw)
        record.update(bytes=len(raw), elapsed_seconds=round(time.monotonic() - start, 3))
        return record

    rows = [request("single", i) for i in range(1, args.requests + 1)]
    for kind, count in (("stream", args.streams), ("fragment", args.fragments)):
        rows.extend(request(kind, i) for i in range(1, count + 1))
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        rows.extend(pool.map(lambda i: request("burst", i), range(1, args.burst + 1)))
    (out / "requests.json").write_text(json.dumps(rows, indent=2) + "\n")
    (out / "expected.json").write_text(json.dumps({"single": args.requests, "stream": args.streams,
                                                  "fragment": args.fragments, "burst": args.burst}, indent=2) + "\n")
    print(f"{args.phase}: sent {len(rows)} requests; retained all response bodies", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase")
    parser.add_argument("directory")
    parser.add_argument("--requests", type=int, default=20)
    parser.add_argument("--streams", type=int, default=1)
    parser.add_argument("--fragments", type=int, default=1)
    parser.add_argument("--burst", type=int, default=12)
    parser.add_argument("--concurrency", type=int, default=6)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--auth", choices=("valid", "none", "invalid"), default="valid")
    args = parser.parse_args()
    if min(args.requests, args.streams, args.fragments, args.burst) < 0 or args.concurrency < 1:
        parser.error("request counts must be nonnegative and concurrency positive")
    send(args)
