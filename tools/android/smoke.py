#!/usr/bin/env python3
"""Install and exercise the native W demo on an explicitly selected Android device."""
import argparse
from pathlib import Path
import subprocess
import sys
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="adb device serial (adb devices)")
    parser.add_argument("--apk", default="bin/android/app/WApp.apk")
    parser.add_argument("--screenshot", default="bin/android/app/preview.png")
    parser.add_argument("--probes", action="store_true", help="also run packaged compiler/ABI probes")
    args = parser.parse_args()
    adb = ["adb", "-s", args.serial]
    def run(*command, **kwargs):
        return subprocess.run(adb + list(command), check=True, **kwargs)
    token = uuid.uuid4().hex
    run("install", "--no-incremental", "-r", args.apk)
    run("shell", "am", "force-stop", "org.wlang.androiddemo")
    run("shell", "am", "start", "-W", "-n", "org.wlang.androiddemo/.WActivity",
        "--ez", "w_smoke", "true", "--es", "w_smoke_token", token,
        "--ez", "w_probes", "true" if args.probes else "false")
    deadline = time.monotonic() + 45
    logs = ""
    while time.monotonic() < deadline:
        logs = run("logcat", "-d", "-s", "WAndroid:I", "AndroidRuntime:E", "*:S",
                   stdout=subprocess.PIPE, text=True).stdout
        if (f"android demo native: ok {token}" in logs
                and (not args.probes or f"android compiler and ABI: ok {token}" in logs)):
            screenshot = Path(args.screenshot)
            screenshot.parent.mkdir(parents=True, exist_ok=True)
            with screenshot.open("wb") as output:
                run("exec-out", "screencap", "-p", stdout=output)
            print(f"Android native callbacks, state, Unicode, lifecycle: OK ({args.serial})")
            if args.probes:
                print("Android embedded compiler, generated code, ARM64 ABI: OK")
            print(screenshot)
            return
        time.sleep(1)
    crashes = run("logcat", "-d", "-b", "crash", stdout=subprocess.PIPE, text=True).stdout
    run("shell", "am", "force-stop", "org.wlang.androiddemo")
    diagnostic = subprocess.run(adb + ["shell", "run-as", "org.wlang.androiddemo", "cat",
                                      "files/w-src/compiler.log"], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True).stdout
    sys.exit("Android native smoke failed or timed out:\n" + logs[-12000:] + crashes[-12000:] + diagnostic)


if __name__ == "__main__":
    main()
