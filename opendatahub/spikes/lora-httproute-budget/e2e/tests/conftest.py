"""Shared fixtures and helpers for the LoRA routing validator.

Isolation contract: every Kubernetes call goes through the validator-owned
kubeconfig handed over by validate.sh (LORA_E2E_KUBECONFIG). The suite never
reads the caller's kubeconfig. The global-strategy fixture snapshots the
inferenceservice-config ConfigMap, establishes each test's declared starting
strategy, and restores the exact original bytes afterwards - a restoration
failure is a harness error, not an assertion failure.

The suite runs strictly serially (validate.sh runs the mutation-marked phase
first, then the readonly phase; neither uses xdist). Read-only refers to the
cluster-global routing strategy, not to namespaced resources.
"""

import json
import os
import re
import subprocess
import time
import uuid
from pathlib import Path

import pytest
import requests as http
from kubernetes import client as k8s
from kubernetes import config as k8s_config

RUN_DIR = Path(os.environ["LORA_E2E_RUN_DIR"])
KUBECONFIG = os.environ["LORA_E2E_KUBECONFIG"]
GATEWAY_URL = os.environ["LORA_E2E_GATEWAY_URL"].rstrip("/")
FIXTURE_NS = os.environ.get("LORA_E2E_FIXTURE_NS", "lora-fixture")
FIXTURE_PVC = os.environ.get("LORA_E2E_FIXTURE_PVC", "lora-adapters")
ADAPTER_COUNT = int(os.environ.get("LORA_E2E_ADAPTER_COUNT", "100"))

KSERVE_NS = "kserve"
ISVC_CONFIGMAP = "inferenceservice-config"
MODEL_HEADER = "X-Gateway-Model-Name"
GROUP = "serving.kserve.io"
VERSION = "v1alpha2"
LLMISVC_PLURAL = "llminferenceservices"
GW_GROUP = "gateway.networking.k8s.io"

BASE_MODEL_URI = "hf://hmellor/tiny-random-LlamaForCausalLM"
VLLM_CPU_IMAGE = "vllm/vllm-openai-cpu:v0.19.0"

# Route-visible names for the realistic-v1 fixture (must match hack/gen-names.py
# and the fixture seeded into the PVC by setup.sh).
ADAPTER_NAMES = subprocess.run(
    ["python3", str(Path(__file__).parent.parent / "hack" / "gen-names.py"), str(ADAPTER_COUNT)],
    check=True, capture_output=True, text=True,
).stdout.split()


# ---------------------------------------------------------------------------
# Contract helpers (independent of the production renderer)
# ---------------------------------------------------------------------------

def fq(namespace: str, model: str) -> str:
    return f"publishers/{namespace}/models/{model}"


def quote_meta(s: str) -> str:
    """Go regexp.QuoteMeta equivalent for the characters it escapes."""
    return re.sub(r"([\\.+*?()|\[\]{}^$])", r"\\\1", s)


def expected_regex(namespace: str, base: str, adapters) -> str:
    alts = [quote_meta(base)] + [quote_meta(a) for a in sorted(set(adapters)) if a != base]
    return "^publishers/" + quote_meta(namespace) + "/models/(" + "|".join(alts) + ")$"


def wait_until(fn, timeout=180, interval=2, desc="condition"):
    """Poll fn until it returns a truthy value; raise on timeout with the last error."""
    deadline = time.time() + timeout
    last_exc = None
    while time.time() < deadline:
        try:
            got = fn()
            if got:
                return got
        except Exception as exc:  # noqa: BLE001 - retried until deadline
            last_exc = exc
        time.sleep(interval)
    raise AssertionError(f"timed out after {timeout}s waiting for {desc}"
                         + (f": last error: {last_exc}" if last_exc else ""))


# ---------------------------------------------------------------------------
# Kubernetes clients
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def api():
    k8s_config.load_kube_config(config_file=KUBECONFIG)
    return {
        "core": k8s.CoreV1Api(),
        "apps": k8s.AppsV1Api(),
        "custom": k8s.CustomObjectsApi(),
    }


def get_route(api, namespace: str, svc_name: str):
    """The controller-managed HTTPRoute for a service (names kept short enough
    that kmeta.ChildName is plain concatenation)."""
    return api["custom"].get_namespaced_custom_object(
        GW_GROUP, "v1", namespace, "httproutes", f"{svc_name}-kserve-route")


def model_header_matches(route):
    out = []
    for rule in route["spec"].get("rules", []):
        for match in rule.get("matches", []):
            for h in match.get("headers", []) or []:
                if h.get("name", "").lower() == MODEL_HEADER.lower():
                    out.append(h)
    return out


def wait_for_stable_route(api, namespace, svc_name, settle=6, timeout=180):
    """Return the route once its resourceVersion has held still for `settle`
    seconds - controller-side follow-up writes (e.g. the InferencePool v1
    migration) settle shortly after creation."""
    def stable():
        first = get_route(api, namespace, svc_name)
        time.sleep(settle)
        second = get_route(api, namespace, svc_name)
        if first["metadata"]["resourceVersion"] == second["metadata"]["resourceVersion"]:
            return second
        return None
    return wait_until(stable, timeout=timeout, interval=1, desc=f"stable route {namespace}/{svc_name}")


def rule_names(route):
    return [r.get("name", "") for r in route["spec"].get("rules", [])]


def get_llmisvc(api, namespace, name):
    return api["custom"].get_namespaced_custom_object(GROUP, VERSION, namespace, LLMISVC_PLURAL, name)


def condition(obj, cond_type):
    for c in obj.get("status", {}).get("conditions", []):
        if c.get("type") == cond_type:
            return c
    return None


# ---------------------------------------------------------------------------
# Global strategy fixture
# ---------------------------------------------------------------------------

def _read_ingress(api):
    cm = api["core"].read_namespaced_config_map(ISVC_CONFIGMAP, KSERVE_NS)
    return cm, json.loads(cm.data.get("ingress", "{}"))


def _write_ingress(api, ingress: dict):
    body = {"data": {"ingress": json.dumps(ingress)}}
    api["core"].patch_namespaced_config_map(ISVC_CONFIGMAP, KSERVE_NS, body)


def set_strategy(api, value):
    """Set (or with None remove) loraModelRoutingStrategy in the ingress config."""
    _, ingress = _read_ingress(api)
    if value is None:
        ingress.pop("loraModelRoutingStrategy", None)
    else:
        ingress["loraModelRoutingStrategy"] = value
    _write_ingress(api, ingress)


class StrategyManager:
    """Establishes a test's declared starting strategy and restores the exact
    original ConfigMap data on teardown. Restoration is verified; failure to
    restore is raised as a harness error so later tests do not run against
    uncertain global state."""

    def __init__(self, api, record):
        self.api = api
        self.record = record
        cm, self.original_ingress = _read_ingress(api)
        self.original_rv = cm.metadata.resource_version

    def require(self, value):
        set_strategy(self.api, value)
        self.record("strategy-set", {"value": value})
        # Give the fan-out a beat; individual assertions still poll.
        time.sleep(1)

    def restore(self):
        _write_ingress(self.api, self.original_ingress)
        _, now = _read_ingress(self.api)
        if now != self.original_ingress:
            raise RuntimeError(
                "HARNESS: failed to restore inferenceservice-config ingress data; "
                f"expected {self.original_ingress!r}, got {now!r}")
        self.record("strategy-restored", {})


@pytest.fixture()
def strategy(api, record):
    mgr = StrategyManager(api, record)
    yield mgr
    mgr.restore()


# ---------------------------------------------------------------------------
# Evidence recording
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def _requests_log():
    path = RUN_DIR / "requests.jsonl"
    fh = path.open("a", encoding="utf-8")
    yield fh
    fh.close()


@pytest.fixture()
def record(request, _requests_log):
    """Append a structured evidence line tagged with the current test."""
    def _record(kind, payload):
        line = {"test": request.node.nodeid, "at": time.time(), "kind": kind, **payload}
        _requests_log.write(json.dumps(line) + "\n")
        _requests_log.flush()
    return _record


def save_resource(name: str, obj):
    (RUN_DIR / "resources").mkdir(exist_ok=True)
    with (RUN_DIR / "resources" / name).open("w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2, default=str)


# ---------------------------------------------------------------------------
# Namespaces and services
# ---------------------------------------------------------------------------

@pytest.fixture()
def test_ns(api, request):
    """A per-test namespace, retained on failure for diagnosis."""
    name = f"lora-e2e-{uuid.uuid4().hex[:8]}"
    api["core"].create_namespace(k8s.V1Namespace(metadata=k8s.V1ObjectMeta(name=name)))
    yield name
    if request.node.rep_call_failed:
        print(f"retaining namespace {name} for diagnosis")
        return
    api["core"].delete_namespace(name, propagation_policy="Background")


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    rep = outcome.get_result()
    if rep.when == "call":
        item.rep_call_failed = rep.failed
    elif not hasattr(item, "rep_call_failed"):
        item.rep_call_failed = False


def llmisvc_manifest(name, namespace, base_model, adapters=(), runtime=False,
                     max_adapters=None, route=None, gateway=None, extra_spec=None):
    """Build an LLMInferenceService dict.

    runtime=True adds the CPU vLLM template (tiny base model, PVC-backed
    adapters); otherwise the preset workload template applies and pods may
    never become Ready, which is fine for route-shape assertions.
    route defaults to a managed route ({}); pass {"http": {"refs": [...]}} or
    an inline {"http": {"spec": {...}}} to exercise other ownership shapes.
    """
    spec = {
        "model": {"uri": BASE_MODEL_URI, "name": base_model},
        "replicas": 1,
        "router": {
            "scheduler": {},
            "gateway": gateway if gateway is not None else {},
            "route": route if route is not None else {},
        },
    }
    if adapters:
        spec["model"]["lora"] = {
            "adapters": [
                {"name": a, "uri": f"pvc://{FIXTURE_PVC}/adapters/{a}"} for a in adapters
            ],
        }
        if max_adapters:
            spec["model"]["lora"]["maxAdapters"] = max_adapters
    if runtime:
        spec["template"] = {
            "containers": [{
                "name": "main",
                "image": VLLM_CPU_IMAGE,
                # The preset assumes the CUDA image (non-root); the CPU image
                # runs as root.
                "securityContext": {"runAsNonRoot": False, "runAsUser": 0},
                "env": [
                    {"name": "VLLM_CPU_KVCACHE_SPACE", "value": "1"},
                    {"name": "VLLM_LOGGING_LEVEL", "value": "INFO"},
                ],
                "resources": {
                    "requests": {"cpu": "2", "memory": "4Gi"},
                    "limits": {"cpu": "8", "memory": "12Gi"},
                },
                "readinessProbe": {
                    "httpGet": {"path": "/health", "port": 8000},
                    "initialDelaySeconds": 20, "periodSeconds": 5,
                    "timeoutSeconds": 5, "failureThreshold": 120,
                },
                "startupProbe": {
                    "httpGet": {"path": "/health", "port": 8000},
                    "periodSeconds": 10, "failureThreshold": 120,
                },
            }],
        }
    if extra_spec:
        spec.update(extra_spec)
    return {
        "apiVersion": f"{GROUP}/{VERSION}",
        "kind": "LLMInferenceService",
        "metadata": {"name": name, "namespace": namespace},
        "spec": spec,
    }


def create_llmisvc(api, manifest):
    ns = manifest["metadata"]["namespace"]
    api["custom"].create_namespaced_custom_object(GROUP, VERSION, ns, LLMISVC_PLURAL, manifest)
    return manifest


def patch_llmisvc(api, namespace, name, patch):
    return api["custom"].patch_namespaced_custom_object(
        GROUP, VERSION, namespace, LLMISVC_PLURAL, name, patch)


def epp_destination_rule(api, namespace, svc_name):
    """Istio originates mTLS to mesh workloads while the EPP serves plaintext
    gRPC; without this DestinationRule every pool-bound request 500s."""
    body = {
        "apiVersion": "networking.istio.io/v1",
        "kind": "DestinationRule",
        "metadata": {"name": f"{svc_name}-epp-tls", "namespace": namespace},
        "spec": {
            "host": f"{svc_name}-epp-service",
            "trafficPolicy": {"tls": {"mode": "SIMPLE", "insecureSkipVerify": True}},
        },
    }
    api["custom"].create_namespaced_custom_object(
        "networking.istio.io", "v1", namespace, "destinationrules", body)


# ---------------------------------------------------------------------------
# Traffic probes
# ---------------------------------------------------------------------------

def probe_completion(record, header_model, body_model, kind, timeout=30):
    """POST /v1/completions through the shared endpoint, addressed by the
    model-routing header. Returns (status_code, parsed-or-None, headers)."""
    resp = http.post(
        f"{GATEWAY_URL}/v1/completions",
        headers={MODEL_HEADER: header_model, "Content-Type": "application/json"},
        json={"model": body_model, "prompt": "hi", "max_tokens": 1},
        timeout=timeout,
    )
    parsed = None
    try:
        parsed = resp.json()
    except ValueError:
        pass
    record("request", {
        "probe": kind,
        "header_model": header_model,
        "body_model": body_model,
        "status": resp.status_code,
        "response_model": (parsed or {}).get("model"),
        "response_headers": {k: v for k, v in resp.headers.items()
                             if k.lower().startswith(("x-", "server"))},
    })
    return resp.status_code, parsed, resp.headers


def service_url(namespace, svc_name):
    return f"{GATEWAY_URL}/{namespace}/{svc_name}"
