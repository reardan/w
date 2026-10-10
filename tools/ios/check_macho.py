#!/usr/bin/env python3
"""Check W's iOS Mach-O platform, entry point, W^X, and UIKit-host import."""
import struct
import sys
from pathlib import Path


def check(path, platform):
    data = Path(path).read_bytes()
    magic, cpu, _, kind, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<8I", data)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C, "expected ARM64 Mach-O"
    assert kind == 2 and flags & 0x200000, "expected PIE executable"
    offset = 32
    platforms, entries, imports, signatures = [], [], [], []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        assert size >= 8 and size % 8 == 0 and offset + size <= 32 + sizeofcmds
        if cmd == 0x32:
            platforms.append(struct.unpack_from("<III", data, offset + 8))
        elif cmd == 0x80000028:
            entries.append(struct.unpack_from("<Q", data, offset + 8)[0])
        elif cmd == 0xC:
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            imports.append(data[offset + name_offset:offset + size].split(b"\0", 1)[0])
        elif cmd == 0x19:
            maxprot, initprot = struct.unpack_from("<II", data, offset + 56)
            assert not (initprot & 2 and initprot & 4), "writable executable segment"
            assert initprot & maxprot == initprot
        elif cmd == 0x1D:
            signatures.append(struct.unpack_from("<II", data, offset + 8))
        offset += size
    assert offset == 32 + sizeofcmds
    expected = {"device": 2, "simulator": 7}[platform]
    assert platforms == [(expected, 17 << 16, 17 << 16)], platforms
    assert len(entries) == 1 and entries[0] < len(data)
    assert b"@executable_path/Frameworks/WIOS.framework/WIOS" in imports
    assert signatures and all(off + length <= len(data) for off, length in signatures)
    print(f"iOS Mach-O valid: {platform}, ARM64, iOS 17+, PIE, W^X, UIKit bridge")


if __name__ == "__main__":
    check(*sys.argv[1:])
