#!/usr/bin/env python3
"""Parse-tree differential between W prediction parsers and pinned ANTLR trees.

Each case translates its grammar with the exact lexer and complete-input
prediction, generates and compiles a W parser, parses every pinned input and
projects the W AST onto ANTLR's canonical parse tree
(libs/extras/grammars/antlr_to_pg/canonical_tree.w). The projection is compared
with committed ANTLR 4.13.2 observations from TreeOracle.java: acceptance, and
for accepted inputs the complete tree of rule names, context classes (labels)
and token text. Precedence, associativity and ambiguity selection all show in
the tree shape.

Ordinary runs are offline. `--jar` additionally regenerates every observation
with a checksum-pinned local ANTLR jar and fails when it differs from the
snapshot; only `--jar --refresh-snapshots` rewrites snapshots.json. Known
differences are per input, need an explanation, and fail when they disappear.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/grammars/antlr_trees"
ORACLE_SOURCES = [ROOT / "tests/grammars/antlr_left_recursion/Inspect.java",
                  ROOT / "tests/grammars/antlr_left_recursion/TreeOracle.java"]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_manifest():
    data = json.loads((FIXTURES / "manifest.json").read_text())
    names = set()
    for case in data["cases"]:
        if case["name"] in names:
            raise ValueError("duplicate case " + case["name"])
        names.add(case["name"])
        for path, expected in case["grammar_sha256"].items():
            if digest(ROOT / path) != expected:
                raise ValueError(case["name"] + ": grammar hash mismatch for " + path)
        if [path for path in case["grammar_sha256"]] != case["grammars"]:
            raise ValueError(case["name"] + ": grammar hashes must list every grammar in order")
        ids = [item["id"] for item in case["inputs"]]
        if len(ids) != len(set(ids)):
            raise ValueError(case["name"] + ": duplicate input id")
        for key, reason in case.get("known_differences", {}).items():
            if key not in ids or not reason:
                raise ValueError(case["name"] + ": known difference needs an input id and an explanation")
    return data


def run(argv, log, timeout, cwd=ROOT, env=None):
    with open(log, "wb") as output:
        try:
            process = subprocess.run([str(arg) for arg in argv], cwd=cwd, stdout=subprocess.PIPE,
                                     stderr=output, timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            raise ValueError(f"timeout after {timeout}s: {log}")
    if process.returncode != 0:
        raise ValueError(f"exit {process.returncode}: see {log}")
    return process.stdout.decode()


def build_w(case, directory, flags, timeout):
    pg, matchers, parser = (directory / name for name in ("grammar.pg", "matchers.w", "parser.w"))
    run([ROOT / "bin/antlr_to_pg", *(ROOT / path for path in case["grammars"]), "--parser-name", "oracle",
         "--start", case["start"], "-o", pg, "--matchers", matchers, *flags], directory / "w_translate.log", timeout)
    run([ROOT / "bin/parser_generator_grammars", pg, "-o", parser], directory / "w_generate.log", timeout)
    source = directory / "runtime.w"
    source.write_text((ROOT / "libs/extras/grammars/matchers.w").read_text() + "\n" + matchers.read_text() + "\n" +
                      parser.read_text() + "\n" + (FIXTURES / "runtime.w.in").read_text())
    binary = directory / "runtime"
    run([ROOT / "bin/wv2", source, "-o", binary], directory / "w_compile.log", timeout)
    return binary


def java_env():
    env = dict(os.environ)
    env.pop("JAVA_TOOL_OPTIONS", None)
    return env


def build_java(case, directory, jar, timeout):
    java = directory / "java"
    java.mkdir()
    for path in case["grammars"]:
        shutil.copyfile(ROOT / path, java / Path(path).name)
    for path in ORACLE_SOURCES:
        shutil.copyfile(path, java / path.name)
    run(["java", "-jar", jar, "-Dlanguage=Java", "-o", java, *(java / Path(path).name for path in case["grammars"])],
        directory / "antlr_generate.log", timeout, env=java_env())
    run(["javac", "-encoding", "UTF-8", "-cp", jar, "-d", java, *sorted(java.glob("*.java"))],
        directory / "java_compile.log", timeout, env=java_env())
    return ["java", "-cp", str(java) + os.pathsep + str(jar), "TreeOracle", case["java_name"], case["start"]]


def observe(output):
    value = json.loads(output)
    return {"accepted": bool(value["accepted"]), "tree": value["tree"] if value["accepted"] else None}


def run_case(case, work, args, snapshots):
    directory = work / case["name"]
    directory.mkdir()
    row = {"name": case["name"], "inputs": [], "errors": [], "live": {}}
    try:
        java = build_java(case, directory, args.jar, args.timeout) if args.jar else None
        binary = None if args.oracle_only else build_w(case, directory, args.translator_flags, args.timeout)
        known = case.get("known_differences", {})
        for item in case["inputs"]:
            key = case["name"] + "/" + item["id"]
            source = directory / (item["id"] + ".txt")
            source.write_bytes(item["text"].encode())
            expected = snapshots.get(key)
            if java:
                live = observe(run([*java, source], directory / (item["id"] + ".java.log"), args.timeout, env=java_env()))
                row["live"][key] = live
                if args.refresh_snapshots or args.corpus:
                    expected = live
                elif live != expected:
                    row["errors"].append(key + ": live ANTLR differs from the pinned snapshot")
            if expected is None:
                row["errors"].append(key + ": missing snapshot")
                continue
            if binary is None:
                continue
            actual = observe(run([binary, source], directory / (item["id"] + ".w.log"), args.timeout))
            same = actual == expected
            status = "match" if same else "known_difference" if item["id"] in known else "mismatch"
            if same and item["id"] in known:
                status = "unexpected_fix"
            row["inputs"].append({"id": item["id"], "status": status, "w": actual, "antlr": expected})
            if status in ("mismatch", "unexpected_fix"):
                row["errors"].append(key + ": " + status)
    except (OSError, ValueError, KeyError) as error:
        row["errors"].append(case["name"] + ": " + str(error))
    return row


def corpus_cases(corpus, names, max_examples):
    """Live-only cases from the pinned sweep manifest and its runtime examples."""
    baseline = json.loads((ROOT / "libs/extras/grammars/antlr_to_pg/sweep_baseline.json").read_text())
    selected = {case["name"]: case for case in baseline["cases"]}
    cases = []
    for name in names:
        entry = selected[name]
        grammars = [corpus / item["path"] for item in entry["inputs"]]
        for path, item in zip(grammars, entry["inputs"]):
            if digest(path) != item["sha256"]:
                raise ValueError(name + ": corpus grammar hash mismatch")
        declared = re.search(r"^\s*(?:parser\s+)?grammar\s+(\w+)\s*;", grammars[-1].read_text(), re.M)[1]
        java_name = declared[:-len("Parser")] if declared.endswith("Parser") else declared
        inputs = []
        for index, example in enumerate(entry.get("runtime", {}).get("examples", [])[:max_examples]):
            path = corpus / example["path"]
            if digest(path) != example["sha256"]:
                raise ValueError(name + ": corpus example hash mismatch")
            inputs.append({"id": "%02d" % (index + 1), "path": example["path"], "text": path.read_bytes().decode("utf-8", "replace")})
        cases.append({"name": name, "grammars": [str(path) for path in grammars], "java_name": java_name,
                      "start": entry["runtime"]["entry"], "inputs": inputs})
    return cases


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jar", type=Path, help="also run the live oracle with the pinned local ANTLR jar")
    parser.add_argument("--oracle-only", action="store_true", help="verify snapshots with the live oracle without building W")
    parser.add_argument("--refresh-snapshots", action="store_true", help="rewrite snapshots from the live oracle")
    parser.add_argument("--case", action="append", help="limit to named cases")
    parser.add_argument("--work", type=Path, help="new or empty artifact directory")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--corpus", type=Path, help="live-only: compare pinned grammars-v4 examples (needs --jar)")
    parser.add_argument("--sweep-case", action="append", default=[], help="with --corpus: sweep case name")
    parser.add_argument("--max-examples", type=int, default=10)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args(argv)
    if (args.oracle_only or args.refresh_snapshots) and not args.jar:
        parser.error("--oracle-only/--refresh-snapshots require --jar")
    data = load_manifest()
    args.translator_flags = data["translator_flags"]
    if args.jar:
        args.jar = args.jar.resolve()
        if digest(args.jar) != data["oracle"]["jar_sha256"]:
            raise ValueError("ANTLR jar checksum mismatch")
        version = subprocess.run(["java", "-version"], capture_output=True, text=True, env=java_env()).stderr
        major = re.search(r'version "(\d+)', version)
        if not major or int(major[1]) < data["oracle"]["minimum_java_major"]:
            raise ValueError("live oracle requires Java " + str(data["oracle"]["minimum_java_major"]) + " or newer")
    if args.corpus:
        if not args.jar or args.refresh_snapshots:
            parser.error("--corpus needs --jar and never refreshes snapshots")
        selected = corpus_cases(args.corpus.resolve(), args.sweep_case, args.max_examples)
    else:
        selected = [case for case in data["cases"] if not args.case or case["name"] in args.case]
    if args.case and set(args.case) - {case["name"] for case in selected}:
        raise ValueError("unknown case")
    if args.work:
        work = args.work.resolve()
        work.mkdir(parents=True, exist_ok=True)
        if any(work.iterdir()):
            raise ValueError("artifact directory must be empty")
    else:
        (ROOT / "bin/antlr_tree_differential").mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix="run-", dir=ROOT / "bin/antlr_tree_differential"))
    print("Artifacts: " + str(work), flush=True)
    tools = [] if args.oracle_only else [ROOT / "bin" / name for name in ("antlr_to_pg", "parser_generator_grammars", "wv2")]
    hashes = {str(path): digest(path) for path in tools}
    snapshots = {} if args.corpus else json.loads((FIXTURES / "snapshots.json").read_text())
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        rows = list(pool.map(lambda case: run_case(case, work, args, snapshots), selected))
    errors = [error for row in rows for error in row["errors"]]
    for path in tools:
        if digest(path) != hashes[str(path)]:
            errors.append("tool changed during the run: " + str(path))
    statuses = [item["status"] for row in rows for item in row["inputs"]]
    summary = {"cases": len(selected), "inputs": sum(len(case["inputs"]) for case in selected),
               "matched": statuses.count("match"), "known_differences": statuses.count("known_difference"),
               "accepted_by_antlr": sum(1 for row in rows for item in row["inputs"] if item["antlr"]["accepted"]),
               "errors": errors}
    (work / "results.json").write_text(json.dumps({"schema": 1, "manifest_sha256": digest(FIXTURES / "manifest.json"),
                                                   "tool_hashes": hashes, "summary": summary, "cases": rows}, indent=2) + "\n")
    for row in rows:
        print(row["name"] + ": " + ("; ".join(row["errors"]) if row["errors"] else "pass"), flush=True)
    if args.refresh_snapshots:
        complete = all(len(row["live"]) == len(case["inputs"]) for row, case in zip(rows, selected))
        if not complete:
            errors.append("live oracle incomplete; snapshots left unchanged")
        else:
            merged = dict(snapshots)
            for row in rows:
                merged.update(row["live"])
            pinned = {case["name"] + "/" + item["id"] for case in data["cases"] for item in case["inputs"]}
            merged = {key: value for key, value in merged.items() if key in pinned}
            (FIXTURES / "snapshots.json").write_text(json.dumps(merged, indent=1, sort_keys=True) + "\n")
            print("refreshed " + str(FIXTURES / "snapshots.json"))
    print(json.dumps(summary, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print("antlr_tree_differential: " + str(error), file=sys.stderr)
        sys.exit(2)
