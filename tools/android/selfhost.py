#!/usr/bin/env python3
"""Qualify Android ARM64 compiler self-hosting on an explicitly selected adb device.

Requires native ARM64 execution or an emulator configured with ARM64 binfmt
translation. Uses Bionic-linked PIE binaries because Android's translation
runner requires a dynamic segment. Does not exercise the Termux environment.
"""
import argparse
import json
from pathlib import Path, PurePosixPath
import shlex
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[2]
IMPORTS = "tests/android_elf_imports.w"
SMOKE = "tests/android_runtime_smoke.w"


def remote_directory(value):
    path = PurePosixPath(value)
    if (not path.is_absolute() or ".." in path.parts
            or path.parts[:4] != ("/", "data", "local", "tmp")
            or len(path.parts) < 5 or any(ord(c) < 32 for c in value)):
        raise argparse.ArgumentTypeError(
            "--remote must name a dedicated directory below /data/local/tmp, without '..'")
    return str(path)


def run(command, **kwargs):
    return subprocess.run(command, check=True, cwd=ROOT, **kwargs)


def dependency_files(compiler):
    paths = {"w.w", SMOKE, IMPORTS}
    for source in sorted(paths.copy()):
        output = run([str(compiler), "deps", "--json", "arm64_android", source],
                     stdout=subprocess.PIPE, text=True).stdout
        for line in output.splitlines():
            if line.strip():
                paths.add(json.loads(line)["file"])
    result = {}
    for name in sorted(paths):
        # Archive only real files from this checkout. Resolved paths also
        # prevent symlinks or dependency output from escaping the source tree.
        source = (ROOT / name).resolve()
        relative = source.relative_to(ROOT)
        if not source.is_file():
            raise ValueError(f"dependency is not a file: {name}")
        result[relative.as_posix()] = source
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="adb device serial (adb devices)")
    parser.add_argument("--compiler", default="bin/wv2", help="host W compiler, relative to checkout")
    parser.add_argument("--remote", type=remote_directory,
                        default="/data/local/tmp/w-android-selfhost",
                        help="dedicated staging directory below /data/local/tmp; files are retained")
    args = parser.parse_args()
    compiler = (ROOT / args.compiler).resolve()
    adb = ["adb", "-s", args.serial]

    def shell(command, **kwargs):
        return run(adb + ["shell", command], **kwargs)

    page_size = shell(shlex.join(["getconf", "PAGESIZE"]),
                      stdout=subprocess.PIPE, text=True).stdout.strip()
    print(f"Android device {args.serial}: {page_size}-byte pages", flush=True)
    with tempfile.TemporaryDirectory(prefix="w-android-selfhost-") as directory:
        local = Path(directory)
        seed = local / "w_seed"
        smoke = local / "runtime_smoke"
        flags = ["arm64_android", "--strict"]
        run([str(compiler), *flags, "w.w", IMPORTS, "-o", str(seed)])
        run([str(compiler), *flags, SMOKE, IMPORTS, "-o", str(smoke)])
        sources = dependency_files(compiler)
        archive_path = local / "sources.tar"
        with tarfile.open(archive_path, "w") as archive:
            for name, source in sources.items():
                archive.add(source, arcname=name, recursive=False)
        print(f"Staging {len(sources)} source files to {args.remote}", flush=True)
        shell(shlex.join(["mkdir", "-p", args.remote]))
        for source in (seed, smoke, archive_path):
            run(adb + ["push", str(source), args.remote + "/" + source.name])

    commands = [
        shlex.join(["cd", args.remote]),
        shlex.join(["tar", "-xf", "sources.tar"]),
        shlex.join(["chmod", "755", "w_seed", "runtime_smoke"]),
    ]
    for previous, output in (("w_seed", "wv3"), ("wv3", "wv4"), ("wv4", "wv5")):
        commands.append(shlex.join(["./" + previous, *flags, "w.w", IMPORTS, "-o", output]))
        commands.append(shlex.join(["chmod", "755", output]))
    commands.extend([
        shlex.join(["cmp", "wv3", "wv4"]),
        shlex.join(["cmp", "wv4", "wv5"]),
        shlex.join(["./runtime_smoke"]),
        shlex.join(["sha256sum", "wv3", "wv4", "wv5"]),
    ])
    shell(" && ".join(commands))
    print(f"Android compiler fixpoint (wv3 == wv4 == wv5) and runtime smoke: OK ({args.serial})")
    print(f"Device artifacts retained in {args.remote}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"Android self-host qualification failed: {error}")
