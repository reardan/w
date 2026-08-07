#!/usr/bin/env python3
"""Convert a binary PPM (P6) to PNG using only the standard library.

Companion to graphics/ui/demo.w's --screenshot flag, which writes the
demo's final frame as P6.

Usage: python3 tools/ppm_to_png.py in.ppm out.png
"""
import struct
import sys
import zlib


def read_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    # Header: P6, whitespace-separated width/height/maxval (with
    # optional # comments), one whitespace byte, then raw pixels.
    parts = []
    i = 0
    while len(parts) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b'#':
            while data[i:i + 1] not in (b'\n', b''):
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        parts.append(data[i:j])
        i = j
    i += 1
    magic, w, h, maxval = parts[0], int(parts[1]), int(parts[2]), int(parts[3])
    if magic != b'P6' or maxval != 255:
        raise SystemExit('expected an 8-bit P6 PPM')
    return w, h, data[i:i + w * h * 3]


def write_png(path, w, h, rgb):
    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload
                + struct.pack('>I', zlib.crc32(tag + payload)))

    raw = b''.join(b'\x00' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))


if __name__ == '__main__':
    w, h, rgb = read_ppm(sys.argv[1])
    write_png(sys.argv[2], w, h, rgb)
