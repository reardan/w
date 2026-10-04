#!/usr/bin/env python3
"""Regression checks for the AST suite's coverage and dependency graph."""

import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("ast_suite", ROOT / "tools" / "ast_suite.py")
ast_suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ast_suite)


class AstSuiteTests(unittest.TestCase):
    def test_required_queries_and_compiles_preserve_seed_and_explicit_modes(self):
        steps = [
            {"cmd": ["bin/wv2", "good.w", "-o", "bin/good"]},
            {"cmd": ["bin/wv2_64", "check", "--lint", "x64", "good.w"]},
            {"cmd": ["env", "-u", "NO_COLOR", "FORCE_COLOR=1", "bin/wv2", "bad.w"], "expect_fail": True},
            {"cmd": ["bin/wv3", "bad.w"], "expect_status": 1},
            {"cmd": ["./w", "w.w", "-o", "bin/wv2"]},
            {"cmd": ["bin/wv2", "--ast-expressions", "good.w"]},
            {"cmd": ["bin/wv2", "--help"]},
        ]
        original = {"targets": [{"name": "tests", "steps": steps}]}
        saved = copy.deepcopy(original)
        result, counts = ast_suite.require_ast_expressions(original)
        commands = [step["cmd"] for step in result["targets"][0]["steps"]]
        self.assertEqual(original, saved)
        self.assertEqual(commands[0][-1], "--ast-required")
        self.assertEqual(commands[1][-1], "--ast-required")
        self.assertEqual(commands[2][-1], "--ast-full-expressions")
        self.assertEqual(commands[3][-1], "--ast-full-expressions")
        for index in (4, 5, 6):
            self.assertEqual(commands[index], steps[index]["cmd"])
        self.assertEqual(counts, {"required": 2, "expected_failures": 2, "explicit_modes": 1, "fixture_groups": 0})
        self.assertEqual(ast_suite.require_ast_expressions(result)[0], result)

    def test_fixture_children_are_gated(self):
        original = {"targets": [{"name": "tests", "steps": [
            {"cmd": ["bin/wfixture", "bin/wv2", "ok.w", "error.w"]},
            {"cmd": ["env", "--unset=NO_COLOR", "--", "bin/wfixture", "bin/wv2_64", "x64.w"]},
            {"cmd": ["bin/wfixture", "./w", "seed.w"]},
        ]}]}
        result, counts = ast_suite.require_ast_expressions(original)
        commands = [step["cmd"] for step in result["targets"][0]["steps"]]
        self.assertEqual(commands[0], ["bin/wfixture", "--ast-expressions", "bin/wv2", "ok.w", "error.w"])
        self.assertEqual(commands[1][4:6], ["--ast-expressions", "bin/wv2_64"])
        self.assertEqual(commands[2], original["targets"][0]["steps"][2]["cmd"])
        self.assertEqual(counts["fixture_groups"], 2)
        self.assertEqual(ast_suite.require_ast_expressions(result)[0], result)

    def test_build_tool_tests_run_last_without_cycles(self):
        manifest = {"targets": [
            {"name": "build"},
            {"name": "ordinary", "deps": ["build"]},
            {"name": "wbuildd_test", "deps": ["build"]},
            {"name": "wexec_test", "deps": ["build"]},
            {"name": "after_daemon", "deps": ["wbuildd_test"]},
            {"name": "after_executor", "deps": ["wexec_test"]},
            {"name": "unselected"},
            {"name": "tests", "deps": ["ordinary", "after_daemon", "after_executor"]},
        ]}
        ast_suite.serialize_build_tool_tests(manifest)
        targets = {target["name"]: target for target in manifest["targets"]}
        self.assertIn("ordinary", targets["wbuildd_test"]["deps"])
        self.assertIn("after_daemon", targets["wexec_test"]["deps"])
        self.assertNotIn("unselected", targets["wexec_test"]["deps"])

        def walk(name, ancestors):
            self.assertNotIn(name, ancestors)
            for dependency in targets[name].get("deps", []):
                walk(dependency, ancestors | {name})

        walk("tests", set())


if __name__ == "__main__":
    unittest.main()
