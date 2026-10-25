#!/usr/bin/env python3
"""Compare color glyphs from graphics.ui.font_color with HarfBuzz's hb-raster.

    pip install uharfbuzz        # 0.57 or newer (HarfBuzz with hb-raster)
    bin/wv2 tools/color_glyph_dump.w -o bin/color_glyph_dump
    python3 tools/color_glyph_compare_hb.py font.ttf ppem [text] [--out DIR]

Renders every color glyph the text maps to (default: every glyph of the
font with COLR data) with tools/color_glyph_dump.w and with
uharfbuzz.RasterPaint at the same size, aligns the two images on the pen
and baseline, and prints per glyph the largest channel difference, the
mean difference inside the reference image (HarfBuzz rounds its extents
inward, dropping partly covered edge rows), and the number of pixels off
by more than 32. --out writes each pair side by side (W left, reference
right) as PNGs. Foreground layers are opaque black in both. Exits
nonzero when a glyph's mean difference exceeds 4 (of 255) or more than
2% of its pixels are off by more than 32. A qualification aid for issue
#827; it is not part of the test suite.

hb-raster paints COLR only. CBDT and sbix bitmaps are compared with the
PNG and metrics fontTools reads from the font, at a size that is one of
the font's strikes, where neither side resamples.
"""
import os
import struct
import subprocess
import sys
import tempfile
import zlib

import uharfbuzz as hb


def read_png(path):
    return decode_png(open(path, "rb").read())


def decode_png(data):
    """8-bit gray, RGB, palette, gray-alpha or RGBA PNG to (w, h, RGBA)."""
    pos = 8
    idat = b""
    width = height = color = 0
    palette = b""
    alpha = b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", body[:10])
            if depth != 8 or body[12] != 0:
                raise ValueError("only 8-bit non-interlaced PNGs are supported")
        elif kind == b"PLTE":
            palette = body
        elif kind == b"tRNS":
            alpha = body
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    raw = zlib.decompress(idat)
    stride = width * channels
    prev = bytearray(stride)
    out = bytearray()
    for y in range(height):
        start = y * (stride + 1)
        kind = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            up = prev[i]
            corner = prev[i - channels] if i >= channels else 0
            if kind == 1:
                row[i] = (row[i] + left) & 255
            elif kind == 2:
                row[i] = (row[i] + up) & 255
            elif kind == 3:
                row[i] = (row[i] + (left + up) // 2) & 255
            elif kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                pred = left if pa <= pb and pa <= pc else (up if pb <= pc else corner)
                row[i] = (row[i] + pred) & 255
        prev = row
        for x in range(width):
            px = row[x * channels:(x + 1) * channels]
            if color == 0:
                out += bytes((px[0], px[0], px[0], 255))
            elif color == 2:
                out += bytes((px[0], px[1], px[2], 255))
            elif color == 3:
                i = px[0]
                out += palette[i * 3:i * 3 + 3] + bytes((alpha[i] if i < len(alpha) else 255,))
            elif color == 4:
                out += bytes((px[0], px[0], px[0], px[1]))
            else:
                out += bytes(px)
    return width, height, bytes(out)


def write_png(path, width, height, rgba):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    raw = b"".join(b"\0" + bytes(rgba[y * width * 4:(y + 1) * width * 4]) for y in range(height))
    with open(path, "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                  + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def hb_render(font, gid):
    """(left, top, width, height, straight RGBA) in y-down pixels, or None."""
    paint = hb.RasterPaint()
    paint.foreground = hb.Color(0, 0, 0, 255)
    paint.set_glyph_extents(font.get_glyph_extents(gid))
    if not paint.paint_glyph_or_fail(font, gid):
        return None
    image = paint.render()
    if image is None:
        return None
    e = image.extents
    data = bytes(image.buffer)
    rgba = bytearray(e.width * e.height * 4)
    for y in range(e.height):
        row = (e.height - 1 - y) * e.stride
        for x in range(e.width):
            b, g, r, a = data[row + x * 4:row + x * 4 + 4]
            if a:
                r, g, b = min(255, (r * 255 + a // 2) // a), min(255, (g * 255 + a // 2) // a), min(255, (b * 255 + a // 2) // a)
            rgba[(y * e.width + x) * 4:(y * e.width + x) * 4 + 4] = bytes((r, g, b, a))
    return e.x_origin, -(e.y_origin + e.height), e.width, e.height, bytes(rgba)


def bitmap_render(path, ppem, gid):
    """The CBDT or sbix PNG of gid in the strike of size ppem, placed by the
    font's metrics as fontTools reads them, as hb_render returns."""
    from fontTools.ttLib import TTFont
    font = TTFont(path)
    name = font.getGlyphName(gid)
    if "CBDT" in font:
        for strike_index, strike in enumerate(font["CBLC"].strikes):
            if strike.bitmapSizeTable.ppemY != ppem:
                continue
            data = font["CBDT"].strikeData[strike_index]
            if name not in data:
                continue
            glyph = data[name]
            glyph.decompile()
            m = glyph.metrics
            w, h, rgba = decode_png(glyph.imageData)
            return m.BearingX if hasattr(m, "BearingX") else m.horiBearingX, -(m.BearingY if hasattr(m, "BearingY") else m.horiBearingY), w, h, rgba
    if "sbix" in font:
        strike = font["sbix"].strikes.get(ppem)
        if strike is None or name not in strike.glyphs:
            return None
        glyph = strike.glyphs[name]
        if glyph.graphicType == "dupe":
            glyph = strike.glyphs[glyph.referenceGlyphName]
        if glyph.graphicType != "png ":
            return None
        w, h, rgba = decode_png(glyph.imageData)
        return glyph.originOffsetX, -(glyph.originOffsetY + h), w, h, rgba
    return None


def place(canvas, cw, ox, oy, img):
    left, top, w, h, rgba = img
    for y in range(h):
        for x in range(w):
            at = ((top - oy + y) * cw + left - ox + x) * 4
            canvas[at:at + 4] = rgba[(y * w + x) * 4:(y * w + x) * 4 + 4]


def premultiplied(px):
    a = px[3]
    return (px[0] * a // 255, px[1] * a // 255, px[2] * a // 255, a)


def main():
    args = [a for a in sys.argv[1:]]
    out_dir = None
    if "--out" in args:
        out_dir = args[args.index("--out") + 1]
        del args[args.index("--out"):args.index("--out") + 2]
    path, ppem = args[0], int(args[1])
    blob = hb.Blob.from_file_path(path)
    face = hb.Face(blob)
    font = hb.Font(face)
    font.scale = (ppem, ppem)
    if len(args) > 2:
        gids = sorted({font.get_nominal_glyph(ord(ch)) for ch in args[2]} - {None, 0})
    else:
        gids = [g for g in range(face.glyph_count) if face.glyph_has_color_paint(g) or face.get_glyph_color_layers(g)]
        if not gids:
            gids = [g for g in range(1, face.glyph_count) if len(font.get_glyph_color_png(g).data) > 0]
    tmp = tempfile.mkdtemp()
    dump = subprocess.run(["bin/color_glyph_dump", path, str(ppem), os.path.join(tmp, "g")] + [str(g) for g in gids],
                          check=True, capture_output=True, text=True).stdout.split("\n")
    failed = 0
    for line in dump:
        fields = line.split()
        if len(fields) < 7:
            if fields:
                print(f"gid {fields[0]}: W renders no color glyph")
                failed += 1
            continue
        gid, left, top, w, h = int(fields[0]), int(fields[2]), int(fields[3]), int(fields[4]), int(fields[5])
        mine = (left, top, w, h, read_png(os.path.join(tmp, f"g{gid}.png"))[2])
        theirs = hb_render(font, gid) or bitmap_render(path, ppem, gid)
        if theirs is None:
            print(f"gid {gid}: no reference renders a color glyph")
            continue
        ox = min(mine[0], theirs[0])
        oy = min(mine[1], theirs[1])
        cw = max(mine[0] + mine[2], theirs[0] + theirs[2]) - ox
        ch = max(mine[1] + mine[3], theirs[1] + theirs[3]) - oy
        a = bytearray(cw * ch * 4)
        b = bytearray(cw * ch * 4)
        place(a, cw, ox, oy, mine)
        place(b, cw, ox, oy, theirs)
        worst = 0
        total = 0
        off = 0
        # HarfBuzz rounds its image extents inward, dropping partly
        # covered edge rows; compare inside its image only.
        count = theirs[2] * theirs[3]
        for y in range(theirs[1] - oy, theirs[1] - oy + theirs[3]):
            for x in range(theirs[0] - ox, theirs[0] - ox + theirs[2]):
                i = y * cw + x
                pa = premultiplied(a[i * 4:i * 4 + 4])
                pb = premultiplied(b[i * 4:i * 4 + 4])
                d = max(abs(pa[k] - pb[k]) for k in range(4))
                worst = max(worst, d)
                total += d
                if d > 32:
                    off += 1
        mean = total / max(1, count)
        bad = mean > 4 or off > 0.02 * count
        failed += bad
        print(f"gid {gid}: max {worst} mean {mean:.2f} off>32 {off}/{count}{'  DIFFERS' if bad else ''}")
        if out_dir:
            pair = bytearray(cw * 2 * ch * 4)
            for y in range(ch):
                pair[y * cw * 8:y * cw * 8 + cw * 4] = a[y * cw * 4:(y + 1) * cw * 4]
                pair[y * cw * 8 + cw * 4:(y + 1) * cw * 8] = b[y * cw * 4:(y + 1) * cw * 4]
            write_png(os.path.join(out_dir, f"gid{gid}.png"), cw * 2, ch, pair)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
