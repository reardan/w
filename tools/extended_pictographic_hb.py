#!/usr/bin/env python3
"""Extract HarfBuzz's Extended_Pictographic table.

    git clone --depth 1 --branch 15.0.0 https://github.com/harfbuzz/harfbuzz
    python3 tools/extended_pictographic_hb.py harfbuzz/src > tools/unicode/extended_pictographic_hb.txt

HarfBuzz decides whether a character after ZWJ joins the grapheme before
it (hb_set_unicode_props) with its own Extended_Pictographic table,
src/hb-unicode-emoji-table.hh, generated from a newer emoji-data.txt
than the Unicode 15.0.0 copy under tools/unicode/. This decodes that
table's two-level bit trie (_hb_emoji_is_Extended_Pictographic) and
prints its ranges as "XXXX..YYYY ; Extended_Pictographic" lines, which
tools/generate_text_data.w reads into lib/unicode_text_data.w for
lib/ttf_shape.w (issue #825).
"""
import os
import re
import sys


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    text = open(os.path.join(sys.argv[1], "hb-unicode-emoji-table.hh")).read()
    data = [int(x) for x in re.findall(r"\d+", re.search(r"_hb_emoji_u8\[\d+\]\s*=\s*\{(.*?)\};", text, re.S).group(1))]
    # return u<LIMIT ? b1(u8+BITS, (u8[ROWS + (b4(u8, (u>>6)>>4)<<4) + ((u>>6)&15)]<<6) + (u&63)) : 0
    body = re.search(r"_hb_emoji_is_Extended_Pictographic \(unsigned u\)\s*\{\s*(?:/\*.*?\*/\s*)?return (.*?);\s*\}", text, re.S).group(1)
    limit, bits, rows = [int(x) for x in re.match(r"u<(\d+)u \? \(uint8_t\)\(_hb_emoji_b1\(_hb_emoji_u8\+(\d+)u,\(\(_hb_emoji_u8\[(\d+)u\+", body).groups()]

    def b4(i):
        return (data[i >> 1] >> ((i & 1) << 2)) & 15

    def b1(i):
        return (data[bits + (i >> 3)] >> (i & 7)) & 1

    def pictographic(u):
        if u >= limit:
            return 0
        return b1((data[rows + (b4((u >> 6) >> 4) << 4) + ((u >> 6) & 15)] << 6) + (u & 63))

    header = next(c for c in re.findall(r"/\*(.*?)\*/", text, re.S) if "emoji-data.txt" in c)
    print("# Extended_Pictographic as HarfBuzz 15.0.0 has it, decoded from")
    print("# src/hb-unicode-emoji-table.hh by tools/extended_pictographic_hb.py.")
    print("# HarfBuzz is MIT licensed; its table header follows:")
    for line in header.strip("\n").splitlines():
        line = line.lstrip(" *").rstrip()
        print(("# " + line) if line else "#")
    start = None
    for u in range(0x110001):
        on = u < 0x110000 and pictographic(u)
        if on and start is None:
            start = u
        if not on and start is not None:
            if start == u - 1:
                print("%04X ; Extended_Pictographic" % start)
            else:
                print("%04X..%04X ; Extended_Pictographic" % (start, u - 1))
            start = None
    return 0


if __name__ == "__main__":
    sys.exit(main())
