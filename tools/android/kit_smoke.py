#!/usr/bin/env python3
"""Exercise graphics/android/kit_demo.w on an explicitly selected device.

Build first, for example:
  python3 tools/android/build.py graphics/android/kit_demo.w --package org.wlang.kitdemo \\
      --label "W kit" --theme daynight --min-sdk 29 --internet --scheme wkit --out bin/android/kit
The script serves one HTTP response on the host, forwards it with `adb reverse`,
launches the demo with a smoke URI, presses Back twice (screen pop, dialog
dismissal) and finally delivers a deep link to the running Activity.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import threading
import time


class Reply(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"kit-http-ok" if self.headers.get("X-Kit") == "1" else b"missing header"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--serial", required=True, help="adb device serial (adb devices)")
    parser.add_argument("--package", default="org.wlang.kitdemo")
    parser.add_argument("--apk", default="bin/android/kit/WApp.apk")
    parser.add_argument("--screenshot", default="bin/android/kit/preview.png")
    args = parser.parse_args()
    adb = ["adb", "-s", args.serial]

    def run(*command, **kwargs):
        return subprocess.run(adb + list(command), check=True, **kwargs)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Reply)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    activity = f"{args.package}/org.wlang.androiddemo.WActivity"
    try:
        run("install", "--no-incremental", "-r", args.apk)
        run("reverse", f"tcp:{port}", f"tcp:{port}")
        run("shell", "am", "force-stop", args.package)
        since = run("shell", "date '+%m-%d %H:%M:%S.000'", stdout=subprocess.PIPE, text=True).stdout.strip()
        run("shell", "am", "start", "-W", "-n", activity, "-d", f"wkit:smoke?http://127.0.0.1:{port}/kit")
        steps = {"kit smoke: press back": ("shell", "input", "keyevent", "4"),
                 "kit smoke: dismiss dialog": ("shell", "input", "keyevent", "4"),
                 "kit smoke: send deep link": ("shell", "am", "start", "-a", "android.intent.action.VIEW",
                                               "-d", "wkit:ping", args.package)}
        done = set()
        deadline = time.monotonic() + 60
        logs = ""
        while time.monotonic() < deadline:
            logs = run("logcat", "-d", "-T", since, "-s", "WAndroid:I", "AndroidRuntime:E", "*:S",
                       stdout=subprocess.PIPE, text=True).stdout
            if "kit smoke: FAILED" in logs or "FATAL EXCEPTION" in logs:
                break
            if "kit smoke: ok" in logs:
                screenshot = Path(args.screenshot)
                screenshot.parent.mkdir(parents=True, exist_ok=True)
                with screenshot.open("wb") as output:
                    run("exec-out", "screencap", "-p", stdout=output)
                print(f"Android kit screens, lists, text, secrets, timer, HTTP, back, dialog, deep link: OK ({args.serial})")
                print(screenshot)
                return
            for marker, command in steps.items():
                if marker in logs and marker not in done:
                    done.add(marker)
                    time.sleep(0.5)
                    run(*command, stdout=subprocess.DEVNULL)
            time.sleep(0.5)
        sys.exit("Android kit smoke failed or timed out:\n" + logs[-8000:])
    finally:
        subprocess.run(adb + ["reverse", "--remove", f"tcp:{port}"], stderr=subprocess.DEVNULL)
        server.shutdown()


if __name__ == "__main__":
    main()
