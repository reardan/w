# wbuild: name=graphics_ui_font_color_test x64 deps=tests/data/fonts/
# Color glyph tables (graphics.ui.font_color, issue #827): COLR/CPAL
# version 0 layers, the version 1 paint graph, CBDT/CBLC and sbix
# bitmaps with strike choice and resampling, and robustness against
# corrupt tables and paint cycles. The fixtures are the fonts
# tools/make_color_test_fonts.py builds and a Noto Color Emoji subset;
# expected colors follow from those scripts' shapes and palettes (and
# match HarfBuzz's hb-raster, tools/color_glyph_compare_hb.py).
import lib.testing
import lib.emoji
import graphics.ui.font_color


ttf_font* load_font(char* path):
	ttf_font* font = cast(ttf_font*, malloc(sizeof(ttf_font)))
	asserts(path, ttf_load(font, path))
	return font


ttf_color_font* color_font(char* path):
	ttf_color_font* cf = cast(ttf_color_font*, malloc(sizeof(ttf_color_font)))
	asserts(c"color tables found", ttf_color_init(cf, load_font(path)))
	return cf


int glyph_of(ttf_color_font* cf, int cp):
	int gid = ttf_glyph_id(cf.font, cp)
	asserts(c"glyph mapped", gid != 0)
	return gid


# The RGBA (or coverage, as gray) pixel of part at font-unit point
# (fx, fy), packed 0xRRGGBBAA-style into out[0..3]; 0 outside the part.
int sample(ttf_color_font* cf, int ppem, ttf_color_part* part, int fx, int fy, int* out):
	for k in range(4): out[k] = 0
	int x = ttf_floor(cast(float32, fx * ppem) / cast(float32, cf.font.upem)) - part.bearing_x
	int y = ttf_floor(cast(float32, 0 - fy * ppem) / cast(float32, cf.font.upem)) + part.bearing_top
	if ((x < 0) || (y < 0) || (x >= part.w) || (y >= part.h)): return 0
	if (part.foreground):
		int c = part.pixels[y * part.w + x] & 255
		for k in range(4): out[k] = c
		return 1
	for k in range(4): out[k] = part.pixels[(y * part.w + x) * 4 + k] & 255
	return 1


void expect_color(ttf_color_font* cf, int ppem, ttf_color_part* part, int fx, int fy, int r, int g, int b, int a):
	int[4] got
	sample(cf, ppem, part, fx, fy, &got[0])
	int[4] want
	want[0] = r
	want[1] = g
	want[2] = b
	want[3] = a
	for k in range(4):
		int d = got[k] - want[k]
		if ((d < -4) || (d > 4)):
			print_error(c"pixel at ")
			print_error(itoa(fx))
			print_error(c",")
			print_error(itoa(fy))
			print_error(c" channel ")
			print_error(itoa(k))
			print_error(c": want ")
			print_error(itoa(want[k]))
			print_error(c", got ")
			print_error(itoa(got[k]))
			print_error(c"\n")
			asserts(c"color matches", 0)


void test_detects_tables():
	ttf_color_font* v0 = color_font(c"tests/data/fonts/ColorTestCOLRv0.ttf")
	assert_equal(0, v0.colr_version)
	assert_equal(TTF_COLOR_COLRV0, ttf_color_glyph_kind(v0, glyph_of(v0, 'A')))
	assert_equal(TTF_COLOR_COLRV0, ttf_color_glyph_kind(v0, glyph_of(v0, 'B')))
	assert_equal(TTF_COLOR_NONE, ttf_color_glyph_kind(v0, glyph_of(v0, 'C')))
	assert_equal(TTF_COLOR_NONE, ttf_color_glyph_kind(v0, 0))
	assert_equal(TTF_COLOR_NONE, ttf_color_glyph_kind(v0, 9999))
	ttf_color_font* v1 = color_font(c"tests/data/fonts/ColorTestCOLRv1.ttf")
	assert_equal(1, v1.colr_version)
	for c in range('A', 'H'): assert_equal(TTF_COLOR_COLRV1, ttf_color_glyph_kind(v1, glyph_of(v1, c)))
	assert_equal(TTF_COLOR_COLRV0, ttf_color_glyph_kind(v1, glyph_of(v1, 'H')))
	ttf_color_font* sbix = color_font(c"tests/data/fonts/ColorTestSbix.ttf")
	assert_equal(TTF_COLOR_SBIX, ttf_color_glyph_kind(sbix, glyph_of(sbix, 'A')))
	assert_equal(TTF_COLOR_SBIX, ttf_color_glyph_kind(sbix, glyph_of(sbix, 'B')))
	assert_equal(TTF_COLOR_NONE, ttf_color_glyph_kind(sbix, glyph_of(sbix, 'C')))
	ttf_color_font* emoji = color_font(c"tests/data/fonts/NotoColorEmoji-subset.ttf")
	assert_equal(TTF_COLOR_CBDT, ttf_color_glyph_kind(emoji, glyph_of(emoji, 0x1f600)))
	assert1(ttf_color_present(emoji))
	# A font without color tables.
	ttf_color_font plain
	assert_equal(0, ttf_color_init(&plain, load_font(c"tests/data/fonts/NotoSans-subset.ttf")))
	ttf_color_glyph g
	assert_equal(0, ttf_color_render(&plain, 1, 20, &g))
	assert_equal(0, g.count)


void test_colr_v0_layers():
	ttf_color_font* cf = color_font(c"tests/data/fonts/ColorTestCOLRv0.ttf")
	ttf_color_glyph g
	assert1(ttf_color_render(cf, glyph_of(cf, 'A'), 50, &g))
	assert_equal(TTF_COLOR_COLRV0, g.kind)
	assert_equal(50, g.advance)
	# The square and circle composite into one RGBA part; the triangle
	# (palette 0xFFFF) is a foreground mask after it.
	assert_equal(2, g.count)
	assert_equal(0, g.parts[0].foreground)
	assert_equal(1, g.parts[1].foreground)
	ttf_color_part* layers = &g.parts[0]
	expect_color(cf, 50, layers, 150, 50, 255, 0, 0, 255)
	# Half-transparent blue over red.
	expect_color(cf, 50, layers, 500, 400, 128, 0, 127, 255)
	# Inside the circle above the square: blue at half alpha.
	expect_color(cf, 50, layers, 500, 650, 0, 0, 255, 128)
	expect_color(cf, 50, layers, 760, 60, 0, 0, 0, 0)
	ttf_color_part* fg = &g.parts[1]
	expect_color(cf, 50, fg, 500, 300, 255, 255, 255, 255)
	expect_color(cf, 50, fg, 160, 700, 0, 0, 0, 0)
	ttf_color_glyph_free(&g)
	assert_equal(0, g.count)
	# B: one green layer, then the foreground bar.
	assert1(ttf_color_render(cf, glyph_of(cf, 'B'), 50, &g))
	assert_equal(2, g.count)
	expect_color(cf, 50, &g.parts[0], 500, 400, 0, 160, 0, 255)
	ttf_color_glyph_free(&g)
	# C has no color record.
	assert_equal(0, ttf_color_render(cf, glyph_of(cf, 'C'), 50, &g))


void test_colr_v1_paints():
	ttf_color_font* cf = color_font(c"tests/data/fonts/ColorTestCOLRv1.ttf")
	ttf_color_glyph g
	int ppem = 64
	# A: a linear gradient red -> blue over x 100..700 (clipped to its
	# ClipBox), under a half-transparent green circle.
	assert1(ttf_color_render(cf, glyph_of(cf, 'A'), ppem, &g))
	assert_equal(TTF_COLOR_COLRV1, g.kind)
	assert_equal(1, g.count)
	expect_color(cf, ppem, &g.parts[0], 150, 50, 234, 0, 21, 255)
	expect_color(cf, ppem, &g.parts[0], 680, 50, 8, 0, 247, 255)
	expect_color(cf, ppem, &g.parts[0], 500, 400, 41, 80, 87, 255)
	ttf_color_glyph_free(&g)
	# B: radial, yellow at the center to green at r = 100, reflected.
	# Pixels sample at their centers: (500, 400) reads (507.8, 398.4),
	# r = 8; (600, 400) r = 101.6, reflected back to 98.4; (650, 400)
	# r = 148.4, reflected to 51.6.
	assert1(ttf_color_render(cf, glyph_of(cf, 'B'), ppem, &g))
	expect_color(cf, ppem, &g.parts[0], 500, 400, 235, 215, 0, 255)
	expect_color(cf, ppem, &g.parts[0], 600, 400, 4, 161, 0, 255)
	expect_color(cf, ppem, &g.parts[0], 650, 400, 123, 189, 0, 255)
	ttf_color_glyph_free(&g)
	# C: sweep about (400, 300), red at 0 degrees, blue at 90, repeating
	# every 180: 1.3 degrees, 90.4 and 269.6 (repeated to 89.6).
	assert1(ttf_color_render(cf, glyph_of(cf, 'C'), ppem, &g))
	expect_color(cf, ppem, &g.parts[0], 600, 305, 251, 0, 4, 255)
	expect_color(cf, ppem, &g.parts[0], 403, 550, 1, 0, 254, 255)
	expect_color(cf, ppem, &g.parts[0], 397, 50, 1, 0, 254, 255)
	ttf_color_glyph_free(&g)
	# D: the square turned 45 degrees about its center, and a circle
	# scaled by half and moved to (350, 300).
	assert1(ttf_color_render(cf, glyph_of(cf, 'D'), ppem, &g))
	expect_color(cf, ppem, &g.parts[0], 400, 680, 255, 0, 0, 255)
	expect_color(cf, ppem, &g.parts[0], 120, 20, 0, 0, 0, 0)
	expect_color(cf, ppem, &g.parts[0], 350, 300, 0, 0, 255, 255)
	ttf_color_glyph_free(&g)
	# E: SRC_IN keeps the circle only where the square is.
	assert1(ttf_color_render(cf, glyph_of(cf, 'E'), ppem, &g))
	expect_color(cf, ppem, &g.parts[0], 500, 400, 0, 0, 255, 255)
	expect_color(cf, ppem, &g.parts[0], 150, 50, 0, 0, 0, 0)
	ttf_color_glyph_free(&g)
	# F: PaintColrGlyph reuse, skew and an affine transform.
	assert1(ttf_color_render(cf, glyph_of(cf, 'F'), ppem, &g))
	asserts(c"F paints", (g.count == 1) && (g.parts[0].w > 40))
	ttf_color_glyph_free(&g)
	# G: red square, then the foreground bar as its own part, then a
	# multiply composite (yellow times blue is black).
	assert1(ttf_color_render(cf, glyph_of(cf, 'G'), ppem, &g))
	assert_equal(3, g.count)
	assert_equal(0, g.parts[0].foreground)
	assert_equal(1, g.parts[1].foreground)
	assert_equal(0, g.parts[2].foreground)
	expect_color(cf, ppem, &g.parts[0], 150, 50, 255, 0, 0, 255)
	expect_color(cf, ppem, &g.parts[1], 500, 300, 255, 255, 255, 255)
	expect_color(cf, ppem, &g.parts[2], 500, 400, 0, 0, 0, 255)
	ttf_color_glyph_free(&g)
	# H: version 0 layers in a version 1 table.
	assert1(ttf_color_render(cf, glyph_of(cf, 'H'), ppem, &g))
	assert_equal(TTF_COLOR_COLRV0, g.kind)
	expect_color(cf, ppem, &g.parts[0], 500, 300, 255, 0, 0, 255)
	expect_color(cf, ppem, &g.parts[0], 500, 700, 0, 160, 0, 255)
	ttf_color_glyph_free(&g)


void test_composite_modes():
	# Every PaintComposite mode on one opaque and one translucent pixel
	# (premultiplied): Porter-Duff results exactly, blend modes in range.
	float32[4] dst
	float32[4] src
	for mode in range(28):
		dst[0] = 0.5
		dst[1] = 0.25
		dst[2] = 0.0
		dst[3] = 0.5
		src[0] = 0.0
		src[1] = 0.5
		src[2] = 1.0
		src[3] = 1.0
		ttf_color_composite(&dst[0], &src[0], 1, mode)
		for k in range(4): asserts(c"composite in range", (dst[k] >= 0.0) && (dst[k] <= 1.0001))
		if (mode == 0): assert_near(0.0, dst[3])
		if (mode == 1): assert_near(1.0, dst[2])
		if (mode == 2): assert_near(0.5, dst[0])
		if (mode == 3): assert_near(1.0, dst[2])
		if (mode == 4): assert_near(1.0, dst[0] + dst[2])
		if (mode == 5): assert_near(0.5, dst[3])
		if (mode == 8): assert_near(0.0, dst[3])
		if (mode >= 13): assert_near(1.0, dst[3])
	# Multiply of opaque colors multiplies them.
	dst[0] = 1.0
	dst[1] = 0.5
	dst[2] = 0.0
	dst[3] = 1.0
	src[0] = 0.5
	src[1] = 0.5
	src[2] = 1.0
	src[3] = 1.0
	ttf_color_composite(&dst[0], &src[0], 1, 23)
	assert_near(0.5, dst[0])
	assert_near(0.25, dst[1])
	assert_near(0.0, dst[2])


void test_sbix_strikes():
	ttf_color_font* cf = color_font(c"tests/data/fonts/ColorTestSbix.ttf")
	ttf_color_glyph g
	int a = glyph_of(cf, 'A')
	# At a strike's own size: the 12 x 12 PNG as is, its bottom-left
	# corner at the origin offset (1, 0).
	assert1(ttf_color_render(cf, a, 16, &g))
	assert_equal(TTF_COLOR_SBIX, g.kind)
	assert_equal(1, g.count)
	ttf_color_part* p = &g.parts[0]
	assert_equal(12, p.w)
	assert_equal(12, p.h)
	assert_equal(1, p.bearing_x)
	assert_equal(12, p.bearing_top)
	assert_equal(16, g.advance)
	assert_equal(255, p.pixels[0] & 255)
	assert_equal(160, p.pixels[11 * 4 + 1] & 255)
	assert_equal(255, p.pixels[11 * 12 * 4 + 2] & 255)
	assert_equal(128, p.pixels[(11 * 12 + 11) * 4 + 3] & 255)
	ttf_color_glyph_free(&g)
	# Between strikes the larger one is scaled down: 48 px at 64 ppem to
	# 30 px at 40.
	assert1(ttf_color_render(cf, a, 40, &g))
	assert_equal(30, g.parts[0].w)
	assert_equal(30, g.parts[0].h)
	assert_equal(3, g.parts[0].bearing_x)
	assert_equal(30, g.parts[0].bearing_top)
	assert_equal(255, g.parts[0].pixels[0] & 255)
	ttf_color_glyph_free(&g)
	# Above the largest strike, it is scaled up.
	assert1(ttf_color_render(cf, a, 100, &g))
	assert_equal(75, g.parts[0].w)
	ttf_color_glyph_free(&g)
	# 'dupe' draws A's image; C has no bitmap.
	assert1(ttf_color_render(cf, glyph_of(cf, 'B'), 16, &g))
	assert_equal(12, g.parts[0].w)
	assert_equal(255, g.parts[0].pixels[0] & 255)
	ttf_color_glyph_free(&g)
	assert_equal(0, ttf_color_render(cf, glyph_of(cf, 'C'), 16, &g))


void test_cbdt_bitmaps():
	ttf_color_font* cf = color_font(c"tests/data/fonts/NotoColorEmoji-subset.ttf")
	ttf_color_glyph g
	int smile = glyph_of(cf, 0x1f600)
	# The 109 ppem strike as stored: 136 x 128, its top 101 rows above
	# the baseline.
	assert1(ttf_color_render(cf, smile, 109, &g))
	assert_equal(TTF_COLOR_CBDT, g.kind)
	assert_equal(136, g.parts[0].w)
	assert_equal(128, g.parts[0].h)
	assert_equal(101, g.parts[0].bearing_top)
	assert_equal(136, g.advance)
	ttf_color_glyph_free(&g)
	# Scaled to 20 ppem.
	assert1(ttf_color_render(cf, smile, 20, &g))
	ttf_color_part* p = &g.parts[0]
	assert_equal(25, p.w)
	assert_equal(23, p.h)
	assert_equal(19, p.bearing_top)
	assert_equal(25, g.advance)
	# Transparent corner, opaque middle.
	assert_equal(0, p.pixels[3] & 255)
	assert_equal(255, p.pixels[(11 * p.w + 12) * 4 + 3] & 255)
	ttf_color_glyph_free(&g)
	# The bitmap-only font loads; its glyphs have no outline.
	ttf_bitmap bm
	assert1(ttf_rasterize(cf.font, smile, 20, &bm))
	assert_equal(0, bm.w)
	assert_equal(25, bm.advance)


# Overwrite the bytes of table tag in a copy of font with a pattern
# derived from seed; render every glyph. Nothing may crash.
void scramble_and_render(char* path, char* tag, int seed):
	ttf_font* font = load_font(path)
	int at = ttf_table(font, tag)
	int length = ttf_table_length(font, tag)
	asserts(tag, at != 0)
	char* copy = cast(char*, malloc(font.size))
	for i in range(font.size): copy[i] = font.data[i]
	int state = seed
	for i in range(length):
		state = (state * 1103515245 + 12345) & 0x7fffffff
		if ((state >> 16) % 7 == 0): copy[at + i] = state >> 8
	ttf_font scrambled
	if (!ttf_load_bytes(&scrambled, copy, font.size)): return
	ttf_color_font cf
	ttf_color_init(&cf, &scrambled)
	for gid in range(scrambled.glyph_count):
		ttf_color_glyph g
		if (ttf_color_render(&cf, gid, 24, &g)): ttf_color_glyph_free(&g)
	free(copy)


void test_corrupt_tables_do_not_crash():
	for seed in range(1, 9):
		scramble_and_render(c"tests/data/fonts/ColorTestCOLRv1.ttf", c"COLR", seed)
		scramble_and_render(c"tests/data/fonts/ColorTestCOLRv0.ttf", c"COLR", seed)
		scramble_and_render(c"tests/data/fonts/ColorTestCOLRv1.ttf", c"CPAL", seed)
		scramble_and_render(c"tests/data/fonts/ColorTestSbix.ttf", c"sbix", seed)
		scramble_and_render(c"tests/data/fonts/NotoColorEmoji-subset.ttf", c"CBLC", seed)


void test_paint_cycle_falls_back():
	# Point F's PaintColrGlyph (format 11, glyph A) at F itself: the
	# depth limit stops the cycle and F falls back to its outline.
	ttf_font* font = load_font(c"tests/data/fonts/ColorTestCOLRv1.ttf")
	int f = ttf_glyph_id(font, 'F')
	int a = ttf_glyph_id(font, 'A')
	int colr = ttf_table(font, c"COLR")
	int length = ttf_table_length(font, c"COLR")
	int patched = 0
	for i in range(length - 2):
		int at = colr + i
		if ((ttf_u8(font, at) == 11) && (ttf_u16(font, at + 1) == a)):
			font.data[at + 2] = f
			patched = patched + 1
	assert_equal(1, patched)
	ttf_color_font cf
	ttf_color_init(&cf, font)
	ttf_color_glyph g
	assert_equal(0, ttf_color_render(&cf, f, 32, &g))
	assert_equal(0, g.count)
	# The other glyphs still render.
	assert1(ttf_color_render(&cf, a, 32, &g))
	ttf_color_glyph_free(&g)


void test_emoji_presentation():
	assert1(emoji_is_presentation(0x1f600))
	assert1(emoji_is_presentation(0x231a))
	assert1(emoji_is_presentation(0x1faf8))
	assert1(emoji_is_presentation(0x1f3fd))
	assert_equal(0, emoji_is_presentation(0x2764))
	assert_equal(0, emoji_is_presentation('A'))
	assert_equal(0, emoji_is_presentation(0x1faf9))
	assert_equal(0, emoji_is_presentation(0x2319))
	# Heavy black heart: text by default, emoji with VS16.
	assert_equal(EMOJI_PRESENTATION_NONE, emoji_presentation_utf8(c"\xe2\x9d\xa4", 0, 3))
	assert_equal(EMOJI_PRESENTATION_EMOJI, emoji_presentation_utf8(c"\xe2\x9d\xa4\xef\xb8\x8f", 0, 6))
	# A grinning face with VS15 asks for text.
	assert_equal(EMOJI_PRESENTATION_TEXT, emoji_presentation_utf8(c"\xf0\x9f\x98\x80\xef\xb8\x8e", 0, 7))
	assert_equal(EMOJI_PRESENTATION_EMOJI, emoji_presentation_utf8(c"\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd", 0, 8))
	assert_equal(EMOJI_PRESENTATION_NONE, emoji_presentation_utf8(c"ab", 0, 2))
