#!/usr/bin/env python3
"""Reproducible native ARM64 ordering/durability qualification (issues 607/608)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
MODES = {
    "streaming": ["--streaming"],
    "retained": ["--ast-required", "--ast-retain"],
    "optimized": ["--ast-required", "--ast-retain", "--ast-opt"],
}
FIXTURES = ["atomic_native", "durability_native"]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(command, cwd, timeout):
    # A timed-out coordinator may leave forked workers spinning. Kill its
    # entire process group both on timeout and on any assertion failure.
    child = subprocess.Popen(command, cwd=cwd, start_new_session=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True)
    try:
        output, _ = child.communicate(timeout=timeout)
    except BaseException:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        raise
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if child.returncode:
        raise RuntimeError(f"exit {child.returncode}: {command}\n{output}")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["all", "atomic", "durability"], default="all")
    parser.add_argument("--compiler", help="defaults to bin/wv2_darwin on macOS, bin/wv2 elsewhere")
    parser.add_argument("--cross", nargs="+", choices=["arm64", "arm64_darwin"])
    parser.add_argument("--host-smoke", action="store_true",
                        help="x64 Linux supplementary harness validation, not ARM64 qualification")
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--scratch", type=Path,
                        help="existing directory on filesystem/device being qualified")
    args = parser.parse_args()
    if args.rounds <= 0 or args.timeout <= 0:
        parser.error("rounds and timeout must be positive")
    if args.cross and args.host_smoke:
        parser.error("--cross and --host-smoke are mutually exclusive")
    machine, system = platform.machine().lower(), platform.system()
    if args.cross:
        archs = args.cross
        evidence = "cross-compilation only"
    elif args.host_smoke:
        if machine not in ("x86_64", "amd64") or system != "Linux":
            parser.error("host smoke requires x64 Linux")
        archs = ["x64"]
        evidence = "x64 supplementary runtime harness validation"
    else:
        if machine not in ("aarch64", "arm64") or system not in ("Linux", "Darwin"):
            parser.error("native qualification requires ARM64 Linux or Apple Silicon; use --cross for builds")
        if (os.cpu_count() or 0) < 2:
            parser.error("native concurrent qualification requires at least two logical CPUs")
        archs = ["arm64_darwin" if system == "Darwin" else "arm64"]
        evidence = ("native concurrent ordering stress" if args.suite == "atomic" else
                    "native runtime stress (process-crash, not power-loss evidence)")
    fixtures = FIXTURES if args.suite == "all" else [args.suite + "_native"]
    compiler = Path(args.compiler or ROOT / "bin" / (
        "wv2_darwin" if system == "Darwin" else "wv2")).resolve()
    report = {
        "evidence": evidence, "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "uname": list(platform.uname()), "cpu_count": os.cpu_count(),
        "compiler": str(compiler), "compiler_sha256": digest(compiler),
        "driver_sha256": digest(__file__),
        "suite": args.suite, "rounds": args.rounds, "iterations_per_litmus": 100000,
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "worktree_diff_sha256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT)).hexdigest(),
        "runs": [], "passed": False,
    }
    source_hash = hashlib.sha256()
    sources = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT).split(b"\0")
    for name in sorted(sources):
        if name.endswith(b".w") and (ROOT / os.fsdecode(name)).is_file():
            source_hash.update(name + b"\0")
            source_hash.update(bytes.fromhex(digest(ROOT / os.fsdecode(name))))
    report["w_source_tree_sha256"] = source_hash.hexdigest()
    if system == "Linux":
        cpuinfo = Path("/proc/cpuinfo")
        if cpuinfo.exists():
            report["cpuinfo"] = cpuinfo.read_text()
    elif system == "Darwin":
        report["hardware"] = subprocess.check_output([
            "sysctl", "hw.model", "machdep.cpu.brand_string", "hw.physicalcpu",
            "hw.logicalcpu", "hw.cachelinesize", "kern.hv_vmm_present"], text=True)
        report["os_version"] = subprocess.check_output(["sw_vers"], text=True)
    output = args.output or ROOT / "bin" / f"qualification_{archs[0]}_{args.suite}.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    build_dir = ROOT / "bin" / "native_qualification"
    build_dir.mkdir(parents=True, exist_ok=True)
    try:
        for arch in archs:
            for mode, flags in MODES.items():
                for fixture in fixtures:
                    source = ROOT / "tests" / f"{fixture}_fixture.w"
                    binary = build_dir / f"{fixture}_{arch}_{mode}"
                    print("compile", arch, mode, fixture, flush=True)
                    # macOS caches code signatures per vnode. Rebuilding an
                    # executed Mach-O in place can get a valid image killed;
                    # publish a fresh inode on every qualification invocation.
                    with tempfile.TemporaryDirectory(prefix="build-", dir=build_dir) as staging:
                        staged_binary = Path(staging) / binary.name
                        command = [str(compiler), arch, *flags, str(source), "-o", str(staged_binary)]
                        run(command, ROOT, args.timeout)
                        staged_binary.replace(binary)
                    record = {"arch": arch, "mode": mode, "fixture": fixture,
                              "command": command, "source_sha256": digest(source),
                              "binary": str(binary),
                              "binary_sha256": digest(binary), "completed_rounds": 0}
                    report["runs"].append(record)
                    if args.cross:
                        continue
                    for trial in range(args.rounds):
                        with tempfile.TemporaryDirectory(prefix="w-native-", dir=args.scratch) as scratch:
                            if "filesystem" not in report:
                                report["scratch_parent"] = str(Path(scratch).parent)
                                report["filesystem"] = subprocess.check_output(["df", "-k", scratch], text=True)
                            run([str(binary)], scratch, args.timeout)
                        record["completed_rounds"] = trial + 1
                    print("pass", arch, mode, fixture, args.rounds, "rounds", flush=True)
        report["passed"] = True
    except BaseException as exc:
        report["failure"] = str(exc)
        raise
    finally:
        output.write_text(json.dumps(report, indent=2) + "\n")
        print(f"evidence: {output}", flush=True)


if __name__ == "__main__":
    main()
