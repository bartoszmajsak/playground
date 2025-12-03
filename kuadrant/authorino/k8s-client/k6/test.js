import http from "k6/http";
import { check } from "k6";
import { Rate } from "k6/metrics";

const successRate = new Rate("success_rate");

const TOKEN = __ENV.TOKEN;
const KUADRANT_GATEWAY_URL = __ENV.KUADRANT_GATEWAY_URL;

if (!TOKEN) {
    throw new Error("TOKEN environment variable is required");
}

if (!KUADRANT_GATEWAY_URL) {
    throw new Error("KUADRANT_GATEWAY_URL environment variable is required");
}

export const options = {
    vus: __ENV.VUS ? parseInt(__ENV.VUS) : 10,
    iterations: __ENV.ITERATIONS ? parseInt(__ENV.ITERATIONS) : 1000,

    thresholds: {
        http_req_duration: ["p(95)<5000"],
        http_req_failed: ["rate<0.1"],
        success_rate: ["rate>0.9"],
    },
};

export default function () {
    const url = `http://${KUADRANT_GATEWAY_URL}/toy`;

    const params = {
        headers: {
            Authorization: `Bearer ${TOKEN}`,
            Host: "api.toystore.com",
        },
    };

    const response = http.get(url, params);

    const passed = check(response, {
        "status is 200": (r) => r.status === 200,
    });

    successRate.add(passed);
}
