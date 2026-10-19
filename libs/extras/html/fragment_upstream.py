#!/usr/bin/env python3
"""Compare unchanged pinned html5lib trees, preserving failures and denominator."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
STATUSES = ("PASS", "FAIL", "ERROR", "TIMEOUT", "UNSUPPORTED")


def execute(command, expected, timeout=10):
    """One native process owns one case; process failure never drops later cases."""
    try:
        run = subprocess.run(command, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", f"native execution exceeded {timeout}s", True
    except OSError as error:
        return "ERROR", f"native launch failed: {error}", False
    if run.returncode < 0:
        return "ERROR", f"native process terminated by signal {-run.returncode}", True
    try:
        output = run.stdout.decode("utf-8")
        errors = run.stderr.decode("utf-8")
    except UnicodeDecodeError as error:
        return "ERROR", f"malformed native UTF-8 output: {error}", True
    if run.returncode or output != expected:
        return "FAIL", (f"exit={run.returncode}, expected={expected!r}, "
                        f"actual={output!r}, stderr={errors!r}"), True
    return "PASS", "", True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--report", type=Path, default=Path("bin/html-fragment-upstream.json"))
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    manifest = json.loads((ROOT / "upstream/manifest.json").read_text())
    for name, record in manifest["files"].items():
        data = (ROOT / "upstream" / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise SystemExit(f"upstream hash mismatch: {name}")
    source = (ROOT / "upstream/tests4.dat").read_text()
    results = []
    for index, case in enumerate(source.split("#data\n")[1:], 1):
        data, rest = case.split("#errors\n", 1)
        data = data.removesuffix("\n")
        context = rest.split("#document-fragment\n", 1)[1].split("\n", 1)[0]
        expected = rest.split("#document\n", 1)[1].rstrip("\n") + "\n"
        status, reason, executed = execute([str(args.binary.resolve()), context, data],
                                          expected, args.timeout)
        results.append({"id": f"tests4.dat:{index}", "context": context,
                        "status": status, "reason": reason, "executed": executed})
    if len(results) != manifest["total_cases"]:
        raise SystemExit("upstream case count mismatch")
    inventory = json.loads((ROOT / "upstream/inventory.json").read_text())
    unexecuted = [record for record in inventory["files"] if record["execution"] == "NOT_RUN"]
    report = {"upstream": manifest["revision"], "total": inventory["total_cases"],
              "selected": len(results), "not_run": sum(r["cases"] for r in unexecuted),
              "executed": sum(r["executed"] for r in results),
              "counts": {s: sum(r["status"] == s for r in results) for s in STATUSES},
              "scope": "Tree outputs only; upstream parse-error lists remain unverified",
              "unexecuted_files": [{"path": r["path"], "cases": r["cases"], "status": "NOT_RUN"}
                                   for r in unexecuted], "results": results}
    report["counts"]["NOT_RUN"] = report["not_run"]
    if report["selected"] + report["not_run"] != report["total"]:
        raise SystemExit("full suite denominator mismatch")
    output = json.dumps(report, indent=2) + "\n"
    print(output, end="")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(output)
    return int(any(report["counts"][s] for s in ("FAIL", "ERROR", "TIMEOUT")))


if __name__ == "__main__":
    raise SystemExit(main())
