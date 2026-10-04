"""Independent-process recovery and optional Linux syscall fault qualification.
SIGKILL is a process crash, NOT a power-loss simulation. fake_fs covers the
separate modeled loss of dirty data and unsynced namespace updates.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

binary = str(pathlib.Path(sys.argv[1]).resolve())

def run(mode, prefix, trace=None):
    cmd = [binary, mode, str(prefix)]
    if trace:
        cmd = ["strace", "-qq", "-o", str(prefix) + ".trace", "-e", trace, *cmd]
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)

cases = [("advance", None), ("compact", None)]
if shutil.which("strace"):
    for syscall in ("write", "fsync", "rename"):
        modes = ("advance",) if syscall == "write" else ("compact",)
        for mode in modes:
            for nth in range(1, 5):
                for fault in ("error=EIO", "signal=SIGKILL"):
                    cases.append((mode, f"inject={syscall}:{fault}:when={nth}"))
    cases.extend(("advance", f"inject=write:{fault}:when=1") for fault in
                 ("error=EINTR", "error=ENOSPC", "retval=0"))
else:
    print("storage_native_test: strace unavailable; syscall injection skipped")

with tempfile.TemporaryDirectory(prefix="w-storage-native-") as directory:
    for i, (mode, trace) in enumerate(cases):
        prefix = pathlib.Path(directory) / str(i)
        initial = run("init", prefix)
        assert initial.returncode == 0, initial.stderr.decode()
        result = run(mode, prefix, trace)
        # A specified nth syscall may not occur. Successful commands and
        # failed/killed commands must all leave a recoverable atomic state.
        assert result.returncode in (0, 3, 4, 8, -9), (mode, trace, result.returncode, result.stderr)
        if trace:
            log = pathlib.Path(str(prefix) + ".trace").read_text()
            assert "ptrace" not in result.stderr.decode().lower(), result.stderr
            if "when=1" in trace:
                assert "INJECTED" in log or "SIGKILL" in log, (trace, log)
                if "error=EINTR" not in trace:
                    assert result.returncode != 0, ("failure released success", mode, trace)
        recovered = run("verify", prefix)
        assert recovered.returncode == 0, (mode, trace, recovered.returncode, recovered.stderr)
print(f"storage_native_test: {len(cases)} independent-process scenarios passed")
