import importlib.util
import json
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


WRAPPER_PATH = Path(__file__).resolve().parents[2] / "deploy" / "assets" / "stats.py"
SPEC = importlib.util.spec_from_file_location("node_stats_wrapper", WRAPPER_PATH)
wrapper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wrapper)


class NodeWrapperTest(unittest.TestCase):
    def test_run_requires_successful_json_object(self):
        completed = subprocess.CompletedProcess([], 0, json.dumps({"stat": []}), "")
        with patch.object(wrapper.subprocess, "run", return_value=completed) as run:
            self.assertEqual(wrapper.run(["xray", "api"]), {"stat": []})
        run.assert_called_once_with(
            ["xray", "api"],
            capture_output=True,
            text=True,
            timeout=wrapper.COMMAND_TIMEOUT,
            check=True,
        )

    def test_run_rejects_non_object_json(self):
        completed = subprocess.CompletedProcess([], 0, "[]", "")
        with patch.object(wrapper.subprocess, "run", return_value=completed):
            with self.assertRaises(ValueError):
                wrapper.run(["xray", "api"])

    def test_protocols_registry_exposes_xray_and_hysteria(self):
        self.assertEqual(set(wrapper.PROTOCOLS), {"xray", "hysteria"})
        for protocol, endpoints in wrapper.PROTOCOLS.items():
            self.assertEqual(set(endpoints), {"stats", "online"})

    def test_fetch_hysteria_requires_secret_and_port(self):
        with patch.object(wrapper, "HYSTERIA_STATS_SECRET", ""), \
             patch.object(wrapper, "HYSTERIA_STATS_PORT", "9999"):
            with self.assertRaises(RuntimeError):
                wrapper.fetch_hysteria("/traffic")

    def test_fetch_hysteria_sends_authorization_header(self):
        response = json.dumps({"alice": {"tx": 1, "rx": 2}}).encode()

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return response

        captured = {}

        def fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            captured["headers"] = dict(req.header_items())
            return FakeResponse()

        with patch.object(wrapper, "HYSTERIA_STATS_SECRET", "s3cret"), \
             patch.object(wrapper, "HYSTERIA_STATS_PORT", "9999"), \
             patch.object(wrapper.urllib.request, "urlopen", fake_urlopen):
            result = wrapper.fetch_hysteria("/traffic")

        self.assertEqual(result, {"alice": {"tx": 1, "rx": 2}})
        self.assertEqual(captured["url"], "http://hysteria:9999/traffic")
        self.assertEqual(captured["headers"].get("Authorization"), "s3cret")


if __name__ == "__main__":
    unittest.main()
