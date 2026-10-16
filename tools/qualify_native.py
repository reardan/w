#!/usr/bin/env python3
"""Reproducible native ARM64 ordering/durability qualification (issues 607/608)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
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


class AdbAtomicRunner:
    """Execute Linux arm64 ELFs directly, without Android's native bridge."""

    def __init__(self, serial):
        self.adb = ["adb", "-s", serial]
        self.remote = None
        self.info = {}
        for name, command in {
            "uname": "uname -a", "machine": "uname -m",
            "model": "getprop ro.product.model", "soc": "getprop ro.soc.model",
            "android_version": "getprop ro.build.version.release",
            "build_fingerprint": "getprop ro.build.fingerprint",
            "qemu": "getprop ro.kernel.qemu", "boot_qemu": "getprop ro.boot.qemu",
            "native_bridge": "getprop ro.dalvik.vm.native.bridge",
            "cpuinfo": "cat /proc/cpuinfo", "online_cpus": "cat /sys/devices/system/cpu/online",
            "status": "cat /proc/self/status", "cgroup": "cat /proc/self/cgroup",
            "identity": "id", "page_size": "getconf PAGESIZE",
        }.items():
            self.info[name] = self.shell(command).strip()
        if self.info["machine"] not in ("aarch64", "arm64"):
            raise ValueError("ADB qualification requires a native ARM64 kernel; translation is not evidence")
        if any(self.info[key] not in ("", "0") for key in ("qemu", "boot_qemu", "native_bridge")):
            raise ValueError("ADB qualification rejects emulators and configured native bridges")
        allowed = next(line.split(":", 1)[1].strip()
                       for line in self.info["status"].splitlines()
                       if line.startswith("Cpus_allowed_list:"))
        def cpus(value):
            result = set()
            for item in value.split(","):
                ends = [int(part) for part in item.split("-")]
                result.update(range(ends[0], ends[-1] + 1))
            return result
        self.info["available_cpus"] = sorted(cpus(allowed) & cpus(self.info["online_cpus"]))
        if len(self.info["available_cpus"]) < 2:
            raise ValueError("native concurrent qualification requires at least two available CPUs")
        self.shell("command -v setsid && command -v timeout && command -v sha256sum")
        self.remote = self.shell("mktemp -d /data/local/tmp/w-atomic-qualification-XXXXXX").strip()

    def shell(self, command, timeout=30):
        return run([*self.adb, "shell", command], ROOT, timeout)

    def stage(self, binary):
        remote = self.remote + "/" + binary.name
        run([*self.adb, "push", str(binary), remote], ROOT, 30)
        self.shell(shlex.join(["chmod", "755", remote]))
        actual = self.shell(shlex.join(["sha256sum", remote])).split()[0]
        if actual != digest(binary):
            raise RuntimeError("device executable SHA256 differs from the compiled binary")
        return remote

    def execute(self, binary, timeout):
        # The session leader supervises timeout in foreground mode, then kills
        # its entire process group, including workers orphaned by an assertion.
        # Redirect locally on the device so surviving workers cannot hold adb's
        # stdout pipe open. A device watchdog still runs if adb disconnects.
        directory = self.shell(shlex.join(["mktemp", "-d", self.remote + "/trial-XXXXXX"])).strip()
        body = (f"cd {shlex.quote(directory)} || exit 1\n"
                "echo $$ > group.pid\n"
                f"timeout --foreground -s KILL {timeout} {shlex.quote(binary)} > output 2>&1\n"
                "echo $? > status\n"
                "kill -KILL -- -$$\n")
        command = (shlex.join(["setsid", "-w", "sh", "-c", body]) + " >/dev/null 2>&1; "
                   + shlex.join(["test", "-f", directory + "/status"]))
        start = time.monotonic()
        try:
            self.shell(command, timeout + 15)
            status = int(self.shell(shlex.join(["cat", directory + "/status"])).strip())
            output = self.shell(shlex.join(["cat", directory + "/output"]))
            if status:
                raise RuntimeError(f"device exit {status}: {binary}\n{output}")
            return {"exit_code": status, "elapsed_seconds": round(time.monotonic() - start, 3),
                    "stdout": output}
        finally:
            # Also cover host interruption/transport failure. If transport has
            # gone away, the device-side watchdog performs the same cleanup.
            try:
                self.shell(f"cd {shlex.quote(directory)} && "
                           "if test -f group.pid; then "
                           "kill -KILL -- -$(cat group.pid) 2>/dev/null || true; fi")
            finally:
                self.shell(shlex.join(["rm", "-rf", directory]))

    def close(self):
        if self.remote:
            self.shell(shlex.join(["rm", "-rf", self.remote]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["all", "atomic", "durability"], default="all")
    parser.add_argument("--compiler", help="defaults to bin/wv2_darwin on macOS, bin/wv2 elsewhere")
    parser.add_argument("--cross", nargs="+", choices=["arm64", "arm64_darwin"])
    parser.add_argument("--host-smoke", action="store_true",
                        help="x64 Linux supplementary harness validation, not ARM64 qualification")
    parser.add_argument("--adb", metavar="SERIAL",
                        help="cross-compile Linux arm64 and run atomic stress on a physical Android device")
    parser.add_argument("--pac", choices=["off", "ret", "full"],
                        help="explicit ARM64 pointer-authentication setting (off for CPUs without PAC)")
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--scratch", type=Path,
                        help="existing directory on filesystem/device being qualified")
    args = parser.parse_args()
    if args.rounds <= 0 or args.timeout <= 0:
        parser.error("rounds and timeout must be positive")
    if sum(bool(option) for option in (args.cross, args.host_smoke, args.adb)) > 1:
        parser.error("--cross, --host-smoke and --adb are mutually exclusive")
    if args.adb and (args.suite != "atomic" or args.scratch):
        parser.error("--adb requires --suite atomic and does not accept --scratch")
    machine, system = platform.machine().lower(), platform.system()
    if args.adb:
        archs = ["arm64"]
        evidence = "native concurrent ordering stress on Android Linux (host cross-compiled)"
    elif args.cross:
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
    if args.adb:
        build_dir = build_dir / "adb"
    build_dir.mkdir(parents=True, exist_ok=True)
    device = None
    try:
        if args.adb:
            device = AdbAtomicRunner(args.adb)
            report["build_host"] = {key: report.pop(key) for key in
                                    ("uname", "cpu_count", "cpuinfo", "hardware", "os_version")
                                    if key in report}
            report["execution_host"] = device.info
            report["execution_transport"] = "adb shell; direct static Linux arm64 ELF, no translation"
            report["remote_directory"] = device.remote
        for arch in archs:
            for mode, flags in MODES.items():
                if args.pac:
                    flags = [*flags, "--pac=" + args.pac]
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
                    if device:
                        remote_binary = device.stage(binary)
                        record["remote_binary"] = remote_binary
                        record["device_binary_sha256"] = record["binary_sha256"]
                        record["trials"] = []
                    for trial in range(args.rounds):
                        if device:
                            record["trials"].append(device.execute(remote_binary, args.timeout))
                        else:
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
        if device:
            device.close()


if __name__ == "__main__":
    main()
