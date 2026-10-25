#!/usr/bin/env python3
"""FreeType reference rows for tests/ttf_hint_test.w (lib/ttf_hint.w).

    python3 tools/ttf_hint_ref.py > tests/data/ttf_hint_freetype.txt

Renders the golden set of tools/ttf_hint_golden.w (the same fonts, sizes
and characters) with FreeType's light autohinter (FT_LOAD_TARGET_LIGHT |
FT_LOAD_FORCE_AUTOHINT, which TrueType and CFF fonts both take) and
prints, per strike, "@font ppem", then per glyph "U+hex top s0 s1 ...":
the bitmap's top row (pixels above the baseline) and each row's summed
coverage. The test compares its own hinted rows with these: which rows
carry ink, and how the ink is spread over them. Needs freetype-py; it is
only a reference generator, never a build or run-time dependency.
"""
import freetype

FONTS = ["tests/data/fonts/NotoSans-subset.ttf", "tests/data/fonts/NotoSans-cff-subset.otf"]
PPEMS = range(9, 15)
TEXT = "ARTVWcefiloq"
FLAGS = freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_LIGHT | freetype.FT_LOAD_FORCE_AUTOHINT


def main():
    print("# FreeType %d.%d.%d light autohinter row sums; regenerate with tools/ttf_hint_ref.py" % freetype.version())
    for path in FONTS:
        face = freetype.Face(path)
        for ppem in PPEMS:
            face.set_pixel_sizes(0, ppem)
            print("@%s %d" % (path, ppem))
            for ch in TEXT:
                face.load_char(ch, FLAGS)
                glyph = face.glyph
                bitmap = glyph.bitmap
                rows = [sum(bitmap.buffer[r * bitmap.pitch:r * bitmap.pitch + bitmap.width]) for r in range(bitmap.rows)]
                print(" ".join(["U+%02x" % ord(ch), str(glyph.bitmap_top)] + [str(v) for v in rows]))


if __name__ == "__main__":
    main()
