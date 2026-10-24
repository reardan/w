#!/usr/bin/env python3
"""Compare the portable shaper (tools/shape_dump.w) with HarfBuzz.

    pip install uharfbuzz
    bin/wv2 tools/shape_dump.w -o bin/shape_dump
    python3 tools/shape_compare_hb.py font.ttf lines.txt [more fonts...]

Shapes every line of lines.txt with uharfbuzz at scale = unitsPerEm (font
units, like shape_dump) and reports lines whose glyph ids, clusters,
advances or offsets differ. Exits nonzero when any line differs. A
qualification aid for issue #459; it is not part of the test suite.
"""
import subprocess
import sys

import uharfbuzz as hb


def harfbuzz(path, lines):
    blob = hb.Blob.from_file_path(path)
    face = hb.Face(blob)
    font = hb.Font(face)
    font.scale = (face.upem, face.upem)
    out = []
    for text in lines:
        buf = hb.Buffer()
        buf.add_utf8(text.encode("utf-8"))
        buf.guess_segment_properties()
        # Match shape_dump: the first strong character decides the
        # direction, else the script's own direction.
        strong = None
        for ch in text:
            bidi = __import__("unicodedata").bidirectional(ch)
            if bidi == "L":
                strong = "ltr"
                break
            if bidi in ("R", "AL"):
                strong = "rtl"
                break
        if strong:
            buf.direction = strong
        hb.shape(font, buf, {})
        cells = ["dir=" + buf.direction]
        for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
            cells.append("%d@%d+%d(%d,%d)" % (info.codepoint, info.cluster, pos.x_advance, pos.x_offset, pos.y_offset))
        out.append(" ".join(cells))
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    lines_path = sys.argv[2]
    fonts = [sys.argv[1]] + sys.argv[3:]
    with open(lines_path, encoding="utf-8") as f:
        lines = [line.rstrip("\n") for line in f]
    failures = 0
    for path in fonts:
        got = subprocess.run(["bin/shape_dump", path, lines_path], capture_output=True, text=True, check=True).stdout.splitlines()
        want = harfbuzz(path, lines)
        for text, a, b in zip(lines, want, got):
            if a.split() != b.split():
                failures += 1
                print("DIFF %s: %s\n  harfbuzz %s\n  portable %s" % (path, text, a, b))
    print("%d differing lines" % failures)
    return failures != 0


if __name__ == "__main__":
    sys.exit(main())
