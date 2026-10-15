#!/usr/bin/env python3
"""Check Android ARM64 shared objects without relying on an NDK installation."""
from pathlib import Path
import struct
import sys


def check(path):
    data = Path(path).read_bytes()
    def unpack(fmt, offset):
        return struct.unpack_from("<" + fmt, data, offset)
    def require(condition, message):
        if not condition:
            raise ValueError(f"{path}: {message}")
    require(data[:7] == b"\x7fELF\x02\x01\x01", "expected little-endian ELF64")
    require(unpack("HH", 16) == (3, 183), "expected ARM64 ET_DYN")
    phoff, = unpack("Q", 32)
    phentsize, phnum = unpack("HH", 54)
    require(phentsize == 56, "invalid program header size")
    loads = 0
    for i in range(phnum):
        kind, flags, offset, addr, _, size, memsize, alignment = unpack("IIQQQQQQ", phoff + i * phentsize)
        require(offset + size <= len(data), "segment extends beyond file")
        if kind == 1:
            loads += 1
            require(alignment >= 16384 and alignment & (alignment - 1) == 0, "LOAD alignment below 16 KB")
            require((addr - offset) % 16384 == 0, "LOAD not congruent on 16 KB pages")
            require(flags & 3 != 3, "writable executable LOAD")
            require(memsize >= size, "LOAD memsz below filesz")
        if kind == 0x6474E551:
            require(flags & 1 == 0, "executable stack")
        if kind == 2:
            for pos in range(offset, offset + size, 16):
                tag, value = unpack("QQ", pos)
                require(tag != 22 and not (tag == 30 and value & 4), "text relocations")
                if tag == 0:
                    break
    require(loads >= 2, "expected separate code/data LOAD segments")
    print(f"{path}: ARM64 shared object, 16 KB alignment, W^X: OK")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: check_elf.py library.so [...]")
    try:
        for filename in sys.argv[1:]:
            check(filename)
    except (OSError, ValueError, struct.error) as error:
        sys.exit(str(error))
