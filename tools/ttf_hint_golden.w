# The light autohinter's golden set (lib/ttf_hint.w, issue #824), shared
# by tools/ttf_hint_dump.w (which writes tests/data/ttf_hint_golden.txt)
# and tests/ttf_hint_test.w (which compares against it): a TrueType and a
# CFF Noto subset, hinted at small sizes.
import lib.lib
import lib.ttf
import lib.ttf_hint
import structures.string


char* ttf_hint_golden_font(int i):
	if (i == 0): return c"tests/data/fonts/NotoSans-subset.ttf"
	return c"tests/data/fonts/NotoSans-cff-subset.otf"


const int ttf_hint_golden_font_count = 2


# Characters both subsets map.
char* ttf_hint_golden_text = c"ARTVWcefiloq"


int ttf_hint_golden_ppem(int i):
	return 9 + i


const int ttf_hint_golden_ppem_count = 6


void ttf_hint_golden_hex(string_builder* out, int v):
	char* digits = c"0123456789abcdef"
	string_append_char(out, digits[(v >> 4) & 15])
	string_append_char(out, digits[v & 15])


# One glyph: "U+hex w h bearing_x bearing_top advance", then a hex line
# per row.
void ttf_hint_golden_glyph(string_builder* out, ttf_bitmap* bm, int code):
	string_append(out, c"U+")
	ttf_hint_golden_hex(out, code)
	string_append_char(out, ' ')
	string_append_int(out, bm.w)
	string_append_char(out, ' ')
	string_append_int(out, bm.h)
	string_append_char(out, ' ')
	string_append_int(out, bm.bearing_x)
	string_append_char(out, ' ')
	string_append_int(out, bm.bearing_top)
	string_append_char(out, ' ')
	string_append_int(out, bm.advance)
	string_append_char(out, '\n')
	for y in range(bm.h):
		for x in range(bm.w): ttf_hint_golden_hex(out, bm.pixels[y * bm.w + x] & 255)
		string_append_char(out, '\n')


# The golden text of one strike: "@font ppem" and every glyph. Returns 1,
# or 0 when the font does not load or a glyph fails.
int ttf_hint_golden_strike(string_builder* out, ttf_font* f, char* path, int ppem, int hinting):
	string_append_char(out, '@')
	string_append(out, path)
	string_append_char(out, ' ')
	string_append_int(out, ppem)
	string_append_char(out, '\n')
	int i = 0
	while (ttf_hint_golden_text[i] != 0):
		int code = ttf_hint_golden_text[i] & 255
		ttf_bitmap bm
		if (!ttf_rasterize_hinted(f, ttf_glyph_id(f, code), ppem, 0.0, hinting, &bm)): return 0
		ttf_hint_golden_glyph(out, &bm, code)
		if (bm.pixels != 0): free(bm.pixels)
		i = i + 1
	return 1


# The whole golden file. Returns 1, or 0 on a load or raster failure.
int ttf_hint_golden_format(string_builder* out):
	string_append(out, c"# lib.ttf_hint light-hinted bitmaps; regenerate with bin/ttf_hint_dump --golden\n")
	for i in range(ttf_hint_golden_font_count):
		ttf_font f
		if (!ttf_load(&f, ttf_hint_golden_font(i))): return 0
		for p in range(ttf_hint_golden_ppem_count):
			if (!ttf_hint_golden_strike(out, &f, ttf_hint_golden_font(i), ttf_hint_golden_ppem(p), TTF_HINT_LIGHT)): return 0
		ttf_free(&f)
	return 1
