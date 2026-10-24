# wbuild: x64 deps=tests/data/cff_paths.txt deps=tests/data/fonts/
# CFF ('OTTO') outlines in lib/ttf.w: every glyph's charstring path and
# control-point bounds in two Noto subsets (one name-keyed with global
# and local subroutines, one CID-keyed with FDSelect) against fontTools
# (tests/data/cff_paths.txt, from tools/cff_paths_ref.py), plus
# rasterization and the shaper on a CFF font.
import lib.testing
import lib.stream
import lib.bytes
import lib.ttf
import lib.ttf_shape

# "gid [xMin yMin xMax yMax]" then the path, as the reference prints it.
void cff_format_glyph(ttf_font* f, int gid, string_builder* out):
	int[4] box
	ttf_glyph_bbox(f, gid, &box[0])
	string_append_int(out, gid)
	string_append(out, c" [")
	for i in range(4):
		if (i > 0): string_append_char(out, ' ')
		string_append_int(out, box[i])
	string_append_char(out, ']')
	asserts(c"charstring runs", ttf_cff_path(f, gid, out))

void test_paths_match_fonttools():
	wstream* src = stream_open_read(c"tests/data/cff_paths.txt")
	asserts(c"reference opens", src != 0)
	string_builder* line = string_new()
	string_builder* got = string_new()
	ttf_font font
	int loaded = 0
	int gid = 0
	int glyphs = 0
	int failures = 0
	while (stream_read_line(src, line)):
		if ((line.length == 0) || (line.data[0] == '#')): continue
		if (line.data[0] == '@'):
			if (loaded): ttf_free(&font)
			string_append_char(line, 0)
			asserts(c"CFF font loads", ttf_load(&font, line.data + 1))
			asserts(c"has CFF outlines", font.cff != 0)
			loaded = 1
			gid = 0
			continue
		string_clear(got)
		cff_format_glyph(&font, gid, got)
		if (!bytes_equal(got.data, got.length, line.data, line.length)):
			failures = failures + 1
			print(c"MISMATCH\n  want ")
			print_n(line.data, line.length)
			print(c"\n  got  ")
			print_n(got.data, got.length)
			print(c"\n")
		gid = gid + 1
		glyphs = glyphs + 1
	stream_close(src)
	if (loaded): ttf_free(&font)
	string_free(line)
	string_free(got)
	assert_equal(0, failures)
	asserts(c"reference covers both fonts", glyphs > 60)

void test_cid_keyed_font():
	ttf_font font
	asserts(c"loads", ttf_load(&font, c"tests/data/fonts/NotoSansJP-subset.otf"))
	asserts(c"CID-keyed", font.cff_fdarray != 0)
	int gid = ttf_glyph_id(&font, 0x65e5)
	asserts(c"has the kanji", gid != 0)
	int[4] box
	assert1(ttf_glyph_bbox(&font, gid, &box[0]))
	asserts(c"kanji has ink", (box[2] > box[0]) && (box[3] > box[1]))
	ttf_bitmap bitmap
	assert1(ttf_rasterize(&font, gid, 32, &bitmap))
	asserts(c"rasterized", (bitmap.w > 10) && (bitmap.h > 10))
	int ink = 0
	for i in range(bitmap.w * bitmap.h): ink = ink + (bitmap.pixels[i] & 255)
	asserts(c"coverage", ink > 255 * 20)
	free(bitmap.pixels)
	ttf_free(&font)

void test_rasterize_and_shape():
	ttf_font font
	asserts(c"loads", ttf_load(&font, c"tests/data/fonts/NotoSans-cff-subset.otf"))
	int gid = ttf_glyph_id(&font, 'o')
	ttf_bitmap bitmap
	assert1(ttf_rasterize(&font, gid, 40, &bitmap))
	# An 'o' has a hole: the centre pixel is empty, the left edge inked.
	asserts(c"o rasterized", (bitmap.w > 8) && (bitmap.h > 8))
	int middle = (bitmap.h / 2) * bitmap.w
	assert_equal(0, bitmap.pixels[middle + bitmap.w / 2] & 255)
	int left = 0
	for x in range(bitmap.w / 3): left = left + (bitmap.pixels[middle + x] & 255)
	asserts(c"o ring inked", left > 200)
	free(bitmap.pixels)
	# A synthetic oblique leans the same outline.
	ttf_bitmap leaning
	assert1(ttf_rasterize_skewed(&font, gid, 40, 0.25, &leaning))
	asserts(c"oblique is wider", leaning.w > 8)
	free(leaning.pixels)
	# Shaping works the same over CFF outlines: "office" ligates.
	int32[8] cps
	int32[8] clusters
	char* text = c"office"
	for i in range(6):
		cps[i] = text[i]
		clusters[i] = i
	otl_buffer* b = ttf_shape(&font, &cps[0], &clusters[0], 6, 0, -1, 0, 0)
	assert_equal(4, b.count)
	otl_buffer_free(b)
	# CFF fonts cannot be subset (the subsetter writes glyf/loca).
	int[2] ranges
	ranges[0] = 'a'
	ranges[1] = 'z'
	int size = 0
	asserts(c"subset refused", ttf_subset(&font, &ranges[0], 1, &size) == 0)
	ttf_free(&font)

void test_malformed_cff():
	ttf_font font
	asserts(c"loads", ttf_load(&font, c"tests/data/fonts/NotoSans-cff-subset.otf"))
	# Point the charstrings at the Global Subr INDEX: its subroutines end
	# in 'return' without endchar and call nothing valid as glyphs, so
	# interpretation must stay in bounds.
	int saved = font.cff_charstrings
	font.cff_charstrings = font.cff_gsubrs
	string_builder* path = string_new()
	for gid in range(10): ttf_cff_path(&font, gid, path)
	font.cff_charstrings = saved
	string_free(path)
	# A version-1 header check: a corrupted CFF major version fails to load.
	char* data = cast(char*, malloc(font.size))
	mem_copy(data, font.data, font.size)
	data[font.cff] = 9
	ttf_font broken
	assert_equal(0, ttf_load_bytes(&broken, data, font.size))
	free(data)
	ttf_free(&font)
