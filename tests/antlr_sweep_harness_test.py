"""Offline fixtures exercise stage attribution, pinning and the regression gate."""
import csv
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sweep", ROOT /
    "libs/extras/grammars/antlr_to_pg/sweep_grammars_v4.py")
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)


class SweepTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="antlr sweep ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.corpus = self.root / "corpus"
        self.corpus.mkdir()
        self.source = self.corpus / "Grammar.g4"
        self.source.write_text("grammar Fixture; root: 'a';")
        self.work = self.root / "work"
        self.work.mkdir()
        self.case = {"name": "fixture", "inputs": [{"path": "Grammar.g4",
            "sha256": sweep.sha256(self.source)}], "expected_pass": list(sweep.STAGES)}
        self.tools = {}
        for name in ("translator", "generator", "compiler"):
            tool = self.root / name
            tool.write_text("#!" + sys.executable + "\n" +
                "import os, pathlib, signal, sys, time\n"
                "args = sys.argv[1:]\n"
                "name = pathlib.Path(sys.argv[0]).name\n"
                "mode = pathlib.Path(sys.argv[0]).with_suffix('.mode')\n"
                "mode = mode.read_text() if mode.exists() else ''\n"
                "print(name + ': complete log, including commas and \\\"quotes\\\"', flush=True)\n"
                "if mode == 'timeout': time.sleep(5)\n"
                "if mode == 'crash': os.kill(os.getpid(), signal.SIGTERM)\n"
                "if mode == 'fail' or (mode == 'strict_fail' and '--strict' in args): sys.exit(7)\n"
                "if mode == 'stateful_fail' and '--stateful' in args: sys.exit(8)\n"
                "if mode == 'missing': sys.exit(0)\n"
                "if name == 'compiler':\n"
                "    program = pathlib.Path(args[0]).read_text()\n"
                "    assert program.count('int main():') == 1, program\n"
                "if '--dependencies' in args:\n"
                "    pathlib.Path(args[args.index('--dependencies')+1]).write_text(args[0] + '\\n')\n"
                "for flag in ('-o', '--matchers', '--report', '--audit'):\n"
                "    if flag in args: pathlib.Path(args[args.index(flag)+1]).write_text('# generated\\n')\n")
            tool.chmod(0o755)
            self.tools[name] = tool
        self.tools["common_matchers"] = self.root / "common.w"
        self.tools["common_matchers"].write_text("# common matchers\n")

    def run_case(self, timeout=5):
        return sweep.run_case(self.case, self.corpus, self.work, self.tools, timeout, self.root)

    def mode(self, tool, value):
        self.tools[tool].with_suffix(".mode").write_text(value)

    def test_success_and_paths_with_spaces(self):
        result = self.run_case()
        self.assertEqual({v["status"] for v in result["stages"].values()}, {"pass"})
        self.assertEqual(result["runtime_smoke"], "not_configured")
        self.assertEqual(result["dependency_inputs"], self.case["inputs"])
        self.assertIn('commas and "quotes"', (self.work / "fixture/compile.log").read_text())
        with self.assertRaises(FileExistsError):
            self.run_case()

    def test_generator_failure_preserves_translation_and_strict(self):
        self.mode("generator", "fail")
        result = self.run_case()
        self.assertEqual(result["stages"]["translate"]["status"], "pass")
        self.assertEqual(result["stages"]["generate"]["exit_code"], 7)
        self.assertEqual(result["stages"]["compile"]["status"], "not_run")
        self.assertEqual(result["stages"]["strict"]["status"], "pass")

    def test_translation_failure_still_audits(self):
        self.mode("translator", "fail")
        result = self.run_case()
        self.assertEqual(result["stages"]["generate"]["status"], "not_run")
        self.assertEqual(result["stages"]["strict"]["exit_code"], 7)

    def test_strict_failure_does_not_erase_compile_pass(self):
        self.mode("translator", "strict_fail")
        result = self.run_case()
        self.assertEqual(result["stages"]["compile"]["status"], "pass")
        self.assertEqual(result["stages"]["strict"]["status"], "fail")

    def test_timeout_is_infrastructure_error_even_for_baseline_failure(self):
        self.mode("generator", "timeout")
        result = self.run_case(timeout=0.2)
        self.case["expected_pass"] = []
        summary = sweep.write_results(self.work, {"cases": [self.case]}, [result], {})
        self.assertEqual(summary["regressions"], [])
        self.assertEqual(summary["infrastructure_errors"], [f"fixture: {name}/generate timeout" for name in sweep.CONFIGURATIONS])
        self.assertIn("stage timeout", (self.work / "fixture/generate.log").read_text())

    def test_success_without_output_is_not_a_pass(self):
        self.mode("translator", "missing")
        result = self.run_case()
        self.assertEqual(result["stages"]["translate"]["status"], "error")
        self.assertEqual(result["stages"]["generate"]["status"], "not_run")

    def test_signal_crash_fails_even_for_a_previously_unsupported_case(self):
        self.mode("generator", "crash")
        result = self.run_case()
        self.case["expected_pass"] = []
        summary = sweep.write_results(self.work, {"cases": [self.case]}, [result], {})
        self.assertLess(result["stages"]["generate"]["exit_code"], 0)
        self.assertEqual(summary["regressions"], [])
        self.assertEqual(summary["infrastructure_errors"], [f"fixture: {name}/generate crash" for name in sweep.CONFIGURATIONS])

    def test_per_case_regression_cannot_be_hidden_by_another_case_passing(self):
        self.mode("compiler", "fail")
        failed = self.run_case()
        passed = dict(failed, name="newly_passing", stages={s: {"status": "pass"} for s in sweep.STAGES})
        summary = sweep.write_results(self.work, {"cases": [self.case]}, [failed, passed], {})
        self.assertEqual(summary["passing"]["compile"], 1)
        self.assertEqual(summary["regressions"], ["fixture: compile regressed to fail"])
        with (self.work / "results.csv").open(newline="") as source:
            rows = list(csv.DictReader(source))
        self.assertEqual(rows[0]["compile"], "fail")
        self.assertEqual(sweep.compare({"cases": [self.case]}, []), ["fixture: missing result"])

    def test_manifest_checks_revision_hash_and_duplicate_cases(self):
        subprocess.run(["git", "init", "-q", str(self.corpus)], check=True)
        subprocess.run(["git", "-C", str(self.corpus), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.corpus), "-c", "user.name=Sweep Test",
                        "-c", "user.email=sweep@example.invalid", "commit", "-qm", "fixture"], check=True)
        commit = sweep.git_output(self.corpus, "rev-parse", "HEAD")
        manifest = {"schema": 1, "corpus_commit": commit, "cases": [self.case]}
        path = self.root / "manifest.json"
        path.write_text(json.dumps(manifest))
        self.assertEqual(sweep.load_manifest(path, self.corpus), manifest)
        self.source.write_text("changed")
        with self.assertRaisesRegex(ValueError, "hash/path mismatch"):
            sweep.load_manifest(path, self.corpus)
        subprocess.run(["git", "-C", str(self.corpus), "checkout", "--", "Grammar.g4"], check=True)
        sibling = self.corpus / "Unpinned.g4"
        sibling.write_text("lexer grammar Unpinned;")
        with self.assertRaisesRegex(ValueError, "untracked siblings"):
            sweep.load_manifest(path, self.corpus)
        sibling.unlink()
        manifest["corpus_commit"] = "0" * 40
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "revision mismatch"):
            sweep.load_manifest(path, self.corpus)
        manifest["corpus_commit"] = commit
        self.case["recorded_pass"] = ["compile"]
        self.case["expected_pass"] = []
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "requires a reclassified reason"):
            sweep.load_manifest(path, self.corpus)
        self.case["reclassified"] = {"compile": "Fixture intentionally rejects an unsafe empty token"}
        path.write_text(json.dumps(manifest))
        sweep.load_manifest(path, self.corpus)
        manifest["cases"].append(self.case)
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "duplicate case"):
            sweep.load_manifest(path, self.corpus)

    def test_all_configurations_build_their_own_outputs(self):
        result = self.run_case()
        programs = set()
        for configuration, flags in sweep.CONFIGURATIONS.items():
            stages = result["configurations"][configuration]["stages"]
            self.assertEqual({v["status"] for v in stages.values()}, {"pass"})
            self.assertEqual([arg for arg in stages["translate"]["argv"] if arg in ("--strict", "--stateful")], list(flags))
            program = Path(stages["compile"]["argv"][1])
            programs.add(program)
            self.assertEqual(stages["compiler_strict"]["argv"][1], str(program))
            self.assertIn("--strict", stages["compiler_strict"]["argv"])
            self.assertNotIn("--strict", stages["compile"]["argv"])
            self.assertEqual(result["configurations"][configuration]["dependency_inputs"], self.case["inputs"])
        self.assertEqual(len(programs), 4)
        self.assertEqual(result["stages"]["strict"], result["configurations"]["default_strict"]["stages"]["translate"])

    def test_warning_failure_is_independent_of_ordinary_compilation(self):
        self.mode("compiler", "strict_fail")
        result = self.run_case()
        for current in result["configurations"].values():
            self.assertEqual(current["stages"]["compile"]["status"], "pass")
            self.assertEqual(current["stages"]["compiler_strict"]["status"], "fail")
        self.case["expected_configurations"] = {"stateful_strict": ["compiler_strict"]}
        self.assertEqual(sweep.compare({"cases": [self.case]}, [result]),
                         ["fixture: stateful_strict/compiler_strict regressed to fail"])

    def test_stateful_failure_does_not_erase_default_results(self):
        self.mode("translator", "stateful_fail")
        result = self.run_case()
        self.assertEqual({v["status"] for v in result["stages"].values()}, {"pass"})
        for name in ("stateful_permissive", "stateful_strict"):
            self.assertEqual(result["configurations"][name]["stages"]["translate"]["exit_code"], 8)
            self.assertEqual(result["configurations"][name]["stages"]["compile"]["status"], "not_run")

    def test_schema_two_roundtrip_preserves_historical_columns(self):
        result = self.run_case()
        summary = sweep.write_results(self.work, {"cases": [self.case]}, [result], {})
        data = json.loads((self.work / "results.json").read_text())
        self.assertEqual(data["schema"], 2)
        self.assertEqual(summary["passing"], dict.fromkeys(sweep.STAGES, 1))
        self.assertEqual(summary["configurations"]["default_strict"], dict.fromkeys(sweep.BUILD_STAGES, 1))
        with (self.work / "results.csv").open() as source:
            row = next(csv.DictReader(source))
        self.assertEqual(row["compile"], "pass")
        self.assertEqual(row["strict"], "pass")
        self.assertEqual(row["default_strict/compiler_strict"], "pass")

    def test_extended_backends_are_opt_in_and_have_distinct_artifacts(self):
        configurations = sweep.CONFIGURATIONS | sweep.EXTENDED_CONFIGURATIONS
        result = sweep.run_case(self.case, self.corpus, self.work, self.tools, 5, self.root, configurations)
        self.assertEqual(set(result["configurations"]), set(configurations))
        stages = result["configurations"]["exact_strict"]["stages"]
        for flag in ("--strict", "--exact-lexer", "--prediction"):
            self.assertIn(flag, stages["translate"]["argv"])
        self.assertIn("exact_strict", stages["compile"]["argv"][1])
        summary = sweep.write_results(self.work, {"cases": [self.case]}, [result], {})
        self.assertEqual(summary["configurations"]["exact_strict"]["compiler_strict"], 1)
        self.assertEqual(result["stages"]["strict"], result["configurations"]["default_strict"]["stages"]["translate"])

    def test_committed_baseline_keeps_original_measurement(self):
        data = json.loads((sweep.HERE / "sweep_baseline.json").read_text())
        self.assertEqual(len(data["cases"]), 291)
        self.assertEqual(len({case["name"] for case in data["cases"]}), 291)
        self.assertEqual(sum(case["historical_288"] for case in data["cases"]), 288)
        self.assertEqual(data["baseline_w_commit"], "298246c6d6906650d4cd9c677e93933abd9bf619")
        # Historical evidence stays fixed; expected passes may increase or have
        # individual removals with an explicit correctness reclassification.
        self.assertEqual(sum("compile" in c["recorded_pass"] for c in data["cases"]), 179)
        self.assertEqual(sum("strict" in c["recorded_pass"] for c in data["cases"]), 10)


if __name__ == "__main__":
    unittest.main()
