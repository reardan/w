# wbuild: x64 deps=tests/data/shape_golden.txt deps=tests/data/fonts/ deps=tools/ui/LiberationSans-Regular.ttf
# The portable shaper (lib/ttf_shape.w over lib/ttf_layout.w) against
# HarfBuzz 15 output recorded in tests/data/shape_golden.txt (regenerate
# with tools/shape_golden_hb.py), plus direct checks of the joining,
# normalization and option paths. The fonts are small OFL Noto subsets
# (tests/data/fonts/README.md) and the checked-in Liberation Sans.
import lib.testing
import lib.stream
import lib.bytes
import tools.shape_dump_lib

int golden_mismatch(ttf_font* font, char* spec, char* line, int length):
	int tab = -1
	for i in range(length):
		if ((tab < 0) && (line[i] == 9)): tab = i
	asserts(c"golden line has a tab", tab > 0)
	string_builder* got = string_new()
	shape_format(font, line, tab, got)
	int want_length = length - tab - 1
	int same = bytes_equal(got.data, got.length, line + tab + 1, want_length)
	if (!same):
		print(f"MISMATCH {spec}: ")
		print_n(line, tab)
		print(c"\n  want ")
		print_n(line + tab + 1, want_length)
		print(c"\n  got  ")
		print_n(got.data, got.length)
		print(c"\n")
	string_free(got)
	return !same

void test_harfbuzz_golden():
	wstream* src = stream_open_read(c"tests/data/shape_golden.txt")
	asserts(c"golden file opens", src != 0)
	string_builder* line = string_new()
	ttf_font font
	int loaded = 0
	int lines = 0
	int failures = 0
	while (stream_read_line(src, line)):
		if ((line.length == 0) || (line.data[0] == '#')): continue
		if (line.data[0] == '@'):
			if (loaded): ttf_free(&font)
			string_append_char(line, 0)
			asserts(c"golden font loads", shape_load_spec(&font, line.data + 1))
			loaded = 1
			continue
		asserts(c"font before text", loaded)
		failures = failures + golden_mismatch(&font, c"golden", line.data, line.length)
		lines = lines + 1
	stream_close(src)
	if (loaded): ttf_free(&font)
	string_free(line)
	assert_equal(0, failures)
	asserts(c"golden file has its lines", lines >= 40)

# Shape a codepoint array as one run and return the buffer.
otl_buffer* shape_cps(ttf_font* font, int32* cps, int count, int rtl, int script, int flags):
	int32[64] clusters
	for i in range(count): clusters[i] = i
	return ttf_shape(font, cps, &clusters[0], count, rtl, script, 0, flags)

void test_joining_forms():
	# beh beh alef hamza: init medi fina, then a non-joining hamza.
	otl_buffer* b = otl_buffer_new(4)
	otl_buffer_add(b, 0, 0x0628, 0, 1)
	otl_buffer_add(b, 0, 0x064e, 1, 1)
	otl_buffer_add(b, 0, 0x0628, 2, 1)
	otl_buffer_add(b, 0, 0x0627, 3, 1)
	otl_buffer_add(b, 0, 0x0621, 4, 1)
	int32[8] forms
	ttf_joining_forms(b, &forms[0])
	assert_equal(ut_form_init, forms[0])
	# The transparent fatha takes no form and does not break the join.
	assert_equal(ut_form_none, forms[1])
	assert_equal(ut_form_medi, forms[2])
	assert_equal(ut_form_fina, forms[3])
	assert_equal(ut_form_none, forms[4])
	otl_buffer_free(b)
	# Tatweel joins on both sides like a dual-joining letter.
	b = otl_buffer_new(2)
	otl_buffer_add(b, 0, 0x0640, 0, 1)
	otl_buffer_add(b, 0, 0x0628, 1, 1)
	ttf_joining_forms(b, &forms[0])
	assert_equal(ut_form_init, forms[0])
	assert_equal(ut_form_fina, forms[1])
	otl_buffer_free(b)
	assert_equal(0xfe91, ut_arabic_form(0x0628, ut_form_init))
	assert_equal(0xfefb, ut_lam_alef(0x0627, ut_form_isol))
	assert_equal(-1, ut_arabic_form('a', ut_form_init))

void test_normalization_tables():
	int a = 0
	int b = 0
	assert1(ut_decompose(0x00e9, &a, &b))
	assert_equal('e', a)
	assert_equal(0x0301, b)
	assert_equal(0x00e9, ut_compose('e', 0x0301))
	assert_equal(-1, ut_compose('q', 0x0301))
	# Hangul composes and decomposes algorithmically.
	assert1(ut_decompose(0xac01, &a, &b))
	assert_equal(0xac00, a)
	assert_equal(0x11a8, b)
	assert_equal(0xac00, ut_compose(0x1100, 0x1161))
	assert_equal(0xac01, ut_compose(0xac00, 0x11a8))
	assert_equal(0xfb2c, ttf_hebrew_compose(0xfb49, 0x05c1))
	assert_equal(-1, ttf_hebrew_compose(0x05d7, 0x05bc))

void test_script_selection():
	char[40] tags
	int n = ttf_script_tags(ut_script_from_code(c"Deva"), &tags[0])
	assert_bytes_equal(c"dev2deva", &tags[0], 8)
	assert_bytes_equal(c"latn", &tags[(n - 1) * 4], 4)
	int32[4] cps
	cps[0] = ' '
	cps[1] = 0x05d0
	assert_bytes_equal(c"Hebr", ut_script_code(ttf_guess_script(&cps[0], 2)), 4)
	assert1(ttf_script_is_rtl(ut_script_from_code(c"Arab")))
	assert1(!ttf_script_is_rtl(ut_script_from_code(c"Latn")))

void test_shape_options():
	ttf_font font
	asserts(c"font loads", ttf_load(&font, c"tests/data/fonts/NotoSans-subset.ttf"))
	int32[8] cps
	char* text = c"office"
	for i in range(6): cps[i] = text[i]
	otl_buffer* b = shape_cps(&font, &cps[0], 6, 0, -1, 0)
	assert_equal(4, b.count)
	assert_equal(1, b.glyphs[1].cluster)
	assert_equal(4, b.glyphs[2].cluster)
	otl_buffer_free(b)
	b = shape_cps(&font, &cps[0], 6, 0, -1, ttf_shape_no_liga)
	assert_equal(6, b.count)
	otl_buffer_free(b)
	# Kerning on, then off: "AV" tightens only with it.
	cps[0] = 'A'
	cps[1] = 'V'
	b = shape_cps(&font, &cps[0], 2, 0, -1, 0)
	int kerned = b.glyphs[0].x_advance
	otl_buffer_free(b)
	b = shape_cps(&font, &cps[0], 2, 0, -1, ttf_shape_no_kern)
	asserts(c"kerning tightens AV", kerned < b.glyphs[0].x_advance)
	otl_buffer_free(b)
	# An empty run shapes to nothing.
	b = shape_cps(&font, &cps[0], 0, 0, -1, 0)
	assert_equal(0, b.count)
	otl_buffer_free(b)
	ttf_free(&font)

void test_rtl_mirroring_and_order():
	ttf_font font
	asserts(c"font loads", ttf_load(&font, c"tools/ui/LiberationSans-Regular.ttf"))
	# "(א)" right to left: visual order reverses and the parentheses
	# mirror, so the leftmost glyph is the closing paren's mirror '('.
	int32[4] cps
	cps[0] = '('
	cps[1] = 0x05d0
	cps[2] = ')'
	otl_buffer* b = shape_cps(&font, &cps[0], 3, 1, ut_script_from_code(c"Hebr"), 0)
	assert_equal(3, b.count)
	assert_equal(2, b.glyphs[0].cluster)
	assert_equal(0, b.glyphs[2].cluster)
	assert_equal(ttf_glyph_id(&font, '('), b.glyphs[0].gid)
	assert_equal(ttf_glyph_id(&font, ')'), b.glyphs[2].gid)
	otl_buffer_free(b)
	ttf_free(&font)

void expect_shape(ttf_font* font, char* text, char* want):
	string_builder* got = string_new()
	shape_format(font, text, strlen(text), got)
	assert_strings_equal(want, got.data)
	string_free(got)

# A font with no space glyph drops default ignorables after shaping, as
# HarfBuzz does, but only unsubstituted ones: a glyph GSUB made from an
# ignorable (a Khmer ZWJ + robat ligature) stays.
void test_dropped_ignorables():
	otl_buffer* b = otl_buffer_new(4)
	otl_buffer_add(b, 5, 'A', 0, 1)
	otl_buffer_add(b, 7, 0x200d, 1, 1)
	b.glyphs[1].subst = otl_subst_substituted | otl_subst_ligated
	otl_buffer_add(b, 0, 0xfe0f, 4, 1)
	otl_buffer_add(b, 0, 0x200c, 7, 1)
	ttf_shape_drop_ignorables(b)
	assert_equal(2, b.count)
	assert_equal(5, b.glyphs[0].gid)
	assert_equal(7, b.glyphs[1].gid)
	assert_equal(1, b.glyphs[1].cluster)
	otl_buffer_free(b)
	# The emoji subset has no space glyph: VS16 after the heart drops, and
	# the ZWJ family and skin-toned thumbs up ligate through GSUB.
	ttf_font font
	asserts(c"emoji subset loads", shape_load_spec(&font, c"tests/data/fonts/NotoColorEmoji-subset.ttf"))
	expect_shape(&font, c"\xe2\x9d\xa4\xef\xb8\x8f", c"dir=ltr 2@0+2550(0,0)")
	expect_shape(&font, c"\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7", c"dir=ltr 10@0+2550(0,0)")
	expect_shape(&font, c"\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd", c"dir=ltr 9@0+2550(0,0)")
