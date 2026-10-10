#!/bin/sh
# Build a native W/UIKit .app. Device installation also needs a development
# identity and matching provisioning profile; see docs/projects/ios.md.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
platform=${1:-simulator}
source=${2:-graphics/ios/demo.w}
compiler=${W_COMPILER:-"$root/bin/wv2_darwin"}
case "$platform" in
    simulator) sdk=iphonesimulator; target=arm64_ios_sim; triple=arm64-apple-ios17.0-simulator; plist_platform=iPhoneSimulator ;;
    device) sdk=iphoneos; target=arm64_ios; triple=arm64-apple-ios17.0; plist_platform=iPhoneOS ;;
    *) echo "usage: $0 [simulator|device] [source.w]" >&2; exit 2 ;;
esac
if [ ! -x "$compiler" ]; then
    echo "Build the host compiler with ./wbuild build_darwin (or set W_COMPILER)." >&2
    exit 1
fi
out="$root/bin/ios/$platform"
app="$out/WApp.app"
framework="$app/Frameworks/WIOS.framework"
mkdir -p "$framework"
# Replace executed Mach-O files through a fresh inode (Darwin caches signatures).
"$compiler" "$target" --strict "$source" -o "$out/WApp.new"
chmod +x "$out/WApp.new"
mv -f "$out/WApp.new" "$app/WApp"
sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
xcrun --sdk "$sdk" clang -target "$triple" -isysroot "$sdk_path" \
    -fobjc-arc -Wall -Wextra -Werror -dynamiclib \
    tools/ios/host.m tools/ios/callback.S -framework UIKit -framework Foundation \
    -install_name '@executable_path/Frameworks/WIOS.framework/WIOS' -o "$out/WIOS.new"
mv -f "$out/WIOS.new" "$framework/WIOS"
python3 - "$app" "$plist_platform" "${W_IOS_BUNDLE_ID:-org.wlang.native-demo}" <<'PY'
import pathlib, plistlib, sys
app, platform, identifier = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
base = dict(CFBundleDevelopmentRegion="en", CFBundleInfoDictionaryVersion="6.0",
            CFBundleShortVersionString="1.0", CFBundleVersion="1", MinimumOSVersion="17.0",
            CFBundleSupportedPlatforms=[platform])
app_info = dict(base, CFBundleIdentifier=identifier, CFBundleExecutable="WApp",
                CFBundleName="W on iPhone", CFBundlePackageType="APPL",
                UIDeviceFamily=[1, 2], UILaunchScreen={},
                UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
framework_info = dict(base, CFBundleIdentifier="org.wlang.WIOS", CFBundleExecutable="WIOS",
                      CFBundleName="WIOS", CFBundlePackageType="FMWK")
for path, value in [(app / "Info.plist", app_info),
                    (app / "Frameworks/WIOS.framework/Info.plist", framework_info)]:
    path.write_bytes(plistlib.dumps(value))
PY
if [ "$platform" = simulator ]; then
    codesign --force --sign - "$framework"
    codesign --force --sign - "$app"
elif [ -n "${W_IOS_SIGN_IDENTITY:-}" ]; then
    : "${W_IOS_PROFILE:?Set W_IOS_PROFILE to a matching .mobileprovision file}"
    : "${W_IOS_ENTITLEMENTS:?Set W_IOS_ENTITLEMENTS to the matching entitlements plist}"
    cp "$W_IOS_PROFILE" "$app/embedded.mobileprovision"
    codesign --force --sign "$W_IOS_SIGN_IDENTITY" "$framework"
    codesign --force --sign "$W_IOS_SIGN_IDENTITY" --entitlements "$W_IOS_ENTITLEMENTS" "$app"
else
    echo "Device app built; deployment requires W_IOS_SIGN_IDENTITY, W_IOS_PROFILE and W_IOS_ENTITLEMENTS." >&2
fi
python3 tools/ios/check_macho.py "$app/WApp" "$platform"
printf '%s\n' "$app"
