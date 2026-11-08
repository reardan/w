# wbuild: target=wfuzz_font_smoke tag=tests dep=wfuzz data=tests/data/fonts/NotoSans-subset.ttf data=tests/data/fonts/NotoSans-cff-subset.otf data=tests/data/fonts/NotoSansJP-subset.otf data=tests/data/fonts/NotoSansThai-subset.ttf data=tests/data/fonts/NotoSansGujarati-nogdef-subset.ttf data=tests/data/fonts/ColorTestCOLRv0.ttf data=tests/data/fonts/ColorTestCOLRv1.ttf data=tests/data/fonts/ColorTestSbix.ttf data=tools/fuzz/regressions/font/
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_font.w -o bin/wfuzz_font_harness"
# wbuild: step="rm -rf bin/wfuzz_font_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_font_harness --bytes --ext .ttf --corpus tests/data/fonts/NotoSans-subset.ttf --corpus tests/data/fonts/NotoSans-cff-subset.otf --corpus tests/data/fonts/NotoSansJP-subset.otf --corpus tests/data/fonts/NotoSansThai-subset.ttf --corpus tests/data/fonts/NotoSansGujarati-nogdef-subset.ttf --corpus tests/data/fonts/ColorTestCOLRv0.ttf --corpus tests/data/fonts/ColorTestCOLRv1.ttf --corpus tests/data/fonts/ColorTestSbix.ttf --corpus tools/fuzz/regressions/font --out bin/wfuzz_font_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_font tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_font.w -o bin/wfuzz_font_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_font_harness --bytes --ext .ttf --corpus tests/data/fonts/NotoSans-subset.ttf --corpus tests/data/fonts/NotoSans-cff-subset.otf --corpus tests/data/fonts/NotoSansJP-subset.otf --corpus tests/data/fonts/NotoSansThai-subset.ttf --corpus tests/data/fonts/NotoSansGujarati-nogdef-subset.ttf --corpus tests/data/fonts/ColorTestCOLRv0.ttf --corpus tests/data/fonts/ColorTestCOLRv1.ttf --corpus tests/data/fonts/ColorTestSbix.ttf --corpus tools/fuzz/regressions/font --out bin/wfuzz_font" timeout=3600000
# Fuzz harness for the font parsers (issue #842): lib/ttf.w's table
# directory, cmap, hmtx/kern/GPOS kerning, glyf (simple and composite)
# and CFF charstring outlines, rasterization (unhinted and lib/ttf_hint.w's
# light hinting) and subsetting; lib/ttf_shape.w's shaper (GSUB/GPOS/GDEF
# through lib/ttf_layout.w) over a few scripts; and graphics/ui/
# font_color.w's COLR v0/v1, CBDT/CBLC and sbix color glyphs. The seeds
# are the small subset fonts under tests/data/fonts.
import tools.fuzz.harness
import lib.ttf
import lib.ttf_hint
import lib.ttf_layout
import lib.ttf_shape
import graphics.ui.font_color


# Glyphs drawn per input: enough to reach composites and subroutines,
# few enough to keep a case fast whatever glyph count the input claims.
const int fh_font_glyphs = 24


void fh_font_glyph(ttf_font* f, ttf_color_font* cf, int gid):
	int[4] box
	ttf_glyph_bbox(f, gid, &box[0])
	ttf_advance_units(f, gid)
	ttf_bitmap bm
	if (ttf_rasterize(f, gid, 12, &bm) && (bm.pixels != 0)): free(bm.pixels)
	if (ttf_rasterize_hinted(f, gid, 11, 0.0, TTF_HINT_LIGHT, &bm) && (bm.pixels != 0)): free(bm.pixels)
	if (f.cff != 0):
		string_builder* path = string_new()
		ttf_cff_path(f, gid, path)
		string_free(path)
	if (ttf_color_present(cf)):
		ttf_color_glyph g
		ttf_color_glyph_init(&g)
		ttf_color_render(cf, gid, 16, &g)
		ttf_color_glyph_free(&g)


void fh_font_shape(ttf_font* f, char* text):
	int32[16] cps
	int32[16] clusters
	int count = 0
	# text is UTF-32 code points written as 4-hex-digit groups.
	while ((text[count * 4] != 0) && (count < 16)):
		int cp = 0
		for k in range(4):
			int c = text[count * 4 + k]
			int v = c - '0'
			if (c >= 'a'): v = c - 'a' + 10
			cp = cp * 16 + v
		cps[count] = cp
		clusters[count] = count
		count = count + 1
	int script = ttf_guess_script(&cps[0], count)
	otl_buffer* b = ttf_shape(f, &cps[0], &clusters[0], count, ttf_script_is_rtl(script), script, 0, 0)
	if (b != 0): otl_buffer_free(b)


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	ttf_font font
	if (ttf_load_bytes(&font, data, length) == 0): return 1
	ttf_font* f = &font
	ttf_color_font cf
	ttf_color_init(&cf, f)
	int previous = 0
	for cp in range(32, 128):
		int gid = ttf_glyph_id(f, cp)
		ttf_kern_units(f, previous, gid)
		previous = gid
	ttf_glyph_id(f, 0x3042)
	ttf_glyph_id(f, 0x1f600)
	int glyphs = f.glyph_count
	if (glyphs > fh_font_glyphs): glyphs = fh_font_glyphs
	for gid in range(glyphs): fh_font_glyph(f, &cf, gid)
	# office (Latin ligatures), Thai, Gujarati, Arabic, Japanese.
	fh_font_shape(f, c"006f006600660069006300650020005600410057")
	fh_font_shape(f, c"0e010e380e480e330e170e35")
	fh_font_shape(f, c"0a950acd0ab70aa80abf0ab0")
	fh_font_shape(f, c"0628064e0628062706210644062706440644")
	fh_font_shape(f, c"30423099304b30893000")
	int[2] ranges
	ranges[0] = 32
	ranges[1] = 126
	int subset_size = 0
	char* subset = ttf_subset(f, &ranges[0], 1, &subset_size)
	if (subset != 0):
		ttf_font small
		if (ttf_load_bytes(&small, subset, subset_size)): ttf_glyph_id(&small, 'A')
		free(subset)
	return 0
