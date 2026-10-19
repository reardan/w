#!/usr/bin/env python3
"""Compare unchanged pinned html5lib trees, preserving failures and denominator."""
import argparse
import hashlib
from datetime import datetime, timezone
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
    except (OSError, ValueError) as error:
        return "ERROR", f"native launch failed: {error}", False
    if run.returncode < 0:
        return "ERROR", f"native process terminated by signal {-run.returncode}", True
    try:
        output = run.stdout.decode("utf-8")
        errors = run.stderr.decode("utf-8")
    except UnicodeDecodeError as error:
        return "ERROR", f"malformed native UTF-8 output: {error}", True
    if run.returncode == 4:
        return "UNSUPPORTED", "native fragment context is not implemented", True
    if run.returncode or output != expected:
        return "FAIL", (f"exit={run.returncode}, expected={expected!r}, "
                        f"actual={output!r}, stderr={errors!r}"), True
    return "PASS", "", True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--profile", choices=("historical", "modern-select"), default="historical")
    parser.add_argument("--gate", choices=("selected", "select-context", "full-corpus"), default="selected")
    parser.add_argument("--report", type=Path, default=Path("bin/html-fragment-upstream.json"))
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    if args.gate == "select-context" and args.profile != "modern-select":
        parser.error("select-context gate requires modern-select profile")
    prefix = "modern/" if args.profile == "modern-select" else ""
    manifest_name = prefix + "manifest.json"
    inventory_name = prefix + "inventory.json"
    manifest_bytes = (ROOT / "upstream" / manifest_name).read_bytes()
    inventory_bytes = (ROOT / "upstream" / inventory_name).read_bytes()
    manifest = json.loads(manifest_bytes)
    inventory = json.loads(inventory_bytes)
    frozen_files = {manifest_name: manifest_bytes, inventory_name: inventory_bytes}
    for name, record in manifest["files"].items():
        data = (ROOT / "upstream" / name).read_bytes()
        frozen_files[name] = data
        if hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise SystemExit(f"upstream hash mismatch: {name}")
    def revision(path):
        run = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True)
        return run.stdout.strip() if run.returncode == 0 else None
    try:
        driver_hash = hashlib.sha256(args.binary.read_bytes()).hexdigest()
        driver_error = None
    except OSError as error:
        driver_hash, driver_error = None, str(error)
    w_root = ROOT.parents[2]
    evidence = {
        "kind": "fresh-execution", "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "w_revision": revision(w_root), "application_revision": revision(w_root.parent),
        "driver_sha256": driver_hash, "driver_hash_error": driver_error,
        "adapter_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "parser_sha256": hashlib.sha256((ROOT / "html.w").read_bytes()).hexdigest(),
        "driver_source_sha256": hashlib.sha256((ROOT / "fragment_fixture.w").read_bytes()).hexdigest(),
        "fixtures": manifest["files"],
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "inventory_sha256": hashlib.sha256(inventory_bytes).hexdigest(),
        "scope": "Tree outputs in both scripting modes; selected document families are scripting-insensitive. Parse-error lists, foreign content and script execution remain unverified."}
    results = []
    for name in manifest["files"]:
        if not name.endswith(".dat"):
            continue
        source = frozen_files[name].decode("utf-8")
        for index, case in enumerate(source.split("#data\n")[1:], 1):
            data, rest = case.split("#errors\n", 1)
            data = data.removesuffix("\n")
            context = "#document"
            if "#document-fragment\n" in rest:
                context = rest.split("#document-fragment\n", 1)[1].split("\n", 1)[0]
            expected = rest.split("#document\n", 1)[1].rstrip("\n") + "\n"
            modes = [0, 1]
            if "#script-off\n" in rest: modes = [0]
            if "#script-on\n" in rest: modes = [1]
            variants = []
            for scripting in modes:
                status, reason, executed = execute(
                    [str(args.binary.resolve()), context, data, str(scripting)],
                    expected, args.timeout)
                variants.append({"scripting": bool(scripting), "status": status,
                                 "reason": reason, "executed": executed})
            # One case keeps one result even when both scripting modes run.
            bad = next((v for v in variants if v["status"] != "PASS"), variants[0])
            results.append({"id": f"{name}:{index}", "context": context,
                            "status": bad["status"], "reason": bad["reason"],
                            "executed": any(v["executed"] for v in variants),
                            "variants": variants})
    if len(results) != manifest["total_cases"]:
        raise SystemExit("upstream case count mismatch")
    changed = []
    for name, expected in (("html.w", evidence["parser_sha256"]),
                           ("fragment_fixture.w", evidence["driver_source_sha256"]),
                           ("fragment_upstream.py", evidence["adapter_sha256"])):
        try:
            if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
                changed.append(name)
        except OSError:
            changed.append(name + " disappeared")
    if revision(w_root) != evidence["w_revision"] or revision(w_root.parent) != evidence["application_revision"]:
        changed.append("repository HEAD")
    if driver_hash is not None:
        try:
            if hashlib.sha256(args.binary.read_bytes()).hexdigest() != driver_hash:
                changed.append("driver binary")
        except OSError:
            changed.append("driver binary disappeared")
    for name, frozen in frozen_files.items():
        try:
            if (ROOT / "upstream" / name).read_bytes() != frozen:
                changed.append("upstream/" + name)
        except OSError:
            changed.append("upstream/" + name + " disappeared")
    evidence["changed_during_execution"] = changed
    if changed:
        for result in results:
            result["observed_status"] = result["status"]
            result["status"] = "ERROR"
            result["reason"] = "provenance changed during execution: " + ", ".join(changed)
            for variant in result["variants"]:
                variant["observed_status"] = variant["status"]
                variant["status"] = "ERROR"
                variant["reason"] = result["reason"]
    unexecuted = [record for record in inventory["files"] if record["execution"] == "NOT_RUN"]
    report = {"upstream": manifest["revision"], "repository": manifest["repository"],
              "execution_kind": "native-tree-comparison", "browser_wpt_execution": False,
              "total": inventory["total_cases"],
              "selected": len(results), "not_run": sum(r["cases"] for r in unexecuted),
              "executed": sum(r["executed"] for r in results),
              "counts": {s: sum(r["status"] == s for r in results) for s in STATUSES},
              "scope": "Tree outputs only; upstream parse-error lists remain unverified",
              "unexecuted_files": [{"path": r["path"], "cases": r["cases"], "status": "NOT_RUN"}
                                   for r in unexecuted], "results": results}
    report["counts"]["NOT_RUN"] = report["not_run"]
    if report["selected"] + report["not_run"] != report["total"]:
        raise SystemExit("full suite denominator mismatch")
    variants = [v for r in results for v in r["variants"]]
    report["variant_counts"] = {s: sum(v["status"] == s for v in variants) for s in STATUSES}
    report["selected_variants"] = len(variants)
    report["executed_variants"] = sum(v["executed"] for v in variants)
    report["evidence"] = evidence
    gated = results
    if args.gate == "select-context":
        gated = [r for r in results if r["context"] == manifest["gate_context"]]
        if len(gated) != manifest["gate_cases"]:
            raise SystemExit("select context gate denominator changed")
    passed = all(r["status"] == "PASS" for r in gated)
    if args.gate == "full-corpus" and report["not_run"]:
        passed = False
    report["profile"] = args.profile
    report["gate"] = {"name": args.gate, "cases": len(gated), "passed": passed,
                      "scope": "Gate never removes other selected case results or mandatory NOT_RUN cases"}
    output = json.dumps(report, indent=2) + "\n"
    print(output, end="")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(output)
    return int(not report["gate"]["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
