#!/usr/bin/env python3
"""Build the small color test fonts in tests/data/fonts/ (issue #827).

    python3 tools/make_color_test_fonts.py tests/data/fonts

Needs fontTools. Writes three fonts made for the tests, each with the same
five outline shapes (upem 1000) and the letters A..H mapped to color glyphs:

- ColorTestCOLRv0.ttf: COLR version 0 layers over a two-palette CPAL,
  including a translucent palette entry and foreground (0xFFFF) layers.
- ColorTestCOLRv1.ttf: a COLR version 1 paint graph per letter: solid,
  linear, radial and sweep gradients (pad, repeat, reflect), transforms,
  composite modes, PaintColrGlyph reuse, clip boxes, a foreground layer,
  and one version 0 record alongside.
- ColorTestSbix.ttf: sbix PNG strikes at 16 and 64 ppem, a 'dupe'
  record, and an outline-only glyph.

The PNGs are written by hand (zlib + CRC), so no imaging library is
needed. Rerun after changing this script and update the goldens in
tests/data/color_glyphs/ (W_UPDATE_GOLDENS=1 bin/graphics_ui_color_glyph_test).
"""
import math
import os
import struct
import sys
import zlib

from fontTools.colorLib.builder import buildCOLR, buildCPAL
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables._s_b_i_x import table__s_b_i_x
from fontTools.ttLib.tables.sbixGlyph import Glyph as SbixGlyph
from fontTools.ttLib.tables.sbixStrike import Strike as SbixStrike

UPEM = 1000
SHAPES = ["square", "circle", "triangle", "bar", "ring"]
LETTERS = "ABCDEFGH"


def draw_rect(pen, x0, y0, x1, y1):
    pen.moveTo((x0, y0))
    pen.lineTo((x0, y1))
    pen.lineTo((x1, y1))
    pen.lineTo((x1, y0))
    pen.closePath()


def draw_circle(pen, cx, cy, r, clockwise=True):
    # Eight quadratic arcs: on-curve points on the circle, off-curve
    # points at r / cos(22.5 degrees).
    k = r / math.cos(math.pi / 8)
    step = -1 if clockwise else 1
    points = []
    for i in range(8):
        a = step * i * math.pi / 4
        mid = a + step * math.pi / 8
        points.append(((round(cx + r * math.cos(a)), round(cy + r * math.sin(a))),
                       (round(cx + k * math.cos(mid)), round(cy + k * math.sin(mid)))))
    pen.moveTo(points[0][0])
    for i in range(8):
        pen.qCurveTo(points[i][1], points[(i + 1) % 8][0])
    pen.closePath()


def shape_glyph(name):
    pen = TTGlyphPen(None)
    if name == "square":
        draw_rect(pen, 100, 0, 700, 600)
    elif name == "circle":
        draw_circle(pen, 500, 400, 300)
    elif name == "triangle":
        pen.moveTo((150, 50))
        pen.lineTo((500, 750))
        pen.lineTo((850, 50))
        pen.closePath()
    elif name == "bar":
        draw_rect(pen, 50, 250, 950, 350)
    elif name == "ring":
        draw_circle(pen, 500, 400, 350, True)
        draw_circle(pen, 500, 400, 200, False)
    elif name == "notdef":
        draw_rect(pen, 100, 0, 500, 700)
    return pen.glyph()


def base_font(family, letters):
    order = [".notdef"] + SHAPES + list(letters)
    fb = FontBuilder(UPEM, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({ord(c): c for c in letters})
    glyphs = {".notdef": shape_glyph("notdef")}
    for s in SHAPES:
        glyphs[s] = shape_glyph(s)
    for c in letters:
        # Each letter's own outline is its monochrome fallback.
        glyphs[c] = shape_glyph("square")
    fb.setupGlyf(glyphs)
    glyf = fb.font["glyf"]
    # Left side bearings are the outlines' xMin, as HarfBuzz expects.
    fb.setupHorizontalMetrics({g: (1000, getattr(glyf[g], "xMin", 0)) for g in order})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": family, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    return fb


def colr_v0_font(path):
    fb = base_font("W Color Test COLRv0", "ABC")
    fb.font["COLR"] = buildCOLR({
        "A": [("square", 0), ("circle", 1), ("triangle", 0xFFFF)],
        "B": [("circle", 2), ("bar", 0xFFFF)],
        # C has no record: it draws as its monochrome outline.
    }, version=0)
    fb.font["CPAL"] = buildCPAL([
        [(1.0, 0.0, 0.0, 1.0), (0.0, 0.0, 1.0, 0.5), (0.0, 160 / 255, 0.0, 1.0)],
        [(1.0, 1.0, 0.0, 1.0), (0.0, 1.0, 1.0, 1.0), (1.0, 0.0, 1.0, 1.0)],
    ])
    fb.save(path)


def solid(index, alpha=1.0):
    return {"Format": 2, "PaletteIndex": index, "Alpha": alpha}


def glyph(name, paint):
    return {"Format": 10, "Glyph": name, "Paint": paint}


def stops(*entries, extend="pad"):
    return {"Extend": extend, "ColorStop": [
        {"StopOffset": o, "PaletteIndex": i, "Alpha": a} for (o, i, a) in entries]}


def colr_v1_font(path):
    fb = base_font("W Color Test COLRv1", LETTERS)
    color_glyphs = {
        # Linear gradient (pad) under a half-transparent solid.
        "A": {"Format": 1, "Layers": [
            glyph("square", {"Format": 4, "ColorLine": stops((0.0, 0, 1.0), (1.0, 1, 1.0)),
                             "x0": 100, "y0": 0, "x1": 700, "y1": 0, "x2": 100, "y2": 600}),
            glyph("circle", solid(2, 0.5)),
        ]},
        # Radial gradient, reflect.
        "B": glyph("circle", {"Format": 6, "ColorLine": stops((0.0, 3, 1.0), (0.5, 2, 1.0), extend="reflect"),
                              "x0": 500, "y0": 400, "r0": 0, "x1": 500, "y1": 400, "r1": 200}),
        # Sweep gradient, repeat.
        "C": glyph("square", {"Format": 8, "ColorLine": stops((0.0, 0, 1.0), (0.5, 1, 1.0), (1.0, 0, 1.0), extend="repeat"),
                              "centerX": 400, "centerY": 300, "startAngle": 0.0, "endAngle": 180.0}),
        # Rotation about a center, translation and scaling.
        "D": {"Format": 1, "Layers": [
            {"Format": 26, "angle": 45.0, "centerX": 400, "centerY": 300, "Paint": glyph("square", solid(0))},
            {"Format": 14, "dx": 100, "dy": 100, "Paint": {"Format": 20, "scale": 0.5, "Paint": glyph("circle", solid(1))}},
        ]},
        # Composite: the circle kept only inside the square (SRC_IN).
        "E": {"Format": 32, "CompositeMode": "src_in",
              "SourcePaint": glyph("circle", solid(1)),
              "BackdropPaint": glyph("square", solid(0))},
        # PaintColrGlyph reuse of A, scaled about a center and skewed.
        "F": {"Format": 1, "Layers": [
            {"Format": 22, "scale": 0.5, "centerX": 500, "centerY": 400, "Paint": {"Format": 11, "Glyph": "A"}},
            {"Format": 28, "xSkewAngle": 20.0, "ySkewAngle": 0.0, "Paint": glyph("bar", solid(3))},
            {"Format": 12, "Transform": {"xx": 1.0, "yx": 0.0, "xy": 0.0, "yy": 0.5, "dx": 0, "dy": 0},
             "Paint": glyph("triangle", solid(2, 0.75))},
        ]},
        # A top-level foreground layer between two colored ones, and a
        # multiply composite.
        "G": {"Format": 1, "Layers": [
            glyph("square", solid(0)),
            glyph("bar", solid(0xFFFF)),
            {"Format": 32, "CompositeMode": "multiply",
             "SourcePaint": glyph("circle", solid(3)),
             "BackdropPaint": glyph("circle", solid(1))},
        ]},
        # Version 0 layers in a version 1 table.
        "H": [("ring", 2), ("bar", 0)],
    }
    fb.font["COLR"] = buildCOLR(color_glyphs, glyphMap=fb.font.getReverseGlyphMap(),
                                clipBoxes={"A": (100, 0, 800, 700), "F": (0, -100, 1000, 800)})
    fb.font["CPAL"] = buildCPAL([[
        (1.0, 0.0, 0.0, 1.0), (0.0, 0.0, 1.0, 1.0), (0.0, 160 / 255, 0.0, 1.0), (1.0, 220 / 255, 0.0, 1.0),
    ]])
    fb.save(path)


def png_bytes(width, height, pixel):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    raw = b""
    for y in range(height):
        raw += b"\0" + b"".join(bytes(pixel(x, y, width, height)) for x in range(width))
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def quadrants(x, y, w, h):
    left = x < w // 2
    top = y < h // 2
    if top and left:
        return (255, 0, 0, 255)
    if top:
        return (0, 160, 0, 255)
    if left:
        return (0, 0, 255, 255)
    return (255, 220, 0, 128)


def sbix_font(path):
    fb = base_font("W Color Test sbix", "ABC")
    font = fb.font
    table = table__s_b_i_x()
    table.version = 1
    table.flags = 1
    for ppem in (16, 64):
        strike = SbixStrike(ppem=ppem, resolution=72)
        for name in font.getGlyphOrder():
            strike.glyphs[name] = SbixGlyph(glyphName=name, graphicType=None)
        size = ppem * 3 // 4
        strike.glyphs["A"] = SbixGlyph(glyphName="A", graphicType="png ", imageData=png_bytes(size, size, quadrants),
                                       originOffsetX=ppem // 16, originOffsetY=0)
        strike.glyphs["B"] = SbixGlyph(glyphName="B", graphicType="dupe", referenceGlyphName="A")
        table.strikes[ppem] = strike
    font["sbix"] = table
    fb.save(path)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "tests/data/fonts"
    colr_v0_font(os.path.join(out, "ColorTestCOLRv0.ttf"))
    colr_v1_font(os.path.join(out, "ColorTestCOLRv1.ttf"))
    sbix_font(os.path.join(out, "ColorTestSbix.ttf"))


if __name__ == "__main__":
    main()
