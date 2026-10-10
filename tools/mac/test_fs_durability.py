#!/usr/bin/env python3
"""Native APFS process-crash/fault qualification for #608 (not power-cut testing).

A private --import-root intercepts only F_FULLFSYNC and rename in a copy
of the current Darwin syscall adapter. All other calls use the real kernel;
lib/fs.w and its publication algorithm are compiled unchanged. No production
fault-injection state, global hooks, or test-only branches are shipped.
"""
import argparse
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="bin/wv2_darwin")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("requires a native Apple Silicon Mac")
    compiler = str((ROOT / args.compiler).resolve())
    with tempfile.TemporaryDirectory(prefix="fs_durability_", dir=ROOT / "bin") as scratch:
        work = Path(scratch)
        overlay = work / "imports"
        relative = Path("lib/darwin/syscalls.w")
        source = (ROOT / relative).read_text()
        for original, replacement in [
            ("sys_fcntl(file, 51, 0)", "fs_fault_fullsync(file)"),
            ("syscall(128, oldpath, newpath, 0)", "fs_fault_rename(oldpath, newpath)"),
        ]:
            if source.count(original) != 1:
                raise RuntimeError(f"update interception for changed syscall adapter: {original}")
            source = source.replace(original, replacement)
        patched = overlay / relative
        patched.parent.mkdir(parents=True)
        patched.write_text("import tests.fs_darwin_fault_hooks\n" + source)
        fixture = "tests/fs_darwin_fault_fixture.w"
        options = ["arm64_darwin", "--import-root", str(overlay)]
        subprocess.run([compiler, "check", "--json", *options, fixture], cwd=ROOT, check=True)
        binary = work / "fixture"
        subprocess.run([compiler, *options, "--strict", fixture, "-o", str(binary)], cwd=ROOT, check=True)
        executable = work / "fixture.run"
        shutil.copy2(binary, executable)  # fresh inode for Darwin's signature cache
        target = work / "state"

        def run(stage, crash=0, error=5):
            return subprocess.run(
                [str(executable), str(target), str(stage), str(crash), str(error)],
                cwd=ROOT, timeout=15, check=False,
            ).returncode

        cases = 0
        for stage in (1, 3, 5):
            # EIO at every publication stage; interruption/unsupported at
            # both full barriers must propagate, never fall back or retry.
            errors = (5,) if stage == 3 else (5, 4, 22, 45, 102)
            for error in errors:
                target.write_bytes(b"old contents")
                assert run(stage, error=error) == 0, (stage, error)
                expected = b"new contents" if stage == 5 else b"old contents"
                assert target.read_bytes() == expected, (stage, error)
                assert not list(work.glob("state.tmp.*")), "failed replace leaked its temp file"
                # Reopen and republish after a reported ambiguous rename.
                assert run(0) == 0
                assert target.read_bytes() == b"new contents"
                cases += 1
        for stage in range(1, 7):
            target.write_bytes(b"old contents")
            assert run(stage, crash=1) == -signal.SIGKILL, stage
            expected = b"old contents" if stage <= 3 else b"new contents"
            assert target.read_bytes() == expected, stage
            leftovers = list(work.glob("state.tmp.*"))
            assert len(leftovers) == (1 if stage <= 3 else 0), (stage, leftovers)
            assert run(0) == 0, "recovery publication failed"
            assert target.read_bytes() == b"new contents"
            for leftover in leftovers:
                assert leftover.read_bytes() == b"new contents"
                leftover.unlink()
            cases += 1
        print(f"Darwin durability: {cases} fault/crash cases and recovery passed")


if __name__ == "__main__":
    main()
