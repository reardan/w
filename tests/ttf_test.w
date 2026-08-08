# Unit tests for tools/ttf.w against the committed Liberation Sans
# faces (tools/ui/*.ttf, SIL OFL 1.1 — see the LICENSE alongside):
# table indexing, cmap format-4 lookup, advances, and rasterized
# coverage with antialiased edges. Runs from the repo root like every
# data-file test.
import lib.testing
import tools.ttf


ttf_font ttf_test_font
int ttf_test_loaded


ttf_font* regular():
	if (ttf_test_loaded == 0):
		asserts(c"load regular", ttf_load(&ttf_test_font, c"tools/ui/LiberationSans-Regular.ttf"))
		ttf_test_loaded = 1
	return &ttf_test_font


void test_font_header():
	ttf_font* f = regular()
	assert_equal(2048, f.upem)
	assert_equal(2620, f.glyph_count)
	# hhea ascender/descender: 1854 / -434 (descent stored positive).
	assert_equal(1854, f.ascent)
	assert_equal(434, f.descent)


void test_cmap_lookup():
	ttf_font* f = regular()
	# Values cross-checked against an independent reader.
	assert_equal(36, ttf_glyph_id(f, 'A'))
	assert_equal(3, ttf_glyph_id(f, ' '))
	assert_equal(76, ttf_glyph_id(f, 'i'))
	# Unmapped codepoint falls to .notdef.
	assert_equal(0, ttf_glyph_id(f, 1))


void test_advances():
	ttf_font* f = regular()
	# 'A' is 1366 units; at ppem 16 that rounds to 11 px.
	assert_equal(1366, ttf_advance_units(f, ttf_glyph_id(f, 'A')))
	assert_equal(11, ttf_scale_round(f, 16, 1366))
	# Rounding is half-up in both directions.
	assert_equal(4, ttf_scale_round(f, 16, 455))
	assert_equal(0 - 4, ttf_scale_round(f, 16, 0 - 455))


void test_rasterize_a():
	ttf_font* f = regular()
	ttf_bitmap bm
	asserts(c"rasterize A", ttf_rasterize(f, ttf_glyph_id(f, 'A'), 16, &bm))
	asserts(c"A width plausible", (bm.w >= 10) && (bm.w <= 16))
	asserts(c"A height plausible", (bm.h >= 11) && (bm.h <= 16))
	# Cap height: 1409 units -> 11 px above the baseline (plus AA pad).
	asserts(c"A sits on the baseline", (bm.bearing_top >= 11) && (bm.bearing_top <= 13))
	int solid = 0
	int partial = 0
	int i = 0
	while (i < bm.w * bm.h):
		int v = bm.pixels[i] & 255
		if (v == 255):
			solid = solid + 1
		else if ((v > 0) && (v < 255)):
			partial = partial + 1
		i = i + 1
	asserts(c"A has solid ink", solid > 0)
	asserts(c"A has antialiased edges", partial > 0)
	free(bm.pixels)


void test_rasterize_space_is_empty():
	ttf_font* f = regular()
	ttf_bitmap bm
	asserts(c"rasterize space", ttf_rasterize(f, ttf_glyph_id(f, ' '), 16, &bm))
	assert_equal(0, bm.w)
	assert_equal(0, bm.h)
	# Space still advances: 569 units -> 4 px.
	assert_equal(4, bm.advance)


void test_every_ascii_glyph_rasterizes():
	ttf_font* f = regular()
	int ch = 33
	while (ch <= 126):
		ttf_bitmap bm
		asserts(c"ascii rasterizes", ttf_rasterize(f, ttf_glyph_id(f, ch), 16, &bm))
		asserts(c"ascii has ink", bm.w > 0)
		asserts(c"ascii bitmap sane", (bm.w <= 24) && (bm.h <= 24))
		free(bm.pixels)
		ch = ch + 1


void test_bold_face_loads_and_is_wider():
	ttf_font bold
	asserts(c"load bold", ttf_load(&bold, c"tools/ui/LiberationSans-Bold.ttf"))
	ttf_font* f = regular()
	int gid_regular = ttf_glyph_id(f, 'a')
	int gid_bold = ttf_glyph_id(&bold, 'a')
	asserts(c"bold a is at least as wide", ttf_advance_units(&bold, gid_bold) >= ttf_advance_units(f, gid_regular))
