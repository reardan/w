#!/bin/sh
# Build/install the native demo on an available Apple Silicon iPhone simulator.
# Pass a simulator UDID to choose explicitly; otherwise select the first iPhone.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
device=${1:-}
if [ -z "$device" ]; then
    device=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if "iPhone" in device["name"] and device.get("isAvailable"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("No available iPhone simulator; install an iOS runtime in Xcode.")')
fi
# Boot only when needed; do not hide unrelated boot failures.
state=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
udid=sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["udid"] == udid:
            print(device["state"])
            raise SystemExit(0)
raise SystemExit("Simulator is not available: " + udid)' "$device")
if [ "$state" != Booted ]; then xcrun simctl boot "$device"; fi
xcrun simctl bootstatus "$device" -b
tools/ios/build.sh simulator
app="$root/bin/ios/simulator/WApp.app"
identifier=${W_IOS_BUNDLE_ID:-org.wlang.native-demo}
xcrun simctl install "$device" "$app"
# A broken callback must fail, not hang unattended verification forever.
python3 - "$device" "$identifier" <<'PY'
import subprocess, sys
result = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process",
                         "--console", sys.argv[1], sys.argv[2], "--smoke-test"],
                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
print(result.stdout, end="")
if result.returncode or "ios demo tap: 1" not in result.stdout or "ios demo UIKit: ok" not in result.stdout:
    raise SystemExit("Native iOS callback smoke test failed")
PY
# Leave an ordinary interactive launch on screen and capture it for review.
xcrun simctl launch "$device" "$identifier"
xcrun simctl io "$device" screenshot "$root/bin/ios/simulator/preview.png"
printf 'Native iOS smoke passed on %s\n' "$device"
