import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';

const BASE_URL = (__ENV.BASE_URL || '').replace(/\/+$/, '');
if (!BASE_URL) {
  throw new Error('BASE_URL is required. Example: BASE_URL=http://10.96.1.100 k6 run validate-k6.js');
}

const MODEL_HEADER = __ENV.MODEL_HEADER || 'X-Gateway-Model-Name';
const MODEL_VALUE = __ENV.MODEL_VALUE || 'publishers/route-validation/models/test-model';
const PUBLISHER_PATH = __ENV.PUBLISHER_PATH || '/publishers/route-validation/models/test-model';
const REQUEST_TIMEOUT = __ENV.ROUTE_VALIDATION_K6_REQUEST_TIMEOUT || '5s';
const DURATION = __ENV.ROUTE_VALIDATION_K6_DURATION || '30s';

const SPLIT_90_MIN = parseFloatEnv('ROUTE_VALIDATION_SPLIT_90_MIN', 82) / 100;
const SPLIT_90_MAX = parseFloatEnv('ROUTE_VALIDATION_SPLIT_90_MAX', 97) / 100;
const HEADER_VUS = parseIntEnv('ROUTE_VALIDATION_K6_HEADER_VUS', 20);
const PUBLISHER_VUS = parseIntEnv('ROUTE_VALIDATION_K6_PUBLISHER_VUS', 20);
const DIRECT_V1_VUS = parseIntEnv('ROUTE_VALIDATION_K6_DIRECT_V1_VUS', 10);
const DIRECT_V2_VUS = parseIntEnv('ROUTE_VALIDATION_K6_DIRECT_V2_VUS', 10);

const requestErrors = new Rate('request_errors');
const headerV1Share = new Rate('header_v1_share');
const publisherV1Share = new Rate('publisher_v1_share');
const directV1Pinned = new Rate('direct_v1_pinned');
const directV2Pinned = new Rate('direct_v2_pinned');

const headerV1Count = new Counter('header_v1_count');
const headerV2Count = new Counter('header_v2_count');
const publisherV1Count = new Counter('publisher_v1_count');
const publisherV2Count = new Counter('publisher_v2_count');
const directV1Count = new Counter('direct_v1_count');
const directV2Count = new Counter('direct_v2_count');
const unknownBodyCount = new Counter('unknown_body_count');

function parseIntEnv(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') {
    return fallback;
  }
  const value = Number.parseInt(raw, 10);
  if (Number.isNaN(value) || value <= 0) {
    return fallback;
  }
  return value;
}

function parseFloatEnv(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') {
    return fallback;
  }
  const value = Number.parseFloat(raw);
  if (Number.isNaN(value)) {
    return fallback;
  }
  return value;
}

if (SPLIT_90_MIN >= SPLIT_90_MAX) {
  throw new Error(
    `Invalid split bounds: ROUTE_VALIDATION_SPLIT_90_MIN (${SPLIT_90_MIN}) must be < ROUTE_VALIDATION_SPLIT_90_MAX (${SPLIT_90_MAX})`,
  );
}

export const options = {
  scenarios: {
    header_parallel: {
      executor: 'constant-vus',
      exec: 'headerScenario',
      vus: HEADER_VUS,
      duration: DURATION,
      tags: { pattern: 'header' },
    },
    publisher_parallel: {
      executor: 'constant-vus',
      exec: 'publisherScenario',
      vus: PUBLISHER_VUS,
      duration: DURATION,
      tags: { pattern: 'publisher' },
    },
    direct_v1_parallel: {
      executor: 'constant-vus',
      exec: 'directV1Scenario',
      vus: DIRECT_V1_VUS,
      duration: DURATION,
      tags: { pattern: 'direct-v1' },
    },
    direct_v2_parallel: {
      executor: 'constant-vus',
      exec: 'directV2Scenario',
      vus: DIRECT_V2_VUS,
      duration: DURATION,
      tags: { pattern: 'direct-v2' },
    },
  },
  thresholds: {
    checks: ['rate>0.99'],
    http_req_failed: ['rate<0.05'],
    request_errors: ['rate<0.05'],
    header_v1_share: [`rate>=${SPLIT_90_MIN}`, `rate<=${SPLIT_90_MAX}`],
    publisher_v1_share: [`rate>=${SPLIT_90_MIN}`, `rate<=${SPLIT_90_MAX}`],
    direct_v1_pinned: ['rate==1'],
    direct_v2_pinned: ['rate==1'],
  },
  summaryTrendStats: ['avg', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

function classifyBackend(body) {
  if (typeof body !== 'string') {
    return 'unknown';
  }
  if (body.includes('v1')) {
    return 'v1';
  }
  if (body.includes('v2')) {
    return 'v2';
  }
  return 'unknown';
}

function evaluateResponse(resp) {
  const statusOk = resp.status === 200;
  const backend = classifyBackend(resp.body);
  const backendKnown = backend !== 'unknown';
  const ok = statusOk && backendKnown;

  requestErrors.add(!ok);
  if (!backendKnown) {
    unknownBodyCount.add(1);
  }

  check(resp, { 'status is 200': (r) => r.status === 200 });
  return { backend, ok };
}

export function headerScenario() {
  const resp = http.get(`${BASE_URL}/`, {
    headers: { [MODEL_HEADER]: MODEL_VALUE },
    timeout: REQUEST_TIMEOUT,
    tags: { pattern: 'header' },
  });
  const { backend, ok } = evaluateResponse(resp);

  if (backend === 'v1') {
    headerV1Count.add(1);
  } else if (backend === 'v2') {
    headerV2Count.add(1);
  }
  headerV1Share.add(ok && backend === 'v1');
}

export function publisherScenario() {
  const resp = http.get(`${BASE_URL}${PUBLISHER_PATH}`, {
    timeout: REQUEST_TIMEOUT,
    tags: { pattern: 'publisher' },
  });
  const { backend, ok } = evaluateResponse(resp);

  if (backend === 'v1') {
    publisherV1Count.add(1);
  } else if (backend === 'v2') {
    publisherV2Count.add(1);
  }
  publisherV1Share.add(ok && backend === 'v1');
}

export function directV1Scenario() {
  const resp = http.get(`${BASE_URL}/direct/v1`, {
    timeout: REQUEST_TIMEOUT,
    tags: { pattern: 'direct-v1' },
  });
  const { backend, ok } = evaluateResponse(resp);

  if (backend === 'v1') {
    directV1Count.add(1);
  } else if (backend === 'v2') {
    directV2Count.add(1);
  }
  directV1Pinned.add(ok && backend === 'v1');
}

export function directV2Scenario() {
  const resp = http.get(`${BASE_URL}/direct/v2`, {
    timeout: REQUEST_TIMEOUT,
    tags: { pattern: 'direct-v2' },
  });
  const { backend, ok } = evaluateResponse(resp);

  if (backend === 'v2') {
    directV2Count.add(1);
  } else if (backend === 'v1') {
    directV1Count.add(1);
  }
  directV2Pinned.add(ok && backend === 'v2');
}

function metricCount(data, metricName) {
  const metric = data.metrics[metricName];
  if (!metric || !metric.values) {
    return 0;
  }
  return Math.round(metric.values.count || 0);
}

function metricRate(data, metricName) {
  const metric = data.metrics[metricName];
  if (!metric || !metric.values) {
    return 0;
  }
  return (metric.values.rate || 0) * 100;
}

export function handleSummary(data) {
  const lines = [];
  lines.push('');
  lines.push('Per-Participant Routes k6 Parallel Summary');
  lines.push(`Base URL: ${BASE_URL}`);
  lines.push(
    `Header split: v1=${metricCount(data, 'header_v1_count')} v2=${metricCount(data, 'header_v2_count')} share=${metricRate(data, 'header_v1_share').toFixed(1)}%`,
  );
  lines.push(
    `Publisher split: v1=${metricCount(data, 'publisher_v1_count')} v2=${metricCount(data, 'publisher_v2_count')} share=${metricRate(data, 'publisher_v1_share').toFixed(1)}%`,
  );
  lines.push(
    `Direct pins: /direct/v1=${metricRate(data, 'direct_v1_pinned').toFixed(1)}% /direct/v2=${metricRate(data, 'direct_v2_pinned').toFixed(1)}%`,
  );
  lines.push(`Unknown body responses: ${metricCount(data, 'unknown_body_count')}`);
  lines.push('');

  return { stdout: `${lines.join('\n')}\n` };
}
