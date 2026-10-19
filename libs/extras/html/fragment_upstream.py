#!/usr/bin/env python3
"""Compare unchanged pinned html5lib trees, keeping all cases in the report."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
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
    run = subprocess.run([str(Path(sys.argv[1]).resolve()), context, data],
                         capture_output=True, text=True, timeout=10)
    status = "PASS"
    reason = ""
    if context == "html" and run.returncode == 3:
        status = "UNSUPPORTED"
        reason = "HTML context reset-insertion-mode/document containers pending"
    elif run.returncode or run.stdout != expected:
        status = "FAIL"
        reason = f"exit={run.returncode}, expected={expected!r}, actual={run.stdout!r}, stderr={run.stderr!r}"
    results.append({"id": f"tests4.dat:{index}", "context": context,
                    "status": status, "reason": reason})
if len(results) != manifest["total_cases"]:
    raise SystemExit("upstream case count mismatch")
report = {"upstream": manifest["revision"], "total": len(results),
          "executed": sum(r["status"] != "UNSUPPORTED" for r in results),
          "counts": {s: sum(r["status"] == s for r in results)
                     for s in ("PASS", "FAIL", "UNSUPPORTED")},
          "scope": "Tree outputs only; upstream parse-error lists remain unverified",
          "results": results}
print(json.dumps(report, indent=2))
Path("bin/html-fragment-upstream.json").write_text(json.dumps(report, indent=2) + "\n")
if report["counts"]["FAIL"]:
    raise SystemExit(1)
