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
"$compiler" arm64_darwin --strict tools/ios/plist.w -o "$out/plist.new"
mv -f "$out/plist.new" "$out/plist"
"$out/plist" "$app" "$plist_platform" "${W_IOS_BUNDLE_ID:-org.wlang.native-demo}"
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
"$compiler" arm64_darwin --strict tools/ios/check_macho.w -o "$out/check_macho.new"
mv -f "$out/check_macho.new" "$out/check_macho"
"$out/check_macho" "$app/WApp" "$platform"
printf '%s\n' "$app"
