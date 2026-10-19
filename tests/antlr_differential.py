#!/usr/bin/env python3
"""Offline snapshot gate and optional checksum-pinned live ANTLR differential oracle.

No downloads occur here. CI supplies a verified jar; normal tests use committed
snapshots. Known incompatibilities are field-specific and unexpected fixes fail
until their ledger is promoted, preventing stale expected-failure exceptions.
"""
import argparse
import hashlib
import json
import os
import random
import signal
import time
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/grammars/antlr_differential"
# Keep the external Java reference runner self-contained: the repository sweep
# and its normal regression harness are now native W tools.
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_output(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def run_stage(argv, log, timeout, cwd):
    start = time.monotonic()
    result = {"argv": [str(arg) for arg in argv], "log": str(log), "status": "error"}
    with log.open("wb") as output:
        try:
            process = subprocess.Popen(result["argv"], cwd=cwd, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                result["exit_code"] = process.wait(timeout=timeout)
                result["status"] = ("pass" if process.returncode == 0 else
                                    "crash" if process.returncode < 0 else "fail")
            except subprocess.TimeoutExpired:
                # Kill descendants too: wrappers and compiler children must not
                # continue writing into artifacts after the stage timed out.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                result.update(status="timeout", exit_code=124)
                output.write(b"\nSWEEP: stage timeout\n")
        except OSError as error:
            output.write(str(error).encode())
            result["error"] = str(error)
    result["seconds"] = round(time.monotonic() - start, 3)
    return result

def observation(output, skip_tokens=(), observe_rules=(), channel_map=None, token_names=None):
    result = {"tokens": [], "rules": []}
    for line in output.splitlines():
        parts = line.split("\t")
        if parts[0] == "ACCEPT" and len(parts) == 2 and parts[1] in ("0", "1"):
            if "accepted" in result:
                raise ValueError("duplicate ACCEPT record")
            result["accepted"] = parts[1] == "1"
        elif parts[0] == "RULE" and len(parts) == 4:
            if parts[1] in observe_rules:
                result["rules"].append({"name": parts[1], "start": int(parts[2]), "length": int(parts[3])})
        elif parts[0] == "TOKEN" and len(parts) == 6:
            name, channel, start, length, encoded = parts[1:]
            if name in skip_tokens:
                continue
            raw = bytes.fromhex(encoded)
            normalized_channel = (channel_map or {}).get(channel, int(channel))
            name = (token_names or {}).get(name, name)
            token = {"name": name, "channel": normalized_channel, "start": int(start),
                     "length": int(length), "text": raw.decode("utf-8")}
            if token["length"] != len(raw) or token["start"] < 0:
                raise ValueError("invalid UTF-8 byte span")
            result["tokens"].append(token)
        else:
            raise ValueError("malformed oracle output: " + line)
    if "accepted" not in result or not result["tokens"] or result["tokens"][-1]["name"] != "EOF":
        raise ValueError("oracle output missing acceptance or EOF")
    return result


def mismatch_fields(actual, expected):
    return sorted(key for key in ("accepted", "tokens", "rules") if actual[key] != expected[key])


def check_mismatches(actual, expected, allowed):
    differences = mismatch_fields(actual, expected)
    if differences != sorted(allowed):
        raise ValueError(f"mismatch fields {differences}; expected known incompatibilities {sorted(allowed)}")
    return differences


def token_fuzz(seed, count):
    """Bounded stable corpus, retained in the manifest for review and replay."""
    rng = random.Random(seed)
    pieces = ["if", "iff", "abc", "123", "0", "?", "#comment\n", "#🙂\n"]
    return [{"id": f"fuzz{index}", "text": " ".join(rng.choice(pieces) for _ in range(rng.randrange(1, 7)))}
            for index in range(count)]


def load_manifest(path=FIXTURES / "manifest.json"):
    data = json.loads(path.read_text())
    if data["schema"] != 1:
        raise ValueError("unsupported differential manifest schema")
    for entry in data["files"]:
        source = (FIXTURES / entry["path"]).resolve()
        if not source.is_relative_to(FIXTURES.resolve()) or digest(source) != entry["sha256"]:
            raise ValueError("differential input hash/path mismatch: " + entry["path"])
    names = set()
    for case in data["cases"]:
        if case["name"] in names:
            raise ValueError("duplicate differential case " + case["name"])
        names.add(case["name"])
        if case.get("fuzz"):
            recipe = case["fuzz"]
            if recipe["algorithm"] != "tokens-v1":
                raise ValueError("unknown deterministic fuzz recipe")
            actual = [{"id": item["id"], "text": item["text"]} for item in case["inputs"] if item["id"].startswith("fuzz")]
            if actual != token_fuzz(recipe["seed"], recipe["count"]):
                raise ValueError("deterministic fuzz inputs differ from recipe")
        input_ids = set()
        for item in case["inputs"]:
            if item["id"] in input_ids or not re.fullmatch(r"[A-Za-z0-9_-]+", item["id"]):
                raise ValueError("invalid or duplicate input id")
            input_ids.add(item["id"])
            if "\0" in item["text"]:
                raise ValueError("embedded NUL requires a length-aware W driver")
            allowed = item.get("known_mismatches", {})
            if set(allowed) - {"accepted", "tokens", "rules"} or any(not value for value in allowed.values()):
                raise ValueError("known incompatibility needs supported field and explanation")
    return data


def command(argv, directory, name, timeout, provenance):
    log = directory / (name + ".log")
    result = run_stage(argv, log, timeout, ROOT)
    provenance[name] = result
    if result["status"] != "pass":
        raise ValueError(f"{name}: {result['status']}; see {log}")
    return log.read_text()


def build_w(case, directory, timeout, stages, extra_flags=()):
    pg, matchers, parser = (directory / filename for filename in ("grammar.pg", "matchers.w", "parser.w"))
    command([ROOT / "bin/antlr_to_pg", *(FIXTURES / path for path in case["grammars"]),
             "--parser-name", "oracle", "-o", pg, "--matchers", matchers,
             *case.get("flags", []), *extra_flags], directory, "w_translate", timeout, stages)
    command([ROOT / "bin/parser_generator_grammars", pg, "-o", parser], directory, "w_generate", timeout, stages)
    driver = (FIXTURES / "runtime.w.in").read_text().replace("START_RULE", case["w_start"])
    source = directory / "runtime.w"
    source.write_text((ROOT / "libs/extras/grammars/matchers.w").read_text() + "\n" +
                      matchers.read_text() + "\n" + parser.read_text() + "\n" + driver)
    binary = directory / "runtime"
    command([ROOT / "bin/wv2", source, "-o", binary, "--strict"], directory, "w_compile_strict", timeout, stages)
    return binary


def build_java(case, directory, jar, timeout, stages):
    java_dir = directory / "java"
    java_dir.mkdir()
    for source in case["grammars"]:
        shutil.copyfile(FIXTURES / source, java_dir / Path(source).name)
    shutil.copyfile(FIXTURES / "Oracle.java", java_dir / "Oracle.java")
    command(["java", "-jar", jar, "-Dlanguage=Java", "-o", java_dir,
             *(java_dir / Path(path).name for path in case["grammars"])], directory, "antlr_generate", timeout, stages)
    command(["javac", "-encoding", "UTF-8", "-cp", jar, "-d", java_dir,
             *sorted(java_dir.rglob("*.java"))], directory, "java_compile", timeout, stages)
    return ["java", "-cp", str(java_dir) + os.pathsep + str(jar), "Oracle", case["lexer"], case["parser"], case["start"]]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", type=Path, help="enable live oracle with the pinned local ANTLR jar")
    parser.add_argument("--oracle-only", action="store_true", help="verify committed snapshots without building W")
    parser.add_argument("--refresh-snapshots", action="store_true", help="explicitly regenerate snapshots with the live oracle")
    parser.add_argument("--require-compatible", action="store_true", help="require all witnesses to match; ignore known-mismatch allowances")
    parser.add_argument("--exact", action="store_true", help="gate exact lexer + prediction against all snapshots without legacy mismatch allowances")
    parser.add_argument("--translator-flag", action="append", default=[], help="additional translator flag, e.g. --translator-flag=--prediction")
    parser.add_argument("--work", type=Path)
    parser.add_argument("--case", action="append")
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args(argv)
    if (args.oracle_only or args.refresh_snapshots) and not args.jar:
        parser.error("--oracle-only/--refresh-snapshots requires --jar")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    data = load_manifest()
    if args.exact:
        args.translator_flag.extend(flag for flag in ("--exact-lexer", "--prediction") if flag not in args.translator_flag)
    if args.jar:
        args.jar = args.jar.resolve()
        if digest(args.jar) != data["oracle"]["jar_sha256"]:
            raise ValueError("ANTLR jar checksum mismatch")
    selected = [case for case in data["cases"] if not args.case or case["name"] in args.case]
    if args.case and set(args.case) - {case["name"] for case in selected}:
        raise ValueError("unknown differential case")
    if args.work:
        work = args.work.resolve()
        work.mkdir(parents=True, exist_ok=True)
        if any(work.iterdir()):
            raise ValueError("differential artifact directory must be empty")
    else:
        (ROOT / "bin/antlr_differential").mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix="run-", dir=ROOT / "bin/antlr_differential"))
    print(f"Artifacts: {work}", flush=True)
    provenance = {"oracle": data["oracle"], "manifest_sha256": digest(FIXTURES / "manifest.json"),
                  "runner_sha256": digest(Path(__file__)), "translator_flags": args.translator_flag,
                  "live_oracle": bool(args.jar), "exact": args.exact, "w_commit": git_output(ROOT, "rev-parse", "HEAD")}
    if args.jar:
        provenance["java_version"] = subprocess.check_output(["java", "-version"], stderr=subprocess.STDOUT, text=True)
        provenance["javac_version"] = subprocess.check_output(["javac", "-version"], stderr=subprocess.STDOUT, text=True)
        version = re.search(r'version "(\d+)', provenance["java_version"])
        if not version or int(version[1]) < data["oracle"]["minimum_java_major"]:
            raise ValueError("live oracle requires Java " + str(data["oracle"]["minimum_java_major"]) + " or newer")
    tools = [] if args.oracle_only else [ROOT / "bin" / name for name in ("antlr_to_pg", "parser_generator_grammars", "wv2")]
    provenance["tool_hashes"] = {str(path): digest(path) for path in tools}
    results, errors, new_snapshots = [], [], {}
    snapshots = json.loads((FIXTURES / "snapshots.json").read_text()) if not args.refresh_snapshots else {}
    for case in selected:
        directory = work / case["name"]
        directory.mkdir()
        stages = {}
        row = {"name": case["name"], "stages": stages, "inputs": []}
        results.append(row)
        try:
            java = build_java(case, directory, args.jar, args.timeout, stages) if args.jar else None
            binary = None if args.oracle_only else build_w(case, directory, args.timeout, stages, args.translator_flag)
            for item in case["inputs"]:
                key = case["name"] + "/" + item["id"]
                source = directory / (item["id"] + ".txt")
                source.write_text(item["text"])
                observation_row = {"id": item["id"]}
                row["inputs"].append(observation_row)
                expected = snapshots.get(key)
                if expected is None and not args.refresh_snapshots:
                    raise ValueError("missing oracle snapshot: " + key)
                if java:
                    live = observation(command([*java, source], directory, item["id"] + ".java", args.timeout, stages), observe_rules=case.get("observe_rules", []), channel_map=case.get("oracle_channels", {}))
                    new_snapshots[key] = live
                    if args.refresh_snapshots:
                        expected = live
                    elif live != expected:
                        raise ValueError(key + ": live ANTLR differs from pinned snapshot")
                    observation_row["oracle"] = live
                if binary:
                    actual = observation(command([binary, source], directory, item["id"] + ".w", args.timeout, stages), case.get("skip_tokens", []), case.get("observe_rules", []), case.get("w_channels", {}), case.get("w_token_names", {}))
                    observation_row["w"] = actual
                    allowed = {} if args.require_compatible or args.exact else item.get("known_mismatches", {})
                    observation_row["differences"] = mismatch_fields(actual, expected)
                    try:
                        observation_row["known_mismatches"] = check_mismatches(actual, expected, allowed)
                    except ValueError as error:
                        observation_row["status"] = "fail"
                        observation_row["error"] = str(error)
                        errors.append(key + ": " + str(error))
                        continue
                observation_row["status"] = "pass"
        except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
            row["error"] = str(error)
            errors.append(case["name"] + ": " + str(error))
        print(case["name"] + (": ERROR " + row["error"] if "error" in row else ": mismatch" if any(item.get("status") == "fail" for item in row["inputs"]) else ": pass"), flush=True)
    for path in tools:
        if digest(path) != provenance["tool_hashes"][str(path)]:
            errors.append("tool changed during differential run: " + str(path))
    configured = sum(len(case["inputs"]) for case in selected)
    summary = {"configured_grammars": len(selected), "configured_inputs": configured,
               "completed_inputs": sum(item.get("status") == "pass" for row in results for item in row["inputs"]),
               "known_mismatching_inputs": sum(bool(item.get("known_mismatches")) for row in results for item in row["inputs"]),
               "errors": errors}
    (work / "results.json").write_text(json.dumps({"schema": 1, "provenance": provenance, "summary": summary, "cases": results}, indent=2) + "\n")
    if args.refresh_snapshots and not errors:
        if args.case:
            old = json.loads((FIXTURES / "snapshots.json").read_text())
            old.update(new_snapshots)
            new_snapshots = old
        (FIXTURES / "snapshots.json").write_text(json.dumps(new_snapshots, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, indent=2))
    return bool(errors)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("differential: " + str(error), file=sys.stderr)
        sys.exit(2)
