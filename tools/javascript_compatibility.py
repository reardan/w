#!/usr/bin/env python3
"""Pinned JavaScript syntax differential tests; no downloads or implicit skips.

Uses a declared Test262 subset, a licensed real-source file, and controlled
execution examples. Test262 harness code is parsed, never executed. Requires
POSIX wait4 for per-child peak RSS and enforces the checked-in Node version.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "tests/javascript/corpus"
UPSTREAM = ROOT / "libs/extras/grammars/antlr_to_pg/testdata/antlr/javascript"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify_hash(path: Path, expected: str) -> None:
    require(path.is_file(), f"missing pinned file: {path}")
    require(hashlib.sha256(path.read_bytes()).hexdigest() == expected,
            f"source hash changed: {path}")


def verify_pins(manifest: dict) -> int:
    upstream = json.loads((UPSTREAM / "UPSTREAM.json").read_text())
    for entry in upstream["files"]:
        verify_hash(UPSTREAM / entry["path"], entry["sha256"])
    profile = json.loads((UPSTREAM / "ADAPTATIONS.json").read_text())
    require(profile["upstream_commit"] == upstream["commit"], "adaptation revision mismatch")
    blockers = (UPSTREAM / "BLOCKERS.txt").read_text()
    records = re.findall(r"^libs/", blockers, re.M)
    require(len(records) == len(profile["sites"]), "adaptation site inventory changed")
    for site in profile["sites"]:
        data = (UPSTREAM / site["file"]).read_bytes()
        expected = site["expected"].encode()
        require(data[site["offset"]:site["offset"] + len(expected)] == expected,
                f"unknown or changed adaptation site: {site['file']}:{site['line']}")
        require(site["status"] in {"adapted-subset", "deferred"}, "unknown adaptation status")
        for native in site["native_files"]:
            require((ROOT / native).is_file(), f"missing native adaptation: {native}")
    for entry in manifest["cases"]:
        verify_hash(CORPUS / entry["path"], entry["sha256"])
    verify_hash(CORPUS / "test262/LICENSE", manifest["upstream"]["license_sha256"])
    for entry in manifest["real_sources"]:
        pin_path = CORPUS / entry["upstream_manifest"]
        pin = json.loads(pin_path.read_text())
        for item in pin["files"]:
            verify_hash(pin_path.parent / item["path"], item["sha256"])
    return len(profile["sites"])


def metadata(source: str) -> tuple[list[str], str | None]:
    match = re.search(r"/\*---\n(.*?)\n---\*/", source, re.S)
    require(match is not None, "Test262 metadata block missing")
    block = match.group(1)
    flags_match = re.search(r"^flags: *\[([^\]]*)\]", block, re.M)
    require(not re.search(r"^flags:", block, re.M) or flags_match is not None,
            "unsupported flags format; update metadata reader explicitly")
    flags = [item.strip() for item in flags_match.group(1).split(",") if item.strip()] if flags_match else []
    require(set(flags) <= {"module", "onlyStrict", "noStrict", "raw", "generated"}, f"unsupported flags: {flags}")
    require(not ({"onlyStrict", "noStrict"} <= set(flags)), "conflicting strict flags")
    negative = re.search(r"^negative:\n((?:[ \t]+[^\n]*\n?)+)", block, re.M)
    phase = None
    if negative:
        phase_match = re.search(r"\bphase: *(\w+)", negative.group(1))
        type_match = re.search(r"\btype: *(\w+)", negative.group(1))
        require(phase_match is not None and type_match is not None, "malformed negative metadata")
        phase = phase_match.group(1)
        require(phase in {"parse", "early", "resolution", "runtime"}, f"unknown negative phase: {phase}")
        if phase in {"parse", "early"}:
            require(type_match.group(1) == "SyntaxError", "non-SyntaxError parse negative")
    return flags, phase


def run(command: list[str], timeout: float, data: bytes | None = None) -> dict:
    """Temporary files avoid pipe deadlocks while wait4 collects process RSS."""
    start = time.monotonic()
    with tempfile.TemporaryFile() as inp, tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        if data is not None:
            inp.write(data)
        inp.seek(0)
        child = subprocess.Popen(command, stdin=inp, stdout=out, stderr=err, cwd=ROOT)
        timed_out = False
        while True:
            pid, status, usage = os.wait4(child.pid, os.WNOHANG)
            if pid:
                break
            if time.monotonic() - start > timeout:
                child.kill()
                pid, status, usage = os.wait4(child.pid, 0)
                timed_out = True
                break
            time.sleep(0.003)
        child.returncode = os.waitstatus_to_exitcode(status)
        out.seek(0)
        err.seek(0)
        rss = usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss * 1024
        return {"exit": child.returncode, "seconds": round(time.monotonic() - start, 6),
                "peak_rss_bytes": int(rss), "timed_out": timed_out,
                "stdout": out.read().decode(errors="replace"),
                "stderr": err.read().decode(errors="replace")}


def oracle(node: str, source: str, module: bool, timeout: float) -> dict:
    if module:
        command = [node, "--input-type=module", "--check"]
    else:
        command = [node, "-e", "new (require('vm').Script)(require('fs').readFileSync(0, 'utf8'));"]
    return run(command, timeout, source.encode())


def check_case(parser: str, node: str, source: str, module: bool, expected: bool,
               name: str, work: Path, timeout: float) -> dict:
    path = work / ("case.mjs" if module else "case.js")
    path.write_text(source)
    command = [parser, "--check"] + (["--module"] if module else []) + [str(path)]
    w_result = run(command, timeout)
    node_result = oracle(node, source, module, timeout)
    valid_exits = w_result["exit"] in {0, 1} and node_result["exit"] in {0, 1}
    agree = ((w_result["exit"] == 0) == expected == (node_result["exit"] == 0))
    passed = valid_exits and agree and not w_result["timed_out"] and not node_result["timed_out"]
    return {"name": name, "module": module, "expected_accept": expected,
            "bytes": len(source.encode()), "passed": passed, "w": w_result, "node": node_result}


def consumer_examples(parser: str, builder: str, transform: str, node: str,
                      work: Path, timeout: float) -> list[dict]:
    built = run([builder], timeout)
    built_path = work / "built.mjs"
    built_path.write_text(built["stdout"])
    built_syntax = check_case(parser, node, built["stdout"], True, True,
                              "builder-output", work, timeout)
    greet = "import { greet } from " + json.dumps(built_path.as_uri()) + "; console.log(greet('world'));"
    built_execution = run([node, "--input-type=module", "-e", greet], timeout)
    builder_passed = (built["exit"] == 0 and not built["timed_out"] and built_syntax["passed"]
                      and built_execution["exit"] == 0 and not built_execution["timed_out"]
                      and built_execution["stdout"] == "Hello, world\n")

    # Comments, CRLF, spacing, and an unrelated matching string must survive.
    source = ('// Keep "./old.mjs" in this comment.\r\n'
              'import { value } from "./old.mjs";  // keep spacing\r\n'
              'export { value as forwarded } from "./old.mjs";\r\n'
              'const untouched = "./old.mjs";\r\n'
              'console.log(value + ":" + untouched);\r\n')
    expected = source.replace('from "./old.mjs"', 'from "./new.mjs"')
    for name in ["old.mjs", "new.mjs"]:
        (work / name).write_text("export const value = 7;\n")
    original_path = work / "original.mjs"
    original_path.write_text(source)
    rewritten = run([transform, str(original_path), "./old.mjs", "./new.mjs"], timeout)
    transformed_path = work / "transformed.mjs"
    transformed_path.write_text(rewritten["stdout"])
    before_syntax = check_case(parser, node, source, True, True, "transform-input", work, timeout)
    after_syntax = check_case(parser, node, rewritten["stdout"], True, True,
                             "transform-output", work, timeout)
    before = run([node, str(original_path)], timeout)
    after = run([node, str(transformed_path)], timeout)
    preserved = rewritten["stdout"].encode() == expected.encode()
    transform_passed = (rewritten["exit"] == 0 and not rewritten["timed_out"] and preserved
                        and before_syntax["passed"] and after_syntax["passed"]
                        and before["exit"] == 0 and after["exit"] == 0
                        and not before["timed_out"] and not after["timed_out"]
                        and before["stdout"] == after["stdout"] == "7:./old.mjs\n")
    return [{"name": "consumer-builder", "passed": builder_passed, "builder": built,
             "syntax": built_syntax, "execution": built_execution},
            {"name": "consumer-transform", "passed": transform_passed, "transform": rewritten,
             "unrelated_bytes_preserved": preserved, "input_syntax": before_syntax,
             "output_syntax": after_syntax, "original_execution": before,
             "transformed_execution": after}]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--parser", default="bin/javascript_inspect")
    ap.add_argument("--builder", default="bin/javascript_build_example")
    ap.add_argument("--transform", default="bin/javascript_transform")
    ap.add_argument("--node", default="node")
    ap.add_argument("--report", default="bin/javascript-compatibility.json")
    ap.add_argument("--timeout", type=float, default=15)
    args = ap.parse_args()
    require(hasattr(os, "wait4"), "compatibility metrics require POSIX wait4")
    parser = str((ROOT / args.parser).resolve()) if not Path(args.parser).is_absolute() else args.parser
    require(Path(parser).is_file() and os.access(parser, os.X_OK), f"parser unavailable: {parser}")
    builder = str((ROOT / args.builder).resolve())
    transform = str((ROOT / args.transform).resolve())
    require(Path(builder).is_file() and os.access(builder, os.X_OK), f"builder unavailable: {builder}")
    require(Path(transform).is_file() and os.access(transform, os.X_OK), f"transform unavailable: {transform}")
    node = shutil.which(args.node)
    require(node is not None, f"required Node oracle unavailable: {args.node}")
    manifest = json.loads((CORPUS / "manifest.json").read_text())
    version = subprocess.check_output([node, "--version"], text=True).strip()
    require(version == manifest["node_version"], f"Node version {version}; required {manifest['node_version']}")
    site_count = verify_pins(manifest)
    results = []
    growth = []
    execution = []
    with tempfile.TemporaryDirectory(prefix="w-javascript-compat-") as directory:
        work = Path(directory)
        for entry in manifest["cases"]:
            source = (CORPUS / entry["path"]).read_text()
            flags, phase = metadata(source)
            module = "module" in flags
            variants = [False] if module or "raw" in flags or "noStrict" in flags else [True] if "onlyStrict" in flags else [False, True]
            expected = phase not in {"parse", "early"}
            for strict in variants:
                variant = "module" if module else "strict" if strict else "sloppy"
                text = ('"use strict";\n' if strict else "") + source
                results.append(check_case(parser, node, text, module, expected,
                                          f"{entry['path']}:{variant}", work, args.timeout))
        for entry in manifest["real_sources"]:
            source = (CORPUS / entry["path"]).read_text()
            results.append(check_case(parser, node, source, entry["mode"] == "module", True,
                                      entry["path"], work, args.timeout))
        for count in [16, 64, 256]:
            # Increasing-size complete programs; unique bindings avoid duplicate-declaration errors.
            source = "".join(f"const v{i} = /a[b]+/i.test(`x${{{i}}}`) ? {i} / 2 : 0;\n" for i in range(count))
            result = check_case(parser, node, source, False, True, f"growth:{count}", work, args.timeout)
            result["statements"] = count
            growth.append(result)
        for entry in manifest["controlled_execution"]:
            syntax = check_case(parser, node, entry["source"], False, True, entry["name"], work, args.timeout)
            actual = run([node, "--input-type=commonjs"], args.timeout, entry["source"].encode())
            execution.append({"name": entry["name"], "syntax": syntax, "result": actual,
                              "passed": syntax["passed"] and actual["exit"] == 0 and actual["stdout"] == entry["stdout"]})
        # Execute consumers while their temporary modules and dependencies exist.
        consumers = consumer_examples(parser, builder, transform, node, work, args.timeout)
    failures = [r["name"] for r in results + growth + execution + consumers if not r["passed"]]
    report = {"node_version": version, "test262_commit": manifest["upstream"]["commit"],
              "adaptation_sites_verified": site_count, "syntax_cases": len(results),
              "syntax_passed": sum(r["passed"] for r in results), "failures": failures,
              "exclusions": manifest["exclusions"], "cases": results, "growth": growth,
              "controlled_execution": execution, "consumer_examples": consumers}
    destination = ROOT / args.report
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2) + "\n")
    print(f"JavaScript syntax: {report['syntax_passed']}/{len(results)}; growth: {sum(r['passed'] for r in growth)}/{len(growth)}; execution: {sum(r['passed'] for r in execution)}/{len(execution)}")
    print(f"Consumer examples: {sum(r['passed'] for r in consumers)}/{len(consumers)}")
    print(f"Verified {site_count} upstream adaptation sites; report: {destination}")
    for exclusion in manifest["exclusions"]:
        print(f"Excluded scope: {exclusion['scope']}: {exclusion['reason']}")
    for failure in failures:
        print(f"FAIL: {failure}")
    return int(bool(failures))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"javascript compatibility: {error}", file=sys.stderr)
        raise SystemExit(2)
