#!/usr/bin/env python3
"""Run the production suite with required AST expression compilation.

The pinned seed and explicit AST differential modes retain their original
commands. Expected compile failures use permissive AST mode so diagnostics
can still fall back to the streaming parser. The diagnostic fixture runner
also enforces required AST mode for positive fixtures. Other nested test-driver
subprocesses retain their own modes.
"""

import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent
COMPILER = re.compile(
    r"(?:\./)?bin/(?:wv[2-5](?:_64|_darwin)?|ast_(?:full_)?wv[2-5](?:_64)?)"
)


def command_program_index(command):
    """Locate a program invoked directly or through a standard env prefix."""
    if command[0] not in ("env", "/usr/bin/env", "/bin/env"):
        return 0
    index = 1
    while index < len(command):
        arg = command[index]
        if arg == "--":
            return index + 1
        if arg in ("-u", "--unset"):
            index += 2
        elif arg in ("-i", "--ignore-environment") or arg.startswith("--unset="):
            index += 1
        elif re.match(r"[A-Za-z_][A-Za-z_0-9]*=", arg):
            index += 1
        else:
            return index
    return index


def require_ast_expressions(manifest):
    """Copy the generated manifest and gate ordinary compiler invocations."""
    result = copy.deepcopy(manifest)
    counts = {"required": 0, "expected_failures": 0, "explicit_modes": 0, "fixture_groups": 0}
    for target in result["targets"]:
        for step in target.get("steps", []):
            command = step.get("cmd", [])
            if not isinstance(command, list) or not command:
                continue
            index = command_program_index(command)
            if index >= len(command):
                continue
            program = command[index]
            if program in ("bin/wfixture", "./bin/wfixture"):
                if index + 1 < len(command) and COMPILER.fullmatch(command[index + 1]):
                    command.insert(index + 1, "--ast-expressions")
                    counts["fixture_groups"] += 1
                continue
            if not COMPILER.fullmatch(program):
                continue
            if not any(arg.endswith(".w") for arg in command[index + 1:]):
                continue
            if any(arg.startswith("--ast-") for arg in command[index + 1:]):
                counts["explicit_modes"] += 1
                continue
            expected_failure = step.get("expect_fail", False) or step.get("expect_status", 0) != 0
            if expected_failure:
                command.append("--ast-full-expressions")
                counts["expected_failures"] += 1
            else:
                command.append("--ast-required")
                counts["required"] += 1
    return result, counts


def serialize_build_tool_tests(manifest):
    """Keep tests which modify shared build outputs after compiler consumers."""
    targets = {target["name"]: target for target in manifest["targets"]}
    closures = {}

    def closure(name):
        if name not in closures:
            reachable = {name}
            for dep in targets[name].get("deps", []):
                reachable.update(closure(dep))
            closures[name] = reachable
        return closures[name]

    selected = closure("tests")
    # Compute these against the original graph before adding ordering edges.
    daemon_prerequisites = {
        name for name in selected
        if "wbuildd_test" not in closure(name) and "wexec_test" not in closure(name)
    }
    executor_prerequisites = {
        name for name in selected if "wexec_test" not in closure(name)
    }
    for name, prerequisites in (
        ("wbuildd_test", daemon_prerequisites),
        ("wexec_test", executor_prerequisites),
    ):
        if name in selected:
            target = targets[name]
            target["deps"] = sorted(set(target.get("deps", [])) | prerequisites)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-j", "--jobs", type=int, default=4, help="parallel build targets (default: 4)")
    parser.add_argument("--prepare-only", action="store_true", help="write the manifest without running tests")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")

    directory = ROOT / "bin" / "ast_suite"
    directory.mkdir(parents=True, exist_ok=True)
    base = directory / "base.json"
    output = directory / "build.json"
    subprocess.run(["bin/wbuildgen", "--out", str(base)], cwd=ROOT, check=True)
    manifest, counts = require_ast_expressions(json.loads(base.read_text()))
    serialize_build_tool_tests(manifest)
    output.write_text(json.dumps(manifest, indent=2) + "\n")
    print(
        f"AST suite manifest: {counts['required']} required compiler steps, "
        f"{counts['expected_failures']} expected compile failures, "
        f"{counts['explicit_modes']} explicit differential-mode steps, "
        f"{counts['fixture_groups']} diagnostic fixture groups",
        flush=True,
    )
    if args.prepare_only:
        print(output)
        return 0
    env = os.environ.copy()
    # did_you_mean_test explicitly tests FORCE_COLOR without inherited NO_COLOR.
    env.pop("NO_COLOR", None)
    return subprocess.run(
        ["./wbuild", "-f", str(output), "--keep-going", "-j", str(args.jobs), "tests"],
        cwd=ROOT, env=env,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
