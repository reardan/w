"""Offline checks for the oracle protocol, baseline ledger and artifact policy."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("differential", ROOT / "tests/antlr_differential.py")
differential = importlib.util.module_from_spec(spec)
spec.loader.exec_module(differential)


class DifferentialTest(unittest.TestCase):
    def test_wire_format_uses_symbolic_tokens_and_utf8_spans(self):
        output = "TOKEN\tIDENT\t0\t0\t4\tf09f9982\nTOKEN\tEOF\t0\t4\t0\t\nACCEPT\t1\nRULE\tfirst\t0\t4\n"
        observed = differential.observation(output, observe_rules=["first"])
        self.assertTrue(observed["accepted"])
        self.assertEqual(observed["tokens"][0], dict(name="IDENT", channel=0, start=0, length=4, text="🙂"))
        self.assertEqual(observed["rules"], [dict(name="first", start=0, length=4)])

    def test_skipped_trivia_is_excluded_but_hidden_channel_is_compared(self):
        output = "TOKEN\tWS\t1\t0\t1\t20\nTOKEN\tCOMMENT\t1\t1\t1\t23\nTOKEN\tEOF\t0\t2\t0\t\nACCEPT\t1\n"
        observed = differential.observation(output, ["WS"])
        self.assertEqual([token["name"] for token in observed["tokens"]], ["COMMENT", "EOF"])
        self.assertEqual(observed["tokens"][0]["channel"], 1)

    def test_user_channel_numbers_normalize_without_aliasing_native_error_channel(self):
        oracle = "TOKEN\tCOMMENT\t2\t0\t1\t23\nTOKEN\tEOF\t0\t1\t0\t\nACCEPT\t1\n"
        native = oracle.replace("COMMENT\t2", "COMMENT\t3")
        self.assertEqual(differential.observation(oracle, channel_map={"2": "COMMENTS"}),
                         differential.observation(native, channel_map={"3": "COMMENTS"}))
        self.assertNotEqual(differential.observation(oracle), differential.observation(native))

    def test_explicit_literal_identity_mapping_preserves_other_tokens(self):
        output = "TOKEN\tKW_IF\t0\t0\t2\t6966\nTOKEN\tEOF\t0\t2\t0\t\nACCEPT\t1\n"
        observed = differential.observation(output, token_names={"KW_IF": "'if'"})
        self.assertEqual(observed["tokens"][0]["name"], "'if'")
        self.assertEqual(observed["tokens"][1]["name"], "EOF")

    def test_reclassifications_have_pinned_upstream_and_live_oracle_witnesses(self):
        manifest = differential.load_manifest()
        cases = {case["name"]: case for case in manifest["cases"]}
        snapshots = json.loads((differential.FIXTURES / "snapshots.json").read_text())
        records = json.loads((differential.FIXTURES / "STRICT_RECLASSIFICATIONS.json").read_text())
        for record in records["cases"]:
            case = cases[record["fixture_case"]]
            self.assertEqual(record["entry_rule"], case["start"])
            self.assertEqual(record["inputs"], case["upstream"]["inputs"])
            for witness in record["witnesses"]:
                item = next(item for item in case["inputs"] if item["text"] == witness["input"])
                self.assertIn("accepted", item["known_mismatches"])
                self.assertTrue(snapshots[case["name"] + "/" + item["id"]]["accepted"])
                self.assertTrue(witness["antlr_accepts"])
                self.assertFalse(witness["legacy_w_accepts"])

    def test_partial_or_malformed_output_is_infrastructure_failure(self):
        for output in ("", "ACCEPT\t1\n", "TOKEN\tEOF\t0\t0\t0\t\n", "arbitrary stdout\n",
                       "TOKEN\tEOF\t0\t0\t0\t\nACCEPT\t1\nACCEPT\t0\n",
                       "TOKEN\tTEXT\t0\t0\t1\tf09f9982\nACCEPT\t1\n"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                differential.observation(output)

    def test_expected_failure_is_exact_and_unexpected_fix_requires_promotion(self):
        expected = dict(accepted=True, tokens=[], rules=[])
        actual = dict(expected, accepted=False)
        self.assertEqual(differential.check_mismatches(actual, expected, {"accepted": "known witness"}), ["accepted"])
        with self.assertRaises(ValueError):
            differential.check_mismatches(expected, expected, {"accepted": "stale waiver"})
        with self.assertRaises(ValueError):
            differential.check_mismatches(dict(actual, tokens=[{}]), expected, {"accepted": "known witness"})
        with self.assertRaises(ValueError):
            differential.check_mismatches(actual, expected, {})

    def test_fuzz_recipe_is_reproducible_and_seed_specific(self):
        self.assertEqual(differential.token_fuzz(689690692, 24), differential.token_fuzz(689690692, 24))
        self.assertNotEqual(differential.token_fuzz(689690692, 24), differential.token_fuzz(1, 24))
        self.assertEqual(len(differential.token_fuzz(689690692, 24)), 24)

    def test_pinned_manifest_and_snapshot_denominators(self):
        manifest = differential.load_manifest()
        snapshots = json.loads((differential.FIXTURES / "snapshots.json").read_text())
        keys = {case["name"] + "/" + item["id"] for case in manifest["cases"] for item in case["inputs"]}
        self.assertEqual(set(snapshots), keys)
        self.assertEqual(manifest["oracle"]["version"], "4.13.2")
        self.assertGreaterEqual(len(manifest["cases"]), 10)
        for key, snapshot in snapshots.items():
            self.assertIsInstance(snapshot["accepted"], bool)
            self.assertEqual(snapshot["tokens"][-1]["name"], "EOF", key)

    def test_untrusted_jar_fails_before_java_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            jar = Path(directory) / "fake.jar"
            jar.write_bytes(b"not ANTLR")
            result = subprocess.run([sys.executable, ROOT / "tests/antlr_differential.py", "--jar", jar],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("checksum mismatch", result.stderr)

    def test_oracle_only_cannot_silently_skip_missing_java(self):
        result = subprocess.run([sys.executable, ROOT / "tests/antlr_differential.py", "--oracle-only"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --jar", result.stderr)


if __name__ == "__main__":
    unittest.main()
