"""Regression cases for the false successes found in the original validator."""
import argparse
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import score


class ScoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        self.args = argparse.Namespace(directory=self.d, phase="fix", model_id="publisher/model", model_name="model",
                                       route_prefix="ns.pool-route.", status=200, chain="OK", picks=True,
                                       responses="complete", after_ipp=True, accounting=False)
        self.body = {"model": "model", "choices": [{"message": {"content": "hello"}, "finish_reason": "stop"}],
                     "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}}
        self.rows = [{"id": k, "kind": k, "status": 200, "complete": True, "body_file": k + ".body"}
                     for k in ("single", "stream", "burst")]
        self.logs = [{"req_id": k, "response_code": 200, "model_hdr": "publisher/model", "ep_requested": "pod:8000",
                      "upstream_host": "pod:8000", "upstream_cluster": "example-inference-pool-cluster", "route_name": "ns.pool-route.4"}
                     for k in ("single", "stream", "burst")]
        for kind in ("single", "burst"):
            (self.d / (kind + ".body")).write_text(json.dumps(self.body))
        (self.d / "stream.body").write_text("data: " + json.dumps(self.body) + "\n\ndata: [DONE]\n\n")
        self.write("requests.json", self.rows)
        self.write("expected.json", {"single": 1, "stream": 1, "fragment": 0, "burst": 1})
        self.write("diag.json", {"verdicts": {"EPP_ENGAGED": "OK", "NO_DUPLICATES": "OK"},
                                 "indices": {"ipp_pre": 0, "auth": 1, "ipp": 2, "istio_ext_proc": 3, "router": 4}})
        self.write_logs()
        (self.d / "epp-before.prom").write_text('llm_d_epp_ready_endpoints 3\n')
        (self.d / "epp-after.prom").write_text('llm_d_epp_ready_endpoints 3\ninference_extension_plugin_duration_seconds_count{extension_point="Picker"} 3\n')
        (self.d / "epp.log").write_text('"EPP received request"\n' * 3)
        for side in ("before", "after"):
            self.write(f"pods-{side}.json", {"items": [{"metadata": {"uid": "pod"}, "status": {"containerStatuses": [{"restartCount": 0}]}}]})
            value = 0 if side == "before" else 21
            calls = 0 if side == "before" else 3
            (self.d / f"limitador-{side}.prom").write_text(f'authorized_hits{{limitador_namespace="ns/pool-route"}} {value}\nauthorized_calls{{limitador_namespace="ns/pool-route"}} {calls}\n')

    def write(self, file, value):
        (self.d / file).write_text(json.dumps(value))

    def write_logs(self):
        (self.d / "gateway.log").write_text("".join(json.dumps(row) + "\n" for row in self.logs))

    def run_score(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return score.score(self.args)

    def test_complete_mix_and_accounting_pass(self):
        self.args.accounting = True
        self.assertFalse(self.run_score())

    def test_empty_http_200_fails_unless_explicitly_reproducing_defect(self):
        (self.d / "single.body").write_text("")
        self.assertTrue(self.run_score())
        self.args.responses = "empty"
        self.assertFalse(self.run_score())

    def test_burst_status_body_and_endpoint_are_all_checked(self):
        (self.d / "burst.body").write_text('{"error":"failed"}')
        self.assertTrue(self.run_score())
        (self.d / "burst.body").write_text(json.dumps(self.body))
        self.rows[2]["status"] = 500
        self.write("requests.json", self.rows)
        self.assertTrue(self.run_score())
        self.rows[2]["status"] = 200
        self.write("requests.json", self.rows)
        self.logs[2]["upstream_host"] = "wrong:8000"
        self.write_logs()
        self.assertTrue(self.run_score())

    def test_sse_requires_json_model_finish_reason_and_final_done(self):
        valid = (self.d / "stream.body").read_text()
        variants = ["data: [DONE]\n", valid.replace('"model": "model"', '"model": "wrong"'),
                    valid.replace('"finish_reason": "stop"', '"finish_reason": null'),
                    valid.replace("data: [DONE]", "data: garbage"), valid + 'data: {}\n']
        for raw in variants:
            with self.subTest(raw=raw):
                (self.d / "stream.body").write_text(raw)
                self.assertTrue(self.run_score())

    def test_dropped_sse_record_cannot_hide_from_expected_counts(self):
        self.write("requests.json", [self.rows[0], self.rows[2]])
        self.assertTrue(self.run_score())

    def test_picker_count_includes_stream_and_burst(self):
        (self.d / "epp-after.prom").write_text('llm_d_epp_ready_endpoints 3\ninference_extension_plugin_duration_seconds_count{extension_point="Picker"} 1\n')
        self.assertTrue(self.run_score())

    def test_same_log_count_with_duplicate_id_does_not_pass(self):
        self.logs[2]["req_id"] = "single"
        self.write_logs()
        self.assertTrue(self.run_score())

    def test_missing_stream_token_charge_fails_accounting(self):
        self.args.accounting = True
        (self.d / "limitador-after.prom").write_text('authorized_hits{limitador_namespace="ns/pool-route"} 14\nauthorized_calls{limitador_namespace="ns/pool-route"} 3\n')
        self.assertTrue(self.run_score())


if __name__ == "__main__":
    unittest.main()
