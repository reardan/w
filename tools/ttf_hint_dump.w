# wbuild: binary=ttf_hint_dump tag=tests
# Print lib.ttf glyph bitmaps, hinted or not, for eyeballing the light
# autohinter (lib/ttf_hint.w) and for regenerating its golden file:
#
#   bin/ttf_hint_dump font.ttf ppem text [light|none]   ASCII art
#   bin/ttf_hint_dump --hex font.ttf ppem text [light|none]   golden format
#   bin/ttf_hint_dump --golden > tests/data/ttf_hint_golden.txt
#
# The golden set is ttf_hint_golden_fonts x ttf_hint_golden_ppems x
# ttf_hint_golden_text, in the format tests/ttf_hint_test.w reads: a
# "@font ppem" line per strike, then per character "U+hex w h bearing_x
# bearing_top advance" and one line of hex coverage bytes per row.
import lib.lib
import lib.ttf
import lib.ttf_hint
import tools.ttf_hint_golden
import structures.string


void dump_art(string_builder* out, ttf_bitmap* bm, int code):
	string_append(out, c"U+")
	ttf_hint_golden_hex(out, code)
	string_append(out, c" left ")
	string_append_int(out, bm.bearing_x)
	string_append(out, c" top ")
	string_append_int(out, bm.bearing_top)
	string_append(out, c" w ")
	string_append_int(out, bm.w)
	string_append(out, c" h ")
	string_append_int(out, bm.h)
	string_append(out, c" adv ")
	string_append_int(out, bm.advance)
	string_append_char(out, '\n')
	char* ramp = c" .:-=+*#%@"
	for y in range(bm.h):
		for x in range(bm.w):
			int k = (bm.pixels[y * bm.w + x] & 255) * 10 / 256
			string_append_char(out, ramp[k])
		string_append_char(out, '\n')


int main(int argc, char** argv):
	string_builder* out = string_new()
	if ((argc == 2) && (strcmp(argv[1], c"--golden") == 0)):
		if (!ttf_hint_golden_format(out)): return 1
		print_n(out.data, out.length)
		return 0
	int hex = (argc > 1) && (strcmp(argv[1], c"--hex") == 0)
	if (hex):
		argv = &argv[1]
		argc = argc - 1
	if (argc < 4):
		print_error(c"usage: ttf_hint_dump [--hex] font.ttf ppem text [light|none] | --golden\n")
		return 2
	ttf_font f
	if (!ttf_load(&f, argv[1])): return 1
	int ppem = atoi(argv[2])
	int hinting = TTF_HINT_LIGHT
	if ((argc > 4) && (strcmp(argv[4], c"none") == 0)): hinting = TTF_HINT_NONE
	char* text = argv[3]
	int i = 0
	while (text[i] != 0):
		ttf_bitmap bm
		int code = text[i] & 255
		if (ttf_rasterize_hinted(&f, ttf_glyph_id(&f, code), ppem, 0.0, hinting, &bm)):
			if (hex): ttf_hint_golden_glyph(out, &bm, code)
			else: dump_art(out, &bm, code)
			if (bm.pixels != 0): free(bm.pixels)
		i = i + 1
	print_n(out.data, out.length)
	return 0
