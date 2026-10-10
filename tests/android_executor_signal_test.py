"""Device regression for the AArch64 Linux-signal to W calling convention.

Pass a dynamically linked Android wexec binary. ANDROID_SERIAL selects the
adb device. Supports ARM64 execution through Android's native bridge too.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: android_executor_signal_test.py <android-wexec>")
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="wexec-signal-") as temp:
        local = Path(temp)
        remote = "/data/local/tmp/" + local.name
        manifest = {"dirs": ["bin"], "targets": [{"name": "hang", "steps": [{
            "cmd": ["/system/bin/sh", "-c",
                    "sleep 600 & child=$!; echo $child > child.pid; wait"],
            "timeout_ms": 0}]}]}
        (local / "manifest.json").write_text(json.dumps(manifest))

        def adb(*args, check=True):
            return subprocess.run(["adb", *args], check=check, text=True,
                                  capture_output=True, timeout=20)

        def shell(command, check=True):
            return adb("shell", command, check=check)

        runner = None
        parent = None
        try:
            shell(f"mkdir -p {remote}/bin")
            adb("push", str(binary), remote + "/wexec")
            adb("push", str(local / "manifest.json"), remote + "/manifest.json")
            shell(f"chmod 755 {remote}/wexec")
            # The second full path is argv[0] for Android's translation
            # runner. A real ARM64 device needs no translation wrapper.
            machine = shell("uname -m").stdout.strip()
            program = "./wexec"
            if machine not in ("aarch64", "arm64"):
                program = ("/system/bin/ndk_translation_program_runner_binfmt_misc_arm64 "
                           f"{remote}/wexec {remote}/wexec")
            command = (f"cd {remote}; {program} -j 1 -f manifest.json hang "
                       ">run.out 2>&1; result=$?; echo $result >status.out")
            runner = subprocess.Popen(["adb", "shell", command],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                ready = shell(f"cd {remote}; cat bin/.wexec_lock; echo; cat child.pid", check=False)
                values = ready.stdout.split()
                if values and values[0].isdecimal():
                    parent = int(values[0])
                if len(values) == 2 and all(v.isdecimal() for v in values):
                    parent, child = map(int, values)
                    break
                if runner.poll() is not None:
                    raise AssertionError("executor exited before starting the child")
                time.sleep(0.1)
            else:
                raise AssertionError("executor did not start the hanging child")
            shell(f"kill -TERM {parent}")
            runner.communicate(timeout=15)
            status = shell(f"cat {remote}/status.out").stdout.strip()
            assert status == "143", f"SIGTERM exit status {status}, expected 143"
            assert shell(f"test ! -e {remote}/bin/.wexec_lock", check=False).returncode == 0, "lock remained"
            deadline = time.monotonic() + 3
            while True:
                stat = shell(f"cat /proc/{child}/stat", check=False)
                if stat.returncode != 0 or stat.stdout.rsplit(") ", 1)[1].split()[0] == "Z":
                    break
                assert time.monotonic() < deadline, "step child survived"
                time.sleep(0.05)
            print("Android executor SIGTERM: exit 143, child killed, lock released")
        except Exception:
            print(shell(f"cat {remote}/run.out", check=False).stdout, file=sys.stderr)
            raise
        finally:
            if runner is not None and runner.poll() is None:
                if parent is not None:
                    shell(f"kill -TERM {parent}", check=False)
                try:
                    runner.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    runner.kill()
                    runner.communicate()
            shell(f"rm -rf {remote}", check=False)


if __name__ == "__main__":
    main()
