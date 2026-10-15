#!/usr/bin/env python3
"""Build the experimental W native-controls APK using an installed SDK/NDK.

No Gradle project or package download is needed. Output and a development
signing key live under bin/android. This is a debug APK, not a release build.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def newest(directory, pattern):
    choices = [p for p in directory.glob(pattern) if p.is_dir() and not re.search(r"rc|beta", p.name)]
    if not choices:
        raise RuntimeError(f"No installed {pattern} package in {directory}")
    return max(choices, key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.name)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", default="graphics/android/demo.w")
    parser.add_argument("--compiler", default=os.environ.get("W_COMPILER", "bin/wv2"))
    parser.add_argument("--sdk", default=os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
                        or str(Path.home() / "Android/Sdk"))
    parser.add_argument("--ndk", default=os.environ.get("ANDROID_NDK_HOME"))
    parser.add_argument("--out", default="bin/android/app")
    parser.add_argument("--probes", action="store_true", help="include device ABI/compiler integration probes")
    args = parser.parse_args()
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
    classes, dex, libs = out / "classes", out / "dex", out / "lib/arm64-v8a"
    for path in (classes, dex, libs):
        if path.exists():
            shutil.rmtree(path)
        path.mkdir(parents=True)
    run(compiler, "arm64_android", "--shared", "--strict", args.source, "-o", libs / "libwapp.so")
    probe_sources = []
    if args.probes:
        run(compiler, "arm64_android", "--shared", "--strict", "compiler/cli.w", "-o", libs / "libwcompiler.so")
        run(compiler, "arm64_android", "--shared", "--strict", "tests/android_elf_fixture.w",
            "tests/android_elf_imports.w", "-o", libs / "libandroid_elf.so")
        probe_sources = ["-DW_ANDROID_PROBES", "tests/android_abi_probe.c", "tools/android/compiler_probe.c"]
    run(clang, "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-Wl,--no-undefined",
        "-Wl,-z,max-page-size=16384", "-Wl,-z,common-page-size=16384", "-Wl,-z,relro,-z,now",
        "-Wl,-soname,libwandroid.so", "tools/android/host.c", *probe_sources,
        "-ldl", "-o", libs / "libwandroid.so")
    run(sys.executable, "tools/android/check_elf.py", *sorted(libs.glob("*.so")))
    android_jar = platform / "android.jar"
    run("javac", "-encoding", "UTF-8", "-source", "8", "-target", "8", "-Xlint:-options",
        "-classpath", android_jar, "-d", classes, "tools/android/WActivity.java")
    run(build_tools / "d8", "--min-api", "28", "--lib", android_jar, "--output", dex,
        *sorted(classes.rglob("*.class")))
    unsigned, aligned, apk = out / "unsigned.apk", out / "aligned.apk", out / "WApp.apk"
    run(build_tools / "aapt2", "link", "-I", android_jar, "--manifest", "tools/android/AndroidManifest.xml",
        "--min-sdk-version", "28", "--target-sdk-version", "35", "-o", unsigned)
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
    key = ROOT / "bin/android/debug.keystore"
    if not key.exists():
        key.parent.mkdir(parents=True, exist_ok=True)
        run("keytool", "-genkeypair", "-keystore", key, "-storepass", "android", "-keypass", "android",
            "-alias", "androiddebugkey", "-dname", "CN=W Android Development", "-keyalg", "RSA",
            "-keysize", "2048", "-validity", "10000", "-noprompt")
    run(build_tools / "apksigner", "sign", "--ks", key, "--ks-pass", "pass:android",
        "--key-pass", "pass:android", "--out", apk, aligned)
    run(build_tools / "apksigner", "verify", apk)
    run(build_tools / "zipalign", "-c", "-P", "16", "4", apk)
    print(apk)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"Android APK build failed: {error}")
