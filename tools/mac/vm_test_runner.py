#!/usr/bin/env python3
"""Build and execute the mandatory, signed, native Darwin VM acceptance gate."""
import hashlib
import json
import math
import statistics
import os
from pathlib import Path
import platform
import shlex
import signal
import shutil
import subprocess
import sys
import time
import urllib.request
from vm_source_identity import source_identity

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
OUT = ROOT / "bin" / "darwin-vm-gate" / time.strftime("%Y%m%d-%H%M%S")
OUT.mkdir(parents=True, exist_ok=False)
REPORT = {"status": "running", "steps": [], "output": str(OUT)}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(label, command, expected=0, timeout=180, native=False, **kwargs):
    command = [str(v) for v in command]
    print(f"[{label}] {shlex.join(command)}", flush=True)
    started = time.monotonic()
    result = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              start_new_session=True, **kwargs)
    try:
        data, _ = result.communicate(timeout=timeout)
    except BaseException:
        # A failed native fixture may own workers. Terminate its whole group,
        # then reap the direct child before reporting the failure.
        try:
            os.killpg(result.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        data, _ = result.communicate()
        (OUT / (label + ".log")).write_bytes(data)
        raise
    output = data.decode("utf-8", errors="replace")
    (OUT / (label + ".log")).write_text(output)
    elapsed = time.monotonic() - started
    REPORT["steps"].append({"name": label, "command": command,
                            "seconds": elapsed, "status": result.returncode})
    if output:
        print(output, end="" if output.endswith("\n") else "\n", flush=True)
    if result.returncode != expected:
        raise RuntimeError(f"{label}: expected status {expected}, got {result.returncode}")
    if native and any(line.lstrip().startswith("SKIP") for line in output.splitlines()):
        raise RuntimeError(f"{label}: native execution skipped")
    return output


def sign(path):
    # Compile to a fresh inode, sign before first execution, verify entitlement.
    run(path.name + "-sign", ["codesign", "--force", "--sign", "-", "--entitlements",
                               "tools/mac/hypervisor.entitlements", path])
    run(path.name + "-signature", ["codesign", "--verify", "--strict", path])
    entitlements = run(path.name + "-entitlements", ["codesign", "-d", "--entitlements", ":-", path])
    if "com.apple.security.hypervisor" not in entitlements or "<true/>" not in entitlements:
        raise RuntimeError(f"{path}: hypervisor entitlement missing")


def compile_program(compiler, source, output, arch="arm64_darwin", strict=True):
    flags = ["--strict"] if strict else []
    run(output.name + "-check", [compiler, "check", "--json", arch, source])
    run(output.name + "-build", [compiler, arch, *flags, source, "-o", output])


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("mandatory native gate requires Apple Silicon macOS; skips are failures")
    for program in ("codesign", "xcrun", "sysctl"):
        if not shutil.which(program):
            raise RuntimeError(f"missing native prerequisite: {program}")
    REPORT["revision"] = run("revision", ["git", "rev-parse", "HEAD"]).strip()
    REPORT["worktree"] = run("worktree", ["git", "status", "--short"])
    REPORT["source_identity"] = source_identity()
    REPORT["platform"] = run("platform", ["sw_vers"])
    REPORT["hardware"] = run("hardware", ["sysctl", "hw.model", "machdep.cpu.brand_string", "hw.memsize", "hw.pagesize", "kern.hv_support"])
    REPORT["sdk"] = run("sdk", ["xcrun", "--show-sdk-version"]).strip()
    compiler = os.environ.get("W_DARWIN_COMPILER")
    if compiler:
        compiler = Path(compiler).resolve()
        if not compiler.is_file():
            raise RuntimeError(f"W_DARWIN_COMPILER does not exist: {compiler}")
        REPORT["bootstrap"] = {"override": str(compiler), "sha256": digest(compiler)}
    else:
        seed = next(line.split() for line in (ROOT / "SEEDS").read_text().splitlines()
                    if line.startswith("w_darwin "))
        _, tag, asset, expected_hash = seed
        compiler = OUT / asset
        url = f"https://github.com/reardan/w/releases/download/{tag}/{asset}"
        print(f"[seed] download {url}", flush=True)
        urllib.request.urlretrieve(url, compiler)
        if digest(compiler) != expected_hash:
            raise RuntimeError("downloaded Darwin seed does not match SEEDS")
        compiler.chmod(0o755)
        REPORT["bootstrap"] = {"tag": tag, "asset": asset, "sha256": expected_hash}
    # No existing repository seed is overwritten. Every stage is a new inode.
    for stage in (2, 3, 4):
        target = OUT / f"wv{stage}_darwin"
        run(f"bootstrap-{stage}", [compiler, "arm64_darwin", "--strict", "w.w", "-o", target])
        compiler = target
    if digest(OUT / "wv3_darwin") != digest(OUT / "wv4_darwin"):
        raise RuntimeError("native compiler fixpoint failed: wv3 != wv4")
    REPORT["compiler_fixpoint_sha256"] = digest(compiler)
    for name, source in (
        ("lib", "lib/lib_test.w"), ("hash_table", "structures/hash_table_test.w"),
        ("map_set_builtin", "tests/map_set_builtin_test.w"),
        ("generator", "tests/generator_test.w"),
        ("compound_assign", "tests/compound_assign_test.w"),
        ("limb_builtin", "tests/limb_builtin_test.w"),
        ("dynamic", "tests/dynamic_darwin_test.w"),
    ):
        target = OUT / (name + "_darwin")
        # Existing smoke fixtures contain intentional legacy type warnings;
        # the compiler fixpoint and all newly added VM code remain strict.
        compile_program(compiler, source, target, strict=False)
        run(name + "-native", [target], native=True)
    # Guest files are Linux AArch64 ELF, never Mach-O host programs.
    guest = OUT / "wvm_darwin_fixture"
    compile_program(compiler, "tests/wvm_darwin_fixture.w", guest, "arm64")
    # Some maintained fixture roots use this conventional output path.
    shutil.copyfile(guest, ROOT / "bin/wvm_darwin_fixture")
    for source in ("tests/hv_darwin_test.w", "tests/wvm_darwin_cell_test.w",
                   "tests/wvm_darwin_snapshot_fixture.w",
                   "tests/wvm_darwin_cell_snapshot_fixture.w", "tests/wvm_darwin_pool_fixture.w"):
        target = OUT / Path(source).stem
        compile_program(compiler, source, target)
        if source.endswith("hv_darwin_test.w"):
            output = run("missing-entitlement", [target], expected=77, native=True)
            if "missing-entitlement" not in output:
                raise RuntimeError("unentitled worker did not identify the missing entitlement")
            # A denied execution has already touched this vnode: sign a copy.
            fresh = target.with_name(target.name + "-signed")
            shutil.copyfile(target, fresh)
            fresh.chmod(0o755)
            target = fresh
        sign(target)
        arguments = [target]
        if source.endswith(("wvm_darwin_cell_test.w", "wvm_darwin_cell_snapshot_fixture.w", "wvm_darwin_pool_fixture.w")):
            arguments.append(guest)
        output = run(Path(source).stem + "-native", arguments, timeout=120, native=True)
        if source.endswith("wvm_darwin_pool_fixture.w"):
            pool_records = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
            pool_summary = {}
            for phase, expected_count in (("pool-create-two", 1), ("ready-acquire", 21),
                                          ("first-command", 21), ("ready-replacement", 21)):
                samples = sorted(row["elapsed_ns"] for row in pool_records if row["phase"] == phase)
                if len(samples) != expected_count:
                    raise RuntimeError(f"pool measurement {phase} has {len(samples)} samples, expected {expected_count}")
                pool_summary[phase] = {"samples": len(samples), "p50_ns": statistics.median(samples),
                                       **{f"p{p}_ns": samples[math.ceil(len(samples) * p / 100) - 1]
                                          for p in (95, 99)}}
            (OUT / "pool.json").write_text(json.dumps({
                "schema": "wvm-darwin-ready-pool-v1", "units": "nanoseconds", "capacity": 2,
                "source_identity": REPORT["source_identity"],
                "guest_ram_bytes": 268435456, "image_bytes": guest.stat().st_size,
                "conditions": "single owner thread; fresh private ready RAM cells; warm template backing; no VM/vCPU retained between leases",
                "semantics": {"ready-acquire": "transfer an already prepared cell; excludes guest run and VM creation",
                              "ready-replacement": "restore one private ready RAM cell from retained template backing",
                              "first-command": "allocator/containers/FP guest on acquired cell; includes VM/vCPU creation, execution and destruction",
                              "pool-create-two": "prepare two ready private RAM cells; excludes template capture"},
                "runs": pool_records, "summary": pool_summary,
            }, indent=2) + "\n")
    for name in ("wvm", "wvmd"):
        target = OUT / (name + "_darwin")
        compile_program(compiler, f"tools/{name}.w", target)
        sign(target)
    run("cli-capabilities", [OUT / "wvm_darwin", "capabilities"], native=True)
    run("cli-available", [OUT / "wvm_darwin", "available"], native=True)
    # This helper covers the actual CLI/daemon/client contract.
    run("lifecycle-e2e", [sys.executable, "tests/wvm_darwin_e2e.py", str(OUT)],
        timeout=180, native=True)
    run("recovery-security", [sys.executable, "tests/wvm_darwin_recovery.py",
                              "--worker", OUT / "wvm_darwin", "--daemon", OUT / "wvmd_darwin",
                              "--guest", guest, "--compiler", compiler], timeout=180, native=True)
    run("lifecycle-performance", [sys.executable, "tools/mac/measure_vm_lifecycle.py",
                                  "--worker", OUT / "wvm_darwin", "--daemon", OUT / "wvmd_darwin",
                                  "--guest", guest, "--samples", "5", "--output", OUT / "lifecycle.json"],
        timeout=180, native=True)
    memory_fixture = OUT / "wvm_darwin_memory_fixture"
    compile_program(compiler, "tests/wvm_darwin_memory_fixture.w", memory_fixture)
    sign(memory_fixture)
    run("memory-accounting", [sys.executable, "tools/mac/measure_vm_memory.py", memory_fixture,
                              "--samples", "5", "--output", OUT / "memory.json"],
        timeout=180, native=True)
    memory_report = json.loads((OUT / "memory.json").read_text())
    memory_report["source_identity"] = REPORT["source_identity"]
    (OUT / "memory.json").write_text(json.dumps(memory_report, indent=2) + "\n")
    REPORT["source_identity_after_gate"] = source_identity()
    REPORT["status"] = "passed"
    print(f"Native Darwin VM gate passed. Evidence: {OUT}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        REPORT["status"] = "failed"
        REPORT["error"] = str(error)
        print(f"FAIL: {error}\nEvidence: {OUT}", file=sys.stderr, flush=True)
        sys.exit(1)
    finally:
        (OUT / "report.json").write_text(json.dumps(REPORT, indent=2) + "\n")
