#!/usr/bin/env python3
"""Adversarial native runner results must preserve truthful outcome accounting."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
from fragment_upstream import execute, ROOT


class ReportTests(unittest.TestCase):
    def test_outcomes(self):
        with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, b"ok\n", b"")):
            self.assertEqual(execute([], "ok\n"), ("PASS", "", True))
            self.assertEqual(execute([], "wrong\n")[0], "FAIL")
        with patch("subprocess.run", return_value=subprocess.CompletedProcess([], -11, b"", b"")):
            self.assertEqual(execute([], "")[0], "ERROR")
        with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, b"\xff", b"")):
            self.assertEqual(execute([], "")[0], "ERROR")
        with patch("subprocess.run", side_effect=subprocess.TimeoutExpired([], 1)):
            self.assertEqual(execute([], "")[0], "TIMEOUT")
        with patch("subprocess.run", side_effect=FileNotFoundError("missing")):
            result = execute([], "")
            self.assertEqual(result[0], "ERROR")
            self.assertFalse(result[2])

    def test_changed_driver_invalidates_all_results(self):
        with tempfile.TemporaryDirectory() as directory:
            driver = Path(directory) / "driver"
            driver.write_text("#!" + sys.executable + "\nfrom pathlib import Path\np=Path(__file__)\np.write_bytes(p.read_bytes()+b'\\n# changed')\n")
            driver.chmod(0o755)
            report = Path(directory) / "report.json"
            run = subprocess.run([sys.executable, str(ROOT / "fragment_upstream.py"),
                                  str(driver), "--report", str(report)], capture_output=True, timeout=20)
            self.assertEqual(run.returncode, 1)
            result = json.loads(report.read_text())
            self.assertEqual(result["counts"]["ERROR"], 61)
            self.assertEqual(result["variant_counts"]["ERROR"], 122)
            self.assertEqual(result["evidence"]["changed_during_execution"], ["driver binary"])
            self.assertTrue(all(r["observed_status"] == "FAIL" for r in result["results"]))

    def test_missing_binary_keeps_all_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            run = subprocess.run([sys.executable, str(ROOT / "fragment_upstream.py"),
                                  str(Path(directory) / "missing"), "--report", str(report)],
                                 capture_output=True, timeout=10)
            self.assertEqual(run.returncode, 1)
            result = json.loads(report.read_text())
            self.assertEqual(result["total"], 1796)
            self.assertEqual(result["selected"], 61)
            self.assertEqual(result["counts"]["NOT_RUN"], 1735)
            self.assertEqual(result["executed"], 0)
            self.assertEqual(result["counts"]["ERROR"], 61)
            self.assertEqual(len(result["results"]), 61)
            self.assertEqual(result["variant_counts"]["ERROR"], 122)
            self.assertEqual(result["selected_variants"], 122)
            self.assertIsNone(result["evidence"]["driver_sha256"])
            self.assertTrue(result["evidence"]["driver_hash_error"])


if __name__ == "__main__":
    unittest.main()
