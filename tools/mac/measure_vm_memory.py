#!/usr/bin/env python3
"""Measure native HV guest CoW versus a full-copy baseline; never sum shared pages."""
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import time
from pathlib import Path


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="signed wvm_darwin_memory_fixture")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("--samples must be positive")
    binary = args.binary.resolve()
    report = {
        "schema": "wvm-darwin-memory-v1",
        "host": {
            "os": command("sw_vers"),
            "machine": platform.machine(),
            "model": command("sysctl", "-n", "hw.model"),
            "chip": command("sysctl", "-n", "machdep.cpu.brand_string"),
            "ram_bytes": int(command("sysctl", "-n", "hw.memsize")),
            "sdk": command("xcrun", "--show-sdk-version"),
        },
        "source_revision": command("git", "rev-parse", "HEAD"),
        "worktree_status": command("git", "status", "--short"),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "conditions": {
            "sample_count_per_scenario": args.samples,
            "data_pages": 1024,
            "code_pages": 1,
            "processes": "fresh exec for each sample; template owner plus 1 or 2 workers",
            "backing": "fresh populated file, warm from capture; owner touches every page",
            "phase_barriers": "all workers stop before HV registration and after guest writes",
            "registration_measurement": "per-worker snapshot; peer may be registering concurrently",
            "cold_cache": "not measured; no filesystem cache eviction",
            "signature": "already signed before timing; signing excluded",
        },
        "accounting_limits": [
            "Summed process RSS and footprint are reported as process counters, not unique physical memory.",
            "Backing logical and allocated bytes are reported separately and must not be added to RSS as RAM.",
            "VM_REGION_TOP_INFO shared counts include HV references and shadow objects; never sum them.",
            "VM_REGION_EXTENDED_INFO is best-effort; exact unique shared/private and pinned bytes are unattributed.",
            "Full-copy mode retains the same template owner and copies each worker RAM before registration.",
            "Mach region sizes for CoW include the metadata/header mapping; full-copy regions contain RAM only.",
        ],
        "runs": [],
        "summary": [],
    }
    for sample in range(args.samples):
        modes = ("cow", "copy") if sample % 2 == 0 else ("copy", "cow")
        for clones in (1, 2):
            for dirty in (0, 256, 1024):
                for mode in modes:
                    start = time.monotonic_ns()
                    result = subprocess.run(
                        [str(binary), mode, str(dirty), str(clones)],
                        check=True, capture_output=True, text=True, timeout=20,
                    )
                    records = [json.loads(line) for line in result.stdout.splitlines()]
                    owner = [r for r in records if r["phase"] == "template-owner"]
                    workers = [r for r in records if r["phase"] == "after-guest-writes"]
                    backing = [r for r in records if r["phase"] == "backing-file"]
                    if len(owner) != 2 or len(workers) != clones or len(backing) != 1:
                        raise RuntimeError("Incomplete mandatory memory sample")
                    report["runs"].append({
                        "sample": sample, "mode": mode, "clones": clones,
                        "dirty_pages": dirty, "dirty_fraction": dirty / 1024,
                        "elapsed_ms": (time.monotonic_ns() - start) / 1e6,
                        "summed_process_rss_bytes": owner[-1]["resident_bytes"] + sum(r["resident_bytes"] for r in workers),
                        "summed_process_footprint_bytes": owner[-1]["footprint_bytes"] + sum(r["footprint_bytes"] for r in workers),
                        "backing_allocated_bytes": backing[0]["allocated_bytes"],
                        "records": records,
                    })
    for clones in (1, 2):
        for dirty in (0, 256, 1024):
            for mode in ("cow", "copy"):
                runs = [r for r in report["runs"] if (r["clones"], r["dirty_pages"], r["mode"]) == (clones, dirty, mode)]
                report["summary"].append({
                    "mode": mode, "clones": clones, "dirty_fraction": dirty / 1024,
                    "samples": len(runs),
                    "median_summed_process_rss_bytes": statistics.median(r["summed_process_rss_bytes"] for r in runs),
                    "median_summed_process_footprint_bytes": statistics.median(r["summed_process_footprint_bytes"] for r in runs),
                    "backing_allocated_bytes": runs[0]["backing_allocated_bytes"],
                })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))
    print(f"Memory evidence: {args.output}")


if __name__ == "__main__":
    main()
