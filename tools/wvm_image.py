#!/usr/bin/env python3
"""Assemble a deterministic initramfs from a SHA256-pinned Linux rootfs tar.

No downloads, host extraction, package installation, or credential discovery.
The rootfs must already contain the shell, Git, runtimes and CA certificates
required by its jobs. Python is a build-time dependency, never a VM dependency.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import tarfile
import tempfile

MAX_BYTES = 2 * 1024**3
MAX_ENTRIES = 200_000


def digest_file(path):
    with open(path, "rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
        return digest.hexdigest()


def clean_name(name):
    parts = PurePosixPath(name).parts
    if name.startswith("/") or ".." in parts or "\0" in name:
        raise ValueError(f"unsafe archive path: {name!r}")
    value = "/".join(part for part in parts if part != ".")
    if len(value.encode()) > 4095:
        raise ValueError("archive path too long")
    return value


def write_entry(output, inode, name, mode, size, source=None, device=(0, 0)):
    encoded = name.encode() + b"\0"
    fields = (inode, mode, 0, 0, 1, 0, size, 0, 0,
              device[0], device[1], len(encoded), 0)
    output.write(b"070701" + b"".join(f"{v:08x}".encode() for v in fields))
    output.write(encoded)
    output.write(b"\0" * (-output.tell() % 4))
    remaining = size
    while remaining:
        block = source.read(min(remaining, 1024 * 1024))
        if not block:
            raise ValueError(f"truncated content for {name}")
        output.write(block)
        remaining -= len(block)
    output.write(b"\0" * (-output.tell() % 4))


def build(rootfs, expected_sha256, init, output):
    # Open once: digest and parse exactly the same descriptor.
    with open(rootfs, "rb") as archive_file:
        digest = hashlib.sha256()
        for block in iter(lambda: archive_file.read(1024 * 1024), b""):
            digest.update(block)
        if digest.hexdigest() != expected_sha256.lower():
            raise ValueError("rootfs SHA256 mismatch")
        archive_file.seek(0)
        with tarfile.open(fileobj=archive_file, mode="r:*") as archive:
            entries = {}
            size = 0
            for member in archive:
                name = clean_name(member.name)
                if not name:
                    if not member.isdir():
                        raise ValueError("root entry must be a directory")
                    continue
                if name == "TRAILER!!!" or name.startswith("init/") or name.startswith("dev/console/"):
                    raise ValueError(f"reserved image path: {name}")
                if name in entries:
                    raise ValueError(f"duplicate archive path: {name}")
                if not (member.isdir() or member.isfile() or member.issym() or member.islnk()):
                    raise ValueError(f"unsupported archive entry: {name}")
                if member.size < 0 or member.size > MAX_BYTES:
                    raise ValueError("invalid entry size")
                size += member.size
                if size > MAX_BYTES or len(entries) >= MAX_ENTRIES:
                    raise ValueError("rootfs exceeds image limits")
                entries[name] = member
            for name in list(entries):
                parent = PurePosixPath(name).parent
                while str(parent) != ".":
                    parent_name = str(parent)
                    if parent_name in entries and not entries[parent_name].isdir():
                        raise ValueError(f"non-directory ancestor: {parent_name}")
                    if parent_name not in entries:
                        member = tarfile.TarInfo(parent_name)
                        member.type, member.mode = tarfile.DIRTYPE, 0o755
                        entries[parent_name] = member
                    parent = parent.parent
            for name in ("dev", "proc", "sys", "tmp", "workspace"):
                if name in entries and not entries[name].isdir():
                    raise ValueError(f"required mountpoint is not a directory: {name}")
                member = tarfile.TarInfo(name)
                member.type, member.mode = tarfile.DIRTYPE, 0o755
                if name == "tmp":
                    member.mode = 0o1777
                entries[name] = member
            if len(entries) > MAX_ENTRIES:
                raise ValueError("expanded entry count exceeds image limit")
            # The tool owns PID 1 and the early console, regardless of rootfs.
            entries.pop("init", None)
            entries.pop("dev/console", None)
            output = Path(output)
            temp_name = None
            try:
                with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as target:
                    temp_name = target.name
                    inode = 1
                    expanded_size = 0
                    for name, member in sorted(entries.items()):
                        source = None
                        length = 0
                        mode = member.mode & 0o777  # strip setuid/setgid
                        if member.isdir():
                            mode |= stat.S_IFDIR
                            if name == "tmp":
                                mode |= stat.S_ISVTX
                        elif member.issym():
                            import io
                            content = member.linkname.encode()
                            if b"\0" in content or len(content) > 4095:
                                raise ValueError("invalid symlink target")
                            source, length = io.BytesIO(content), len(content)
                            mode |= stat.S_IFLNK
                        else:
                            linked = member
                            if member.islnk():
                                linked = entries.get(clean_name(member.linkname))
                                if linked is None or not linked.isfile():
                                    raise ValueError(f"hardlink must name a regular file: {name}")
                            source = archive.extractfile(linked)
                            length = linked.size
                            mode |= stat.S_IFREG
                        expanded_size += length
                        if expanded_size > MAX_BYTES:
                            raise ValueError("expanded image exceeds limit")
                        write_entry(target, inode, name, mode, length, source)
                        if source:
                            source.close()
                        inode += 1
                    with open(init, "rb") as init_file:
                        header = init_file.read(20)
                        if header[:6] != b"\x7fELF\x02\x01" or header[18:20] != b"\x3e\x00":
                            raise ValueError("init must be a Linux x64 ELF")
                        init_file.seek(0)
                        init_size = os.fstat(init_file.fileno()).st_size
                        if init_size > 64 * 1024**2:
                            raise ValueError("init exceeds size limit")
                        init_digest = hashlib.sha256(init_file.read()).hexdigest()
                        init_file.seek(0)
                        write_entry(target, inode, "init", stat.S_IFREG | 0o755, init_size, init_file)
                    write_entry(target, inode + 1, "dev/console", stat.S_IFCHR | 0o600, 0, device=(5, 1))
                    write_entry(target, inode + 2, "TRAILER!!!", 0, 0)
                    target.write(b"\0" * (-target.tell() % 512))
                os.replace(temp_name, output)
                temp_name = None
            finally:
                if temp_name is not None:
                    os.unlink(temp_name)
    manifest = {"format": 1, "rootfs_sha256": expected_sha256.lower(),
                "init_sha256": init_digest, "image_sha256": digest_file(output),
                "entries": len(entries) + 2}
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rootfs", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--init", default="bin/wvm_init")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        manifest = build(args.rootfs, args.sha256, args.init, args.output)
        Path(args.output + ".json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f"wvm_image: {error}\n")
    print(json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    main()
