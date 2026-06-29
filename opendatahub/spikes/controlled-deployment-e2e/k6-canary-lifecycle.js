// Continuous traffic generator for canary rollout validation.
//
// Sends requests at a steady rate while the cluster state changes externally.
// Logs x-served-by attribution per request. The companion validate-canary.sh
// script orchestrates weight changes and analyzes the output for zero-downtime
// violations.
//
// Usage:
//   k6 run --out json=traffic.jsonl \
//     -e GATEWAY_URL=http://172.18.255.200 \
//     -e NAMESPACE=controlled-deployment-spike \
//     -e MODEL=tiny-llama \
//     -e DURATION=180s \
//     -e RATE=2 \
//     k6-canary-lifecycle.js

import http from "k6/http";
import { check } from "k6";
import { Rate, Trend, Counter } from "k6/metrics";

const gatewayUrl = __ENV.GATEWAY_URL || "http://172.18.255.200";
const ns = __ENV.NAMESPACE || "controlled-deployment-spike";
const model = __ENV.MODEL || "tiny-llama";
const rate = parseInt(__ENV.RATE || "2");
const duration = __ENV.DURATION || "180s";

const errorRate = new Rate("request_errors");
const servedByV1 = new Counter("served_by_v1");
const servedByV2 = new Counter("served_by_v2");
const servedByUnknown = new Counter("served_by_unknown");
const requestLatency = new Trend("request_latency_ms");

export const options = {
  scenarios: {
    steady_traffic: {
      executor: "constant-arrival-rate",
      rate: rate,
      timeUnit: "1s",
      duration: duration,
      preAllocatedVUs: 5,
      maxVUs: 20,
    },
  },
  thresholds: {
    request_errors: [{ threshold: "rate<0.02", abortOnFail: false }],
  },
};

export default function () {
  const url = `${gatewayUrl}/v1/completions`;
  const payload = JSON.stringify({
    model: model,
    prompt: "Hello",
    max_tokens: 5,
  });

  const params = {
    headers: {
      "Content-Type": "application/json",
      "X-Gateway-Model-Name": `publishers/${ns}/models/${model}`,
    },
    timeout: "30s",
  };

  const res = http.post(url, payload, params);
  const servedBy = res.headers["X-Served-By"] || res.headers["x-served-by"] || "";

  requestLatency.add(res.timings.duration);

  const ok = check(res, {
    "status is 200": (r) => r.status === 200,
  });

  if (!ok) {
    errorRate.add(1);
    console.log(`ERROR ts=${Date.now()} status=${res.status} latency=${res.timings.duration}ms`);
  } else {
    errorRate.add(0);
  }

  if (servedBy.includes("v1")) {
    servedByV1.add(1);
  } else if (servedBy.includes("v2")) {
    servedByV2.add(1);
  } else {
    servedByUnknown.add(1);
  }

  console.log(
    `ts=${Date.now()} served_by=${servedBy || "none"} status=${res.status} latency=${Math.round(res.timings.duration)}ms`
  );
}
