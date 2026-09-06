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


if __name__ == "__main__":
    unittest.main()
