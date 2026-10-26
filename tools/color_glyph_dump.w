# Render color glyphs with graphics.ui.font_color and write each as a PNG,
# for comparison with another renderer:
#   bin/color_glyph_dump font.ttf ppem out_prefix gid...
# Writes <out_prefix><gid>.png (the parts composited in paint order,
# foreground layers in opaque black) and prints one line per glyph:
# "gid kind left top width height parts", with left/top the image's
# top-left corner in y-down pixels from the pen on the baseline, or
# "gid none" when the glyph has no color data.
# tools/color_glyph_compare_hb.py runs this against HarfBuzz's hb-raster.
import lib.lib
import lib.stream
import lib.ttf
import structures.string
import graphics.image.png
import graphics.ui.font_color


void dump_over(char* dst, int i, int r, int g, int b, int a):
	float32 sa = cast(float32, a) / 255.0
	float32 da = cast(float32, dst[i * 4 + 3] & 255) / 255.0
	float32 oa = sa + da * (1.0 - sa)
	if (oa <= 0.0): return
	for k in range(3):
		int sc = r
		if (k == 1): sc = g
		if (k == 2): sc = b
		float32 v = (cast(float32, sc) * sa + cast(float32, dst[i * 4 + k] & 255) * da * (1.0 - sa)) / oa
		dst[i * 4 + k] = cast(int, v + 0.5)
	dst[i * 4 + 3] = cast(int, oa * 255.0 + 0.5)


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc < 5):
		println2(c"usage: color_glyph_dump font.ttf ppem out_prefix gid...")
		return 2
	ttf_font font
	if (!ttf_load(&font, args[1])): return 2
	ttf_color_font cf
	ttf_color_init(&cf, &font)
	int ppem = atoi(args[2])
	for a in range(4, argc):
		int gid = atoi(args[a])
		ttf_color_glyph g
		print(itoa(gid))
		if (!ttf_color_render(&cf, gid, ppem, &g)):
			println(c" none")
			continue
		int left = 0
		int top = 0
		int right = 0
		int bottom = 0
		for i in range(g.count):
			ttf_color_part* p = &g.parts[i]
			if ((i == 0) || (p.bearing_x < left)): left = p.bearing_x
			if ((i == 0) || (0 - p.bearing_top < top)): top = 0 - p.bearing_top
			if ((i == 0) || (p.bearing_x + p.w > right)): right = p.bearing_x + p.w
			if ((i == 0) || (p.h - p.bearing_top > bottom)): bottom = p.h - p.bearing_top
		int w = right - left
		int h = bottom - top
		print(c" ")
		print(itoa(g.kind))
		print(c" ")
		print(itoa(left))
		print(c" ")
		print(itoa(top))
		print(c" ")
		print(itoa(w))
		print(c" ")
		print(itoa(h))
		print(c" ")
		print(itoa(g.count))
		println(c"")
		if ((w <= 0) || (h <= 0)):
			ttf_color_glyph_free(&g)
			continue
		char* canvas = cast(char*, malloc(w * h * 4))
		for i in range(w * h * 4): canvas[i] = 0
		for i in range(g.count):
			ttf_color_part* p = &g.parts[i]
			for y in range(p.h):
				for x in range(p.w):
					int at = (0 - p.bearing_top + y - top) * w + p.bearing_x + x - left
					if (p.foreground): dump_over(canvas, at, 0, 0, 0, p.pixels[y * p.w + x] & 255)
					else:
						char* s = &p.pixels[(y * p.w + x) * 4]
						dump_over(canvas, at, s[0] & 255, s[1] & 255, s[2] & 255, s[3] & 255)
		string_builder* png = png_encode_rgba(w, h, canvas)
		string_builder* path = string_new()
		string_append(path, args[3])
		string_append_int(path, gid)
		string_append(path, c".png")
		wstream* out = stream_open_write(path.data)
		if (out != 0):
			stream_write(out, png.data, png.length)
			stream_close(out)
		string_free(path)
		string_free(png)
		free(canvas)
		ttf_color_glyph_free(&g)
	return 0
