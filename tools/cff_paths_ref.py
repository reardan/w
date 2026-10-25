#!/usr/bin/env python3
"""Reference CFF glyph paths for tests/ttf_cff_test.w, from fontTools.

    python3 tools/cff_paths_ref.py font.otf [more.otf...] > tests/data/cff_paths.txt

One line per glyph: "@font" starts a font; then "gid [xMin yMin xMax
yMax] M x y L x y C x1 y1 x2 y2 x y Z ..." in font units rounded half
up, with control-point bounds, the format lib/ttf.w's ttf_cff_path and
ttf_glyph_bbox produce.
"""
import math
import sys

from fontTools.pens.boundsPen import ControlBoundsPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.ttLib import TTFont


def r(v):
    return math.floor(v + 0.5)


def main():
    print("# fontTools reference paths; regenerate with tools/cff_paths_ref.py")
    for path in sys.argv[1:]:
        print("@" + path)
        font = TTFont(path)
        glyphs = font.getGlyphSet()
        for gid, name in enumerate(font.getGlyphOrder()):
            pen = RecordingPen()
            glyphs[name].draw(pen)
            bounds = ControlBoundsPen(glyphs)
            glyphs[name].draw(bounds)
            box = bounds.bounds or (0, 0, 0, 0)
            out = ["%d [%d %d %d %d]" % (gid, math.floor(box[0]), math.floor(box[1]), math.ceil(box[2]), math.ceil(box[3]))]
            for op, args in pen.value:
                if op == "moveTo":
                    out.append("M %d %d" % (r(args[0][0]), r(args[0][1])))
                elif op == "lineTo":
                    out.append("L %d %d" % (r(args[0][0]), r(args[0][1])))
                elif op == "curveTo":
                    out.append("C " + " ".join("%d %d" % (r(x), r(y)) for x, y in args))
                elif op in ("closePath", "endPath"):
                    out.append("Z")
            print(" ".join(out))


if __name__ == "__main__":
    main()
