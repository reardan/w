#!/usr/bin/env python3
"""Reproducible, staged grammars-v4 compile sweep (Python standard library only)."""
import argparse
import concurrent.futures
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
STAGES = ("translate", "generate", "compile", "strict")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_output(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def load_manifest(path, corpus):
    manifest = json.loads(path.read_text())
    if manifest.get("schema") != 1:
        raise ValueError("unsupported sweep manifest schema")
    actual = git_output(corpus, "rev-parse", "HEAD")
    if actual != manifest["corpus_commit"]:
        raise ValueError(f"corpus revision mismatch: expected {manifest['corpus_commit']}, got {actual}")
    names = set()
    for case in manifest["cases"]:
        name = case["name"]
        if name in names or not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            raise ValueError(f"invalid or duplicate case name: {name}")
        names.add(name)
        if not case["inputs"]:
            raise ValueError(f"no pinned inputs for {name}")
        if set(case["expected_pass"]) - set(STAGES):
            raise ValueError(f"invalid baseline stage for {name}")
        removed = set(case.get("recorded_pass", [])) - set(case["expected_pass"])
        for stage in removed:
            reason = case.get("reclassified", {}).get(stage, "")
            if not isinstance(reason, str) or not reason.strip():
                raise ValueError(f"{name}: removing recorded {stage} pass requires a reclassified reason")
        for entry in case["inputs"]:
            path = (corpus / entry["path"]).resolve()
            if not path.is_relative_to(corpus.resolve()) or sha256(path) != entry["sha256"]:
                raise ValueError(f"corpus input hash/path mismatch: {entry['path']}")
    # Dependency resolution may load sibling .g4 files beyond the selected roots.
    # The pinned commit covers those bytes only if no modified/untracked grammar
    # can replace a dependency. This also rejects untracked sibling shadows.
    changed = git_output(corpus, "status", "--porcelain", "--untracked-files=all", "--", "*.g4")
    if changed:
        raise ValueError("corpus grammar files must be clean (including untracked siblings):\n" + changed)
    return manifest


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


def require_outputs(stage, paths):
    if stage["status"] == "pass":
        missing = [str(path) for path in paths if not path.is_file()]
        if missing:
            stage.update(status="error", error="missing output: " + ", ".join(missing))


def run_case(case, corpus, work, tools, timeout, repo=REPO):
    directory = work / case["name"]
    directory.mkdir()  # An existing case must never reuse stale outputs.
    parser_name = "sweep_" + re.sub(r"[^a-zA-Z0-9]", "_", case["name"])
    pg = directory / "grammar.pg"
    matchers = directory / "matchers.w"
    generated = directory / "parser.w"
    sources = [corpus / item["path"] for item in case["inputs"]]
    result = {"name": case["name"], "inputs": case["inputs"],
              "historical_288": case.get("historical_288", False),
              "stages": {stage: {"status": "not_run"} for stage in STAGES},
              "runtime_smoke": "not_configured"}
    stages = result["stages"]

    def translate(strict=False):
        prefix = "strict" if strict else "translate"
        output_pg = directory / "strict.pg" if strict else pg
        output_matchers = directory / "strict.matchers.w" if strict else matchers
        args = [tools["translator"], *sources, "-o", output_pg,
                "--parser-name", parser_name, "--matchers", output_matchers,
                "--report", directory / (prefix + ".report"),
                "--audit", directory / (prefix + ".audit"),
                "--dependencies", directory / (prefix + ".inputs")]
        if strict:
            args.append("--strict")
        status = run_stage(args, directory / (prefix + ".log"), timeout, repo)
        require_outputs(status, [output_pg, output_matchers, directory / (prefix + ".inputs")])
        return status

    stages["translate"] = translate()
    if stages["translate"]["status"] == "pass":
        stages["generate"] = run_stage([tools["generator"], pg, "-o", generated],
                                       directory / "generate.log", timeout, repo)
        require_outputs(stages["generate"], [generated])
        if stages["generate"]["status"] == "pass":
            program = directory / "compile.w"
            program.write_bytes(tools["common_matchers"].read_bytes() + b"\n" +
                                matchers.read_bytes() + b"\n" + generated.read_bytes() +
                                b"\nint main():\n\treturn 0\n")
            binary = directory / "parser.bin"
            stages["compile"] = run_stage([tools["compiler"], program, "-o", binary],
                                          directory / "compile.log", timeout, repo)
            require_outputs(stages["compile"], [binary])
    # Audit acceptance is an independent metric, including on failed translations.
    stages["strict"] = translate(strict=True)
    result["dependency_inputs"] = []
    loaded = directory / "translate.inputs"
    if loaded.exists():
        for value in loaded.read_text().splitlines():
            path = (repo / value).resolve()
            if not path.is_relative_to(corpus.resolve()):
                stages["translate"].update(status="error", error="dependency outside pinned corpus: " + value)
                break
            result["dependency_inputs"].append({"path": str(path.relative_to(corpus.resolve())),
                                                 "sha256": sha256(path)})
    return result


def compare(manifest, results):
    actual = {result["name"]: result for result in results}
    regressions = []
    for case in manifest["cases"]:
        if case["name"] not in actual:
            regressions.append(f"{case['name']}: missing result")
            continue
        for stage in case["expected_pass"]:
            status = actual[case["name"]]["stages"][stage]["status"]
            if status != "pass":
                regressions.append(f"{case['name']}: {stage} regressed to {status}")
    return regressions


def write_results(work, manifest, results, provenance, csv_path=None):
    regressions = compare(manifest, results)
    errors = list(provenance.get("infrastructure_errors", [])) + [f"{row['name']}: {stage} {value['status']}"
              for row in results for stage, value in row["stages"].items()
              if value["status"] in ("error", "timeout", "crash")]
    totals = {stage: sum(row["stages"][stage]["status"] == "pass" for row in results)
              for stage in STAGES}
    summary = {"cases": len(results), "passing": totals,
               "historical_288_compiled": sum(row["historical_288"] and
                   row["stages"]["compile"]["status"] == "pass" for row in results),
               "runtime_smoke": "not_configured", "regressions": regressions,
               "infrastructure_errors": errors}
    (work / "results.json").write_text(json.dumps({"provenance": provenance,
        "summary": summary, "cases": results}, indent=2) + "\n")
    with (csv_path or work / "results.csv").open("w", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(["name", "inputs", *STAGES, "runtime_smoke"])
        for row in results:
            writer.writerow([row["name"], ";".join(item["path"] for item in row["inputs"]),
                             *(row["stages"][stage]["status"] for stage in STAGES),
                             row["runtime_smoke"]])
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=os.environ.get("GV4"))
    parser.add_argument("--manifest", type=Path, default=HERE / "sweep_baseline.json")
    parser.add_argument("--work", type=Path, default=os.environ.get("WORK"),
                        help="new/empty artifact directory; default creates bin/grammar_sweep/run-*")
    parser.add_argument("--csv", type=Path, default=os.environ.get("OUT_CSV"))
    parser.add_argument("--jobs", type=int, default=os.environ.get("JOBS", 4))
    parser.add_argument("--timeout", type=float, default=90, help="seconds per stage")
    parser.add_argument("--case", action="append", help="run selected pinned case(s)")
    args = parser.parse_args(argv)
    if args.corpus is None:
        parser.error("set GV4 or pass --corpus (see README.md for pinned checkout)")
    if args.jobs < 1 or args.timeout <= 0:
        parser.error("jobs and timeout must be positive")
    try:
        corpus = args.corpus.resolve()
        manifest = load_manifest(args.manifest, corpus)
        if args.case:
            unknown = set(args.case) - {case["name"] for case in manifest["cases"]}
            if unknown:
                raise ValueError("unknown cases: " + ", ".join(sorted(unknown)))
            manifest = dict(manifest, cases=[case for case in manifest["cases"]
                                            if case["name"] in args.case])
        tools = {"translator": REPO / "bin/antlr_to_pg",
                 "generator": REPO / "bin/parser_generator_grammars",
                 "compiler": REPO / "bin/wv2",
                 "common_matchers": REPO / "libs/extras/grammars/matchers.w"}
        for name, path in tools.items():
            if not path.is_file() or (name != "common_matchers" and not os.access(path, os.X_OK)):
                raise ValueError(f"missing tool/input {path}; run ./wbuild antlr_to_pg")
        if args.work:
            work = args.work.resolve()
            work.mkdir(parents=True, exist_ok=True)
            if any(work.iterdir()):
                raise ValueError(f"artifact directory is not empty: {work}")
        else:
            parent = REPO / "bin/grammar_sweep"
            parent.mkdir(parents=True, exist_ok=True)
            work = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
        provenance = {"corpus_commit": manifest["corpus_commit"],
                      "w_commit": git_output(REPO, "rev-parse", "HEAD"),
                      "w_dirty": bool(git_output(REPO, "status", "--porcelain")),
                      "manifest_sha256": sha256(args.manifest),
                      "runner_sha256": sha256(Path(__file__)),
                      "tools_sha256": {name: sha256(path) for name, path in tools.items()},
                      "selection": args.case or "all pinned cases",
                      "timeout_seconds": args.timeout,
                      "compile_harness": "empty main; generated parser is not executed"}
        print(f"Artifacts: {work}", flush=True)
        results = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
            futures = {executor.submit(run_case, case, corpus, work, tools, args.timeout): case
                       for case in manifest["cases"]}
            for future in concurrent.futures.as_completed(futures):
                try:
                    result = future.result()
                except Exception as error:
                    # Finish the other cases and publish a complete denominator,
                    # even when a worker encounters a filesystem/tooling fault.
                    case = futures[future]
                    result = {"name": case["name"], "inputs": case["inputs"],
                              "historical_288": case.get("historical_288", False),
                              "runtime_smoke": "not_configured",
                              "stages": {stage: {"status": "error", "error": str(error)}
                                         for stage in STAGES}}
                results.append(result)
                print(f"[{len(results)}/{len(futures)}] {result['name']}: " +
                      " ".join(stage + "=" + result["stages"][stage]["status"] for stage in STAGES),
                      flush=True)
        results.sort(key=lambda row: row["name"])
        provenance["tools_sha256_after"] = {name: sha256(path) for name, path in tools.items()}
        provenance["infrastructure_errors"] = [f"tool/input changed during sweep: {name}"
            for name, digest in provenance["tools_sha256"].items()
            if provenance["tools_sha256_after"][name] != digest]
        if git_output(corpus, "status", "--porcelain", "--untracked-files=all", "--", "*.g4"):
            provenance["infrastructure_errors"].append("corpus grammar files changed during sweep")
        summary = write_results(work, manifest, results, provenance, args.csv)
        print(json.dumps(summary, indent=2))
        return 1 if summary["regressions"] or summary["infrastructure_errors"] else 0
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"sweep: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
