# Unit tests for lib/ttf.w against the committed Liberation Sans
# faces (tools/ui/*.ttf, SIL OFL 1.1 — see the LICENSE alongside):
# table indexing, cmap format-4 and format-12 lookup, advances,
# decoration metrics, composite and skewed outlines, in-memory loading,
# rejection of truncated input, and rasterized coverage with
# antialiased edges. Runs from the repo root like every
# data-file test.
import lib.testing
import lib.ttf


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


void test_decoration_metrics():
	ttf_font* f = regular()
	# post: underlinePosition -67, underlineThickness 150; OS/2:
	# yStrikeoutPosition 530, yStrikeoutSize 102.
	assert_equal(0 - 67, f.underline_pos)
	assert_equal(150, f.underline_thick)
	assert_equal(530, f.strike_pos)
	assert_equal(102, f.strike_thick)
	# At 16 ppem: underline one row below the baseline, one pixel
	# thick; strikeout four rows above it (mid x-height).
	assert_equal(1, ttf_underline_top(f, 16))
	assert_equal(1, ttf_underline_thickness(f, 16))
	assert_equal(0 - 4, ttf_strikeout_top(f, 16))
	assert_equal(1, ttf_strikeout_thickness(f, 16))


# Latin-1 accented letters are composites in Liberation Sans: the base
# letter plus an offset accent glyph.
void test_composite_glyph_rasterizes():
	ttf_font* f = regular()
	int gid = ttf_glyph_id(f, 233)
	asserts(c"e-acute is a composite", ttf_s16(f, f.glyf + ttf_glyf_offset(f, gid)) < 0)
	ttf_bitmap accented
	asserts(c"rasterize e-acute", ttf_rasterize(f, gid, 16, &accented))
	ttf_bitmap plain
	asserts(c"rasterize e", ttf_rasterize(f, ttf_glyph_id(f, 'e'), 16, &plain))
	# Same base letter, same advance; the accent adds ink above it.
	assert_equal(plain.advance, accented.advance)
	asserts(c"accent reaches higher", accented.bearing_top > plain.bearing_top + 2)
	asserts(c"accent adds rows", accented.h > plain.h + 2)
	free(accented.pixels)
	free(plain.pixels)
	int code = 192
	while (code <= 255):
		if ((code != 215) && (code != 247)):
			ttf_bitmap bm
			asserts(c"latin-1 rasterizes", ttf_rasterize(f, ttf_glyph_id(f, code), 16, &bm))
			if (bm.pixels != 0):
				free(bm.pixels)
		code = code + 1


# An oblique rasterization leans the ink right: the tall 'l' gets
# wider, while the advance (layout) is unchanged.
void test_skewed_rasterize_leans():
	ttf_font* f = regular()
	int gid = ttf_glyph_id(f, 'l')
	ttf_bitmap upright
	asserts(c"upright l", ttf_rasterize(f, gid, 16, &upright))
	ttf_bitmap leaned
	asserts(c"oblique l", ttf_rasterize_skewed(f, gid, 16, 0.25, &leaned))
	assert_equal(upright.advance, leaned.advance)
	assert_equal(upright.bearing_top, leaned.bearing_top)
	asserts(c"lean widens the ink", leaned.w >= upright.w + 2)
	free(upright.pixels)
	free(leaned.pixels)


void test_load_bytes_matches_load():
	int size = 0
	char* data = ttf_read_file(c"tools/ui/LiberationSans-Regular.ttf", &size)
	asserts(c"read font file", data != 0)
	ttf_font mem
	asserts(c"load from bytes", ttf_load_bytes(&mem, data, size))
	ttf_font* f = regular()
	assert_equal(f.glyph_count, mem.glyph_count)
	assert_equal(ttf_glyph_id(f, 'Q'), ttf_glyph_id(&mem, 'Q'))
	free(data)


# Truncated or foreign bytes fail to load instead of reading past the
# end of the blob.
void test_bad_input_is_rejected():
	int size = 0
	char* data = ttf_read_file(c"tools/ui/LiberationSans-Regular.ttf", &size)
	ttf_font cut
	asserts(c"header-only font rejected", ttf_load_bytes(&cut, data, 200) == 0)
	asserts(c"tiny blob rejected", ttf_load_bytes(&cut, data, 8) == 0)
	char* junk = malloc(64)
	int i = 0
	while (i < 64):
		junk[i] = 'x'
		i = i + 1
	asserts(c"non-font rejected", ttf_load_bytes(&cut, junk, 64) == 0)
	free(junk)
	free(data)
	ttf_font missing
	asserts(c"missing file rejected", ttf_load(&missing, c"tools/ui/no-such-font.ttf") == 0)


void put_u16(char* p, int off, int v):
	p[off] = (v >> 8) & 255
	p[off + 1] = v & 255


void put_u32(char* p, int off, int v):
	put_u16(p, off, (v >> 16) & 65535)
	put_u16(p, off + 2, v & 65535)


# Format 12 (full Unicode) groups, over a hand-built subtable: one
# group mapping U+1F600..U+1F602 to glyphs 50..52.
void test_cmap_format_12():
	# The subtable sits at offset 4: offset 0 means "absent".
	char* data = malloc(32)
	put_u32(data, 0, 0)
	put_u16(data, 4, 12)
	put_u16(data, 6, 0)
	put_u32(data, 8, 28)
	put_u32(data, 12, 0)
	put_u32(data, 16, 1)
	put_u32(data, 20, 128512)
	put_u32(data, 24, 128514)
	put_u32(data, 28, 50)
	ttf_font f
	f.data = data
	f.size = 32
	f.cmap4 = 0
	f.cmap12 = 4
	assert_equal(50, ttf_glyph_id(&f, 128512))
	assert_equal(51, ttf_glyph_id(&f, 128513))
	assert_equal(52, ttf_glyph_id(&f, 128514))
	assert_equal(0, ttf_glyph_id(&f, 128515))
	assert_equal(0, ttf_glyph_id(&f, 'A'))
	free(data)
