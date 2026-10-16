#!/usr/bin/env python3
"""Build the experimental W native-controls APK using an installed SDK/NDK.

No Gradle project or package download is needed. Output and a development
signing key live under bin/android. This is a debug APK, not a release build.
Other repositories can package their own W app with --package, --label,
--icon, --scheme, --internet, --notifications, --import-root and a shared
--keystore.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
ANDROID_NS = "http://schemas.android.com/apk/res/android"
THEMES = {
    "light": "@android:style/Theme.Material.Light.NoActionBar",
    # Follows the system light/dark setting with the device's native styling (API 29+).
    "daynight": "@style/WDayNight",
}
DAYNIGHT = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="WDayNight" parent="@android:style/Theme.DeviceDefault.DayNight">
        <item name="android:windowActionBar">false</item>
        <item name="android:windowNoTitle">true</item>
    </style>
</resources>
"""
# Cleartext HTTP only to this device's loopback (e.g. `adb reverse` during development).
LOOPBACK_CLEARTEXT = """<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="false" />
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
        <domain includeSubdomains="false">localhost</domain>
    </domain-config>
</network-security-config>
"""


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def newest(directory, pattern):
    choices = [p for p in directory.glob(pattern) if p.is_dir() and not re.search(r"rc|beta", p.name)]
    if not choices:
        raise RuntimeError(f"No installed {pattern} package in {directory}")
    return max(choices, key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.name)))


def manifest(args, path, resources):
    """Write the app manifest: tools/android/AndroidManifest.xml plus per-app settings."""
    android = "{%s}" % ANDROID_NS
    ET.register_namespace("android", ANDROID_NS)
    tree = ET.parse(ROOT / "tools/android/AndroidManifest.xml")
    root = tree.getroot()
    root.set("package", args.package)
    root.find("uses-sdk").set(android + "minSdkVersion", str(args.min_sdk))
    application = root.find("application")
    application.set(android + "label", args.label)
    application.set(android + "theme", THEMES[args.theme])
    if args.theme == "daynight":
        (resources / "values").mkdir(parents=True)
        (resources / "values/w_theme.xml").write_text(DAYNIGHT, encoding="utf-8")
    activity = application.find("activity")
    # The Java package stays fixed: host.c's JNI symbols name org.wlang.androiddemo.WActivity.
    activity.set(android + "name", "org.wlang.androiddemo.WActivity")
    if args.icon:
        # Density mipmaps, an adaptive icon with a themed (monochrome) layer and
        # a notification glyph, generated from one PNG with the JDK.
        java = shutil.which("java", path=str(Path(os.environ["JAVA_HOME"]) / "bin")) if os.environ.get("JAVA_HOME") else None
        java = java or shutil.which("java")
        if not java:
            raise RuntimeError("--icon needs a JDK `java` (JAVA_HOME or PATH)")
        command = [java, "-Djava.awt.headless=true", ROOT / "tools/android/icon/WIcon.java",
                   Path(args.icon).expanduser().resolve(), resources]
        run(*command, *([args.icon_background] if args.icon_background else []))
        application.set(android + "icon", "@mipmap/w_app_icon")
        application.set(android + "roundIcon", "@mipmap/w_app_icon")
    if args.notifications:
        # Local notifications (POST_NOTIFICATIONS is a runtime permission on API 33+)
        # and WService, the foreground service behind wandroid_background.
        for name in ("POST_NOTIFICATIONS", "FOREGROUND_SERVICE", "FOREGROUND_SERVICE_DATA_SYNC"):
            permission = ET.Element("uses-permission", {android + "name": "android.permission." + name})
            root.insert(list(root).index(application), permission)
        ET.SubElement(application, "service", {android + "name": "org.wlang.androiddemo.WService",
                                               android + "exported": "false",
                                               android + "foregroundServiceType": "dataSync"})
    if args.internet:
        permission = ET.Element("uses-permission", {android + "name": "android.permission.INTERNET"})
        root.insert(list(root).index(application), permission)
        application.set(android + "networkSecurityConfig", "@xml/w_network_security")
        (resources / "xml").mkdir(parents=True)
        (resources / "xml/w_network_security.xml").write_text(LOOPBACK_CLEARTEXT, encoding="utf-8")
    if args.scheme:
        # A deep link reaches the running Activity through onNewIntent.
        activity.set(android + "launchMode", "singleTask")
        for scheme in args.scheme:
            intents = ET.SubElement(activity, "intent-filter")
            ET.SubElement(intents, "action", {android + "name": "android.intent.action.VIEW"})
            for category in ("DEFAULT", "BROWSABLE"):
                ET.SubElement(intents, "category", {android + "name": "android.intent.category." + category})
            ET.SubElement(intents, "data", {android + "scheme": scheme})
    tree.write(path, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", default="graphics/android/demo.w")
    parser.add_argument("--package", default="org.wlang.androiddemo", help="application id")
    parser.add_argument("--label", default="W on Android", help="launcher label")
    parser.add_argument("--icon", help="launcher icon PNG (mipmaps and an adaptive icon are generated)")
    parser.add_argument("--icon-background", help="adaptive icon background #RRGGBB (default: detected)")
    parser.add_argument("--theme", choices=sorted(THEMES), default="light")
    parser.add_argument("--min-sdk", type=int, default=28)
    parser.add_argument("--scheme", action="append", default=[], help="deep-link URI scheme (repeatable)")
    parser.add_argument("--internet", action="store_true",
                        help="INTERNET permission; cleartext HTTP only to 127.0.0.1/localhost")
    parser.add_argument("--notifications", action="store_true",
                        help="local notifications and the background-work foreground service")
    parser.add_argument("--import-root", help="extra W import root for the app source")
    parser.add_argument("--keystore", default=os.environ.get("W_ANDROID_KEYSTORE", "bin/android/debug.keystore"),
                        help="development signing keystore, created if missing (share one across apps)")
    parser.add_argument("--keystore-pass", default=os.environ.get("W_ANDROID_KEYSTORE_PASS", "android"))
    parser.add_argument("--key-alias", default=os.environ.get("W_ANDROID_KEY_ALIAS", "androiddebugkey"))
    parser.add_argument("--apk-name", default="WApp.apk")
    parser.add_argument("--compiler", default=os.environ.get("W_COMPILER", "bin/wv2"))
    parser.add_argument("--sdk", default=os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
                        or str(Path.home() / "Android/Sdk"))
    parser.add_argument("--ndk", default=os.environ.get("ANDROID_NDK_HOME"))
    parser.add_argument("--out", default="bin/android/app")
    parser.add_argument("--probes", action="store_true", help="include device ABI/compiler integration probes")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+", args.package):
        raise RuntimeError(f"Invalid Android package id: {args.package}")
    if args.theme == "daynight" and args.min_sdk < 29:
        raise RuntimeError("--theme daynight requires --min-sdk 29 or newer")
    if args.min_sdk < 28:
        raise RuntimeError("W Android apps require --min-sdk 28 or newer")
    for scheme in args.scheme:
        if not re.fullmatch(r"[a-z][a-z0-9+.-]*", scheme):
            raise RuntimeError(f"Invalid URI scheme: {scheme}")
    sdk = Path(args.sdk).expanduser().resolve()
    ndk = Path(args.ndk).expanduser().resolve() if args.ndk else newest(sdk / "ndk", "*")
    build_tools = newest(sdk / "build-tools", "*")
    platform = newest(sdk / "platforms", "android-*")
    if int(platform.name.split("-")[-1]) < 35:
        raise RuntimeError("Install Android SDK platform 35 or newer")
    hosts = list((ndk / "toolchains/llvm/prebuilt").glob("*"))
    if len(hosts) != 1:
        raise RuntimeError("Expected one NDK host toolchain")
    clang = hosts[0] / "bin/aarch64-linux-android28-clang"
    compiler = (ROOT / args.compiler).resolve()
    if not compiler.is_file():
        raise RuntimeError("Build W with ./wbuild build first, or set --compiler")
    out = (ROOT / args.out).resolve()
    classes, dex, libs, resources = out / "classes", out / "dex", out / "lib/arm64-v8a", out / "res"
    for path in (classes, dex, libs, resources):
        if path.exists():
            shutil.rmtree(path)
        path.mkdir(parents=True)
    imports = ["--import-root", Path(args.import_root).expanduser().resolve()] if args.import_root else []
    run(compiler, "arm64_android", "--shared", "--strict", *imports, args.source, "-o", libs / "libwapp.so")
    probe_sources = []
    if args.probes:
        run(compiler, "arm64_android", "--shared", "--strict", "compiler/cli.w", "-o", libs / "libwcompiler.so")
        run(compiler, "arm64_android", "--shared", "--strict", "tests/android_elf_fixture.w",
            "tests/android_elf_imports.w", "-o", libs / "libandroid_elf.so")
        probe_sources = ["-DW_ANDROID_PROBES", "tests/android_abi_probe.c", "tools/android/compiler_probe.c"]
    run(clang, "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-Wl,--no-undefined",
        "-Wl,-z,max-page-size=16384", "-Wl,-z,common-page-size=16384", "-Wl,-z,relro,-z,now",
        "-Wl,-soname,libwandroid.so", "tools/android/host.c", "tools/android/kit.c", *probe_sources,
        "-ldl", "-o", libs / "libwandroid.so")
    run(sys.executable, "tools/android/check_elf.py", *sorted(libs.glob("*.so")))
    android_jar = platform / "android.jar"
    run("javac", "-encoding", "UTF-8", "-source", "8", "-target", "8", "-Xlint:-options",
        "-classpath", android_jar, "-d", classes, *sorted((ROOT / "tools/android").glob("*.java")))
    run(build_tools / "d8", "--min-api", str(args.min_sdk), "--lib", android_jar, "--output", dex,
        *sorted(classes.rglob("*.class")))
    unsigned, aligned, apk = out / "unsigned.apk", out / "aligned.apk", out / args.apk_name
    app_manifest = out / "AndroidManifest.xml"
    manifest(args, app_manifest, resources)
    compiled = []
    if any(resources.iterdir()):
        compiled = [out / "resources.zip"]
        run(build_tools / "aapt2", "compile", "--dir", resources, "-o", compiled[0])
    run(build_tools / "aapt2", "link", "-I", android_jar, "--manifest", app_manifest, *compiled,
        "--min-sdk-version", str(args.min_sdk), "--target-sdk-version", "35", "-o", unsigned)
    with zipfile.ZipFile(unsigned, "a") as archive:
        archive.write(dex / "classes.dex", "classes.dex", compress_type=zipfile.ZIP_DEFLATED)
        for library in sorted(libs.glob("*.so")):
            archive.write(library, f"lib/arm64-v8a/{library.name}", compress_type=zipfile.ZIP_STORED)
        if args.probes:
            dependencies = subprocess.run([str(compiler), "deps", "--json", "arm64_android",
                                           "tests/android_device_program.w"], cwd=ROOT,
                                          check=True, stdout=subprocess.PIPE, text=True).stdout
            sources = set()
            for line in dependencies.splitlines():
                if not line.startswith("{"):
                    continue
                source = (ROOT / json.loads(line)["file"]).resolve()
                if not source.is_relative_to(ROOT):
                    raise RuntimeError(f"Probe dependency is outside checkout: {source}")
                sources.add(source)
            for source in sorted(sources):
                archive.write(source, "assets/w-src/" + source.relative_to(ROOT).as_posix(),
                              compress_type=zipfile.ZIP_DEFLATED)
    run(build_tools / "zipalign", "-P", "16", "-f", "4", unsigned, aligned)
    key = (ROOT / Path(args.keystore).expanduser()).resolve()
    secret = "pass:" + args.keystore_pass
    if not key.exists():
        key.parent.mkdir(parents=True, exist_ok=True)
        run("keytool", "-genkeypair", "-keystore", key, "-storepass", args.keystore_pass,
            "-keypass", args.keystore_pass, "-alias", args.key_alias, "-dname", "CN=W Android Development",
            "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000", "-noprompt")
    run(build_tools / "apksigner", "sign", "--ks", key, "--ks-key-alias", args.key_alias, "--ks-pass", secret,
        "--key-pass", secret, "--out", apk, aligned)
    run(build_tools / "apksigner", "verify", apk)
    run(build_tools / "zipalign", "-c", "-P", "16", "4", apk)
    print(apk)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"Android APK build failed: {error}")
