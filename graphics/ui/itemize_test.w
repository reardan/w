# wbuild: name=graphics_ui_itemize_test arch_only=x64 deps=tests/data/fonts/
# Paragraph itemization (graphics.ui.itemize): bidi, script and face runs
# over the embedded default face with the committed Noto subsets as
# fallbacks, visual order, carets across runs, drawing, fitting and
# limits; shaping context and cross-face joining; line layout (UAX #14
# breaks by shaped width, per-line bidi and reshaping, carets and
# hit-testing across lines). Headless; needs no display.
import lib.testing
import graphics.ui.itemize

int hebrew_face
int arabic_face
int devanagari_face
int latin_face

void load_faces():
	if (hebrew_face != 0): return
	hebrew_face = ui_font_face_load_ttf(c"tests/data/fonts/NotoSansHebrew-subset.ttf")
	arabic_face = ui_font_face_load_ttf(c"tests/data/fonts/NotoSansArabic-subset.ttf")
	devanagari_face = ui_font_face_load_ttf(c"tests/data/fonts/NotoSansDevanagari-subset.ttf")
	latin_face = ui_font_face_load_ttf(c"tests/data/fonts/NotoSans-subset.ttf")
	asserts(c"fixture faces load", (hebrew_face > 0) && (arabic_face > 0) && (devanagari_face > 0) && (latin_face > 0))
	ui_font_add_fallback(hebrew_face)
	ui_font_add_fallback(arabic_face)
	ui_font_add_fallback(devanagari_face)
	ui_font_add_fallback(latin_face)

void expect_item(ui_paragraph* p, int i, int start, int end, int level, char* script, int face):
	ui_text_item* item = &p.items[i]
	assert_equal(start, item.byte_start)
	assert_equal(end - start, item.byte_length)
	assert_equal(level, item.level)
	assert_equal(ut_script_from_code(script), item.script)
	assert_equal(face, item.face)
	assert_equal(UI_SHAPE_OK, item.run.status)
	asserts(c"item has glyphs", item.run.count > 0)

# "Hi " Hebrew " " Arabic " 12 " Devanagari "!" in a left-to-right paragraph.
char* mixed_text():
	return c"Hi \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d \xd9\x85\xd8\xb1\xd8\xad\xd8\xa8\xd8\xa7 12 \xe0\xa4\x95\xe0\xa4\xbf!"

void test_mixed_runs_and_visual_order():
	load_faces()
	char* text = mixed_text()
	ui_paragraph* p = ui_paragraph_shape(text, strlen(text), 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_OK, p.status)
	assert_equal(UI_SHAPE_LTR, p.direction)
	assert_equal(33, p.source_bytes)
	assert_equal(7, p.item_count)
	expect_item(p, 0, 0, 3, 0, c"Latn", UI_FACE_REGULAR)
	# The space after the Hebrew word takes its script and stays in its face.
	expect_item(p, 1, 3, 12, 1, c"Hebr", hebrew_face)
	expect_item(p, 2, 12, 23, 1, c"Arab", arabic_face)
	# Digits after Arabic: their own bidi level, Arabic script, and the
	# Arabic face, which covers them.
	expect_item(p, 3, 23, 25, 2, c"Arab", arabic_face)
	expect_item(p, 4, 25, 26, 0, c"Arab", arabic_face)
	expect_item(p, 5, 26, 32, 0, c"Deva", devanagari_face)
	# The Devanagari face has no '!': the next face that covers it.
	expect_item(p, 6, 32, 33, 0, c"Deva", UI_FACE_REGULAR)
	# Left to right: Latin, then the right-to-left run with the digits
	# leftmost and the Hebrew word rightmost, then the rest.
	assert_equal(0, p.visual_items[0])
	assert_equal(3, p.visual_items[1])
	assert_equal(2, p.visual_items[2])
	assert_equal(1, p.visual_items[3])
	assert_equal(4, p.visual_items[4])
	assert_equal(5, p.visual_items[5])
	assert_equal(6, p.visual_items[6])
	int total = 0
	int pen = 0
	for k in range(p.item_count):
		ui_text_item* item = &p.items[p.visual_items[k]]
		assert_equal(pen, item.x)
		pen = pen + item.run.advance
		total = total + item.run.advance
	assert_equal(total, p.advance)
	assert_equal(ui_font_strike_ppem(0), ui_font_strike_ppem(p.items[1].strike))
	asserts(c"line ascent covers every face", p.ascent >= ui_font_strike_ascent(p.items[5].strike))
	ui_paragraph_free(p)

void test_carets_across_runs():
	load_faces()
	char* text = mixed_text()
	ui_paragraph* p = ui_paragraph_shape(text, strlen(text), 0, UI_SHAPE_AUTO)
	ui_text_item* latin = &p.items[0]
	ui_text_item* hebrew = &p.items[1]
	ui_text_item* digits = &p.items[3]
	assert_equal(0, ui_paragraph_caret_x(p, text, 0))
	# The start of the Hebrew word is its right edge.
	assert_equal(hebrew.x + hebrew.run.advance, ui_paragraph_caret_x(p, text, 3))
	assert_equal(latin.run.advance, ui_paragraph_caret_x(p, text, 2) + latin.run.glyphs[2].x_advance)
	# Inside the Hebrew word, logical order runs right to left.
	asserts(c"rtl caret moves left", ui_paragraph_caret_x(p, text, 5) < ui_paragraph_caret_x(p, text, 3))
	assert_equal(digits.x, ui_paragraph_caret_x(p, text, 23))
	assert_equal(p.advance, ui_paragraph_caret_x(p, text, 33))
	# A byte inside a character rounds to its grapheme.
	assert_equal(ui_paragraph_caret_x(p, text, 3), ui_paragraph_caret_x(p, text, 4))
	int[9] offsets
	offsets[0] = 0
	offsets[1] = 3
	offsets[2] = 5
	offsets[3] = 12
	offsets[4] = 23
	offsets[5] = 24
	offsets[6] = 26
	offsets[7] = 32
	offsets[8] = 33
	for k in range(9):
		assert_equal(offsets[k], ui_paragraph_offset_from_x(p, text, ui_paragraph_caret_x(p, text, offsets[k])))
	ui_paragraph_free(p)

void test_marks_stay_with_their_base():
	load_faces()
	# o + U+0308: the default face lacks the diaeresis, so the whole
	# grapheme moves to the first face with both, and the next letter stays
	# there while it is covered.
	char* text = c"ao\xcc\x88x"
	ui_paragraph* p = ui_paragraph_shape(text, strlen(text), 0, UI_SHAPE_LTR)
	assert_equal(UI_SHAPE_OK, p.status)
	assert_equal(2, p.item_count)
	expect_item(p, 0, 0, 1, 0, c"Latn", UI_FACE_REGULAR)
	expect_item(p, 1, 1, 5, 0, c"Latn", latin_face)
	ui_paragraph_free(p)
	# Hebrew bet + dagesh shapes as one Hebrew-face run.
	text = c"\xd7\x91\xd6\xbc"
	p = ui_paragraph_shape(text, strlen(text), 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_RTL, p.direction)
	assert_equal(1, p.item_count)
	expect_item(p, 0, 0, 4, 1, c"Hebr", hebrew_face)
	ui_paragraph_free(p)

void test_brackets_and_leading_common():
	load_faces()
	# Leading punctuation takes the first real script; the closing bracket
	# takes its opener's script, not the Hebrew inside.
	char* text = c"1 (a\xd7\xa9) b"
	ui_paragraph* p = ui_paragraph_shape(text, strlen(text), 0, UI_SHAPE_LTR)
	assert_equal(UI_SHAPE_OK, p.status)
	int latn = ut_script_from_code(c"Latn")
	for i in range(p.item_count):
		ui_text_item* item = &p.items[i]
		if (item.byte_start == 0): assert_equal(latn, item.script)
		if (item.byte_start <= 6):
			if (item.byte_start + item.byte_length > 6): assert_equal(latn, item.script)
	ui_paragraph_free(p)
	# Only shared characters: no script, so the shaper guesses.
	p = ui_paragraph_shape(c"12 !", 4, 0, UI_SHAPE_LTR)
	assert_equal(1, p.item_count)
	assert_equal(-1, p.items[0].script)
	ui_paragraph_free(p)

void test_draw_and_fit():
	load_faces()
	char* text = mixed_text()
	ui_paragraph* p = ui_paragraph_shape(text, strlen(text), 0, UI_SHAPE_AUTO)
	ui_renderer renderer
	ui_render_init_headless(&renderer)
	ui_render_begin(&renderer, 400, 60)
	assert_equal(1, ui_paragraph_draw(&renderer, 10.0, 10.0, p, ui_gray(1.0)))
	asserts(c"paragraph drew glyph quads", renderer.layer_vert_count[UI_LAYER_BASE] > 0)
	ui_render_destroy(&renderer)
	# Fitting: "Hi " fits exactly; one unit less still breaks there (the
	# first break), and the whole width fits everything.
	ui_text_item* latin = &p.items[0]
	assert_equal(3, ui_paragraph_fit(p, text, latin.run.advance))
	assert_equal(3, ui_paragraph_fit(p, text, 1))
	assert_equal(33, ui_paragraph_fit(p, text, p.advance))
	assert_equal(12, ui_paragraph_fit(p, text, latin.run.advance + p.items[1].run.advance))
	ui_paragraph_free(p)

void test_empty_invalid_and_limits():
	ui_paragraph* p = ui_paragraph_shape(c"", 0, 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_OK, p.status)
	assert_equal(0, p.item_count)
	assert_equal(0, p.advance)
	assert_equal(0, ui_paragraph_caret_x(p, c"", 0))
	assert_equal(0, ui_paragraph_offset_from_x(p, c"", 100))
	assert_equal(0, ui_paragraph_fit(p, c"", 100))
	ui_paragraph_free(p)
	p = ui_paragraph_shape(c"\xff", 1, 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_INVALID, p.status)
	assert_equal(0, ui_paragraph_draw(cast(ui_renderer*, 0), 0.0, 0.0, p, ui_gray(1.0)))
	ui_paragraph_free(p)
	p = ui_paragraph_shape(c"a", 1, -1, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_INVALID, p.status)
	ui_paragraph_free(p)
	p = ui_paragraph_shape(c"a", 1, 0, 9)
	assert_equal(UI_SHAPE_INVALID, p.status)
	ui_paragraph_free(p)
	p = ui_paragraph_shape(c"a", 65537, 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_LIMIT, p.status)
	ui_paragraph_free(p)
	ui_paragraph_free(cast(ui_paragraph*, 0))

# ---- Shaping context and cross-face joining (issue #826) ----------------

# The glyph of the logically first and last letter of a two-letter run
# of seen (init and fina forms), and of one seen alone (isol). (The
# subset's beh forms share one dotless glyph.)
void seen_forms(int strike, int* isol, int* init, int* fina):
	ui_shaped_run* run = ui_shape_portable_utf8(c"\xd8\xb3", 2, strike, UI_SHAPE_RTL, 0, 0, 64)
	isol[0] = run.glyphs[0].gid
	ui_shaped_run_free(run)
	run = ui_shape_portable_utf8(c"\xd8\xb3\xd8\xb3", 4, strike, UI_SHAPE_RTL, 0, 0, 64)
	# Visual order: the logical last letter is leftmost.
	fina[0] = run.glyphs[0].gid
	init[0] = run.glyphs[1].gid
	ui_shaped_run_free(run)
	asserts(c"seen forms differ", (isol[0] != init[0]) && (init[0] != fina[0]) && (isol[0] != fina[0]))

void test_shaping_context():
	load_faces()
	int strike = ui_font_strike(arabic_face, ui_font_strike_ppem(0))
	int isol = 0
	int init = 0
	int fina = 0
	seen_forms(strike, &isol, &init, &fina)
	# Three seens: the middle one shaped alone with its neighbours as
	# context takes the medial form; with only one side, init or fina.
	char* text = c"\xd8\xb3\xd8\xb3\xd8\xb3"
	ui_shaped_run* alone = ui_shape_portable_item(text, 6, 2, 2, strike, UI_SHAPE_RTL, 0, 0, 64)
	assert_equal(UI_SHAPE_OK, alone.status)
	assert_equal(1, alone.count)
	assert_equal(0, alone.glyphs[0].cluster)
	asserts(c"medial in context", (alone.glyphs[0].gid != isol) && (alone.glyphs[0].gid != init) && (alone.glyphs[0].gid != fina))
	ui_shaped_run_free(alone)
	ui_shaped_run* first = ui_shape_portable_item(text, 4, 0, 2, strike, UI_SHAPE_RTL, 0, 0, 64)
	assert_equal(init, first.glyphs[0].gid)
	ui_shaped_run_free(first)
	ui_shaped_run* last = ui_shape_portable_item(text, 6, 4, 2, strike, UI_SHAPE_RTL, 0, 0, 64)
	assert_equal(fina, last.glyphs[0].gid)
	ui_shaped_run_free(last)
	# Transparent marks in the context are skipped; a non-joining
	# character (a space) stops the join.
	char* marked = c"\xd8\xb3\xd9\x8e\xd8\xb3"
	ui_shaped_run* after_mark = ui_shape_portable_item(marked, 6, 4, 2, strike, UI_SHAPE_RTL, 0, 0, 64)
	assert_equal(fina, after_mark.glyphs[0].gid)
	ui_shaped_run_free(after_mark)
	char* spaced = c"\xd8\xb3 \xd8\xb3"
	ui_shaped_run* after_space = ui_shape_portable_item(spaced, 5, 3, 2, strike, UI_SHAPE_RTL, 0, 0, 64)
	assert_equal(isol, after_space.glyphs[0].gid)
	ui_shaped_run_free(after_space)
	# Context stops at invalid UTF-8 and never reaches outside the text.
	char* broken = c"\xd8\xb3\xff\xd8\xb3"
	ui_shaped_run* after_bad = ui_shape_portable_item(broken, 5, 3, 2, strike, UI_SHAPE_RTL, 0, 0, 64)
	assert_equal(isol, after_bad.glyphs[0].gid)
	ui_shaped_run_free(after_bad)
	ui_shaped_run* bad_range = ui_shape_portable_item(text, 6, 4, 4, strike, UI_SHAPE_RTL, 0, 0, 64)
	assert_equal(UI_SHAPE_INVALID, bad_range.status)
	ui_shaped_run_free(bad_range)
	# The lib.ttf_shape entry point directly: seen with a dual-joining
	# tatweel on either side.
	ttf_font* font = ui_font_face_font(arabic_face)
	int32[1] cps
	int32[1] clusters
	int32[1] pre
	int32[1] post
	cps[0] = 0x0633
	clusters[0] = 0
	pre[0] = 0x0640
	post[0] = 0x0640
	otl_buffer* b = ttf_shape_context(font, &cps[0], &clusters[0], 1, &pre[0], 1, &post[0], 1, 1, -1, 0, 0)
	int medial = b.glyphs[0].gid
	otl_buffer_free(b)
	b = ttf_shape(font, &cps[0], &clusters[0], 1, 1, -1, 0, 0)
	asserts(c"context changes the form", medial != b.glyphs[0].gid)
	otl_buffer_free(b)
	# The context is cleared after the call.
	b = ttf_shape(font, &cps[0], &clusters[0], 1, 1, -1, 0, 0)
	assert_equal(0, ttf_context_before)
	assert_equal(0, ttf_context_after)
	otl_buffer_free(b)

void test_cross_face_joining():
	load_faces()
	int strike = ui_font_strike(arabic_face, ui_font_strike_ppem(0))
	int isol = 0
	int init = 0
	int fina = 0
	seen_forms(strike, &isol, &init, &fina)
	# Seen, jeem, seen: the subset has no jeem, so the word splits into
	# three items of two faces, and the seens still join to the jeem.
	char* text = c"\xd8\xb3\xd8\xac\xd8\xb3"
	ui_paragraph* p = ui_paragraph_shape(text, 6, 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_OK, p.status)
	assert_equal(3, p.item_count)
	assert_equal(arabic_face, p.items[0].face)
	asserts(c"jeem from another face", p.items[1].face != arabic_face)
	assert_equal(arabic_face, p.items[2].face)
	assert_equal(init, p.items[0].run.glyphs[0].gid)
	assert_equal(fina, p.items[2].run.glyphs[0].gid)
	ui_paragraph_free(p)

# ---- Line layout (issue #826) ---------------------------------------------

# Every line fits (unless it is one grapheme), lines tile the text in
# order and stack from the top.
void expect_lines_tile(ui_paragraph* p, int width):
	int at = 0
	int top = 0
	for k in range(p.line_count):
		ui_text_line* line = &p.lines[k]
		assert_equal(at, line.byte_start)
		assert_equal(top, line.top)
		asserts(c"line fits", (line.advance - line.trailing <= width) || (line.item_count <= 1))
		asserts(c"trailing inside advance", (line.trailing >= 0) && (line.trailing <= line.advance))
		int pen = 0
		for v in range(line.item_count):
			ui_text_item* item = &line.items[line.visual_items[v]]
			assert_equal(pen, item.x)
			pen = pen + item.run.advance
		assert_equal(pen, line.advance)
		at = at + line.byte_length
		top = top + line.ascent + line.descent
	assert_equal(p.source_bytes, at)
	assert_equal(top, p.height)

# The width of text[0, length) shaped alone as a paragraph.
int paragraph_width(char* text, int length):
	ui_paragraph* p = ui_paragraph_shape(text, length, 0, UI_SHAPE_LTR)
	int width = p.advance
	ui_paragraph_free(p)
	return width

void test_layout_latin_words():
	char* text = c"the quick brown fox jumps"
	int length = strlen(text)
	ui_paragraph* p = ui_paragraph_shape(text, length, 0, UI_SHAPE_AUTO)
	# "the quick" fits; the space after it hangs.
	int width = paragraph_width(c"the quick", 9)
	assert_equal(UI_SHAPE_OK, ui_paragraph_layout(p, text, width, lb_tailor_default))
	assert_equal(width, p.line_width)
	asserts(c"several lines", p.line_count >= 3)
	assert_equal(10, p.lines[0].byte_length)
	asserts(c"the space hangs", p.lines[0].trailing > 0)
	assert_equal(width, p.lines[0].advance - p.lines[0].trailing)
	expect_lines_tile(p, width)
	# The last line has no trailing space.
	assert_equal(0, p.lines[p.line_count - 1].trailing)
	# Wide enough for everything: one line, the unwrapped paragraph.
	assert_equal(UI_SHAPE_OK, ui_paragraph_layout(p, text, p.advance, lb_tailor_default))
	assert_equal(1, p.line_count)
	assert_equal(p.advance, p.lines[0].advance)
	assert_equal(p.ascent + p.descent, p.height)
	ui_paragraph_free(p)

void test_layout_bidi_lines():
	load_faces()
	# "a shalom shalom b" in a left-to-right paragraph: unwrapped, the
	# space between the Hebrew words is right-to-left (level 1); at a
	# line end, rule L1 resets it to the paragraph level.
	char* text = c"a \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d b"
	int length = strlen(text)
	ui_paragraph* p = ui_paragraph_shape(text, length, 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_LTR, p.direction)
	int width = paragraph_width(text, 10)
	assert_equal(UI_SHAPE_OK, ui_paragraph_layout(p, text, width, lb_tailor_default))
	assert_equal(2, p.line_count)
	ui_text_line* line = &p.lines[0]
	assert_equal(11, line.byte_length)
	assert_equal(3, line.item_count)
	assert_equal(0, line.items[0].level)
	assert_equal(1, line.items[1].level)
	assert_equal(2, line.items[1].byte_start)
	assert_equal(8, line.items[1].byte_length)
	# The trailing space: level 0, still in the Hebrew face, and it hangs.
	assert_equal(10, line.items[2].byte_start)
	assert_equal(0, line.items[2].level)
	assert_equal(hebrew_face, line.items[2].face)
	assert_equal(line.items[2].run.advance, line.trailing)
	assert_equal(0, line.visual_items[0])
	assert_equal(1, line.visual_items[1])
	assert_equal(2, line.visual_items[2])
	# The second line: the Hebrew word then " b".
	line = &p.lines[1]
	assert_equal(11, line.byte_start)
	assert_equal(1, line.items[0].level)
	expect_lines_tile(p, width)
	ui_paragraph_free(p)

void test_layout_rtl_alignment():
	load_faces()
	char* text = c"\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d \xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d"
	int length = strlen(text)
	ui_paragraph* p = ui_paragraph_shape(text, length, 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_RTL, p.direction)
	int width = paragraph_width(text, 8) + 64
	assert_equal(UI_SHAPE_OK, ui_paragraph_layout(p, text, width, lb_tailor_default))
	assert_equal(2, p.line_count)
	# Start-aligned on the right: the content ends at the right edge and
	# the trailing space hangs at the left.
	ui_text_line* line = &p.lines[0]
	assert_equal(width - line.advance, line.x)
	asserts(c"space hangs", line.trailing > 0)
	# The first character's caret is the line's right edge.
	int index = -1
	assert_equal(width, ui_paragraph_line_caret_x(p, text, 0, &index))
	assert_equal(0, index)
	expect_lines_tile(p, width)
	ui_paragraph_free(p)

void test_layout_reshapes_lines():
	load_faces()
	# Three seens, each wider than the layout: the word breaks between
	# graphemes, and each line reshapes its letter alone (isolated), where
	# the unwrapped paragraph joins them.
	int strike = ui_font_strike(arabic_face, ui_font_strike_ppem(0))
	int isol = 0
	int init = 0
	int fina = 0
	seen_forms(strike, &isol, &init, &fina)
	char* text = c"\xd8\xb3\xd8\xb3\xd8\xb3"
	ui_paragraph* p = ui_paragraph_shape(text, 6, 0, UI_SHAPE_AUTO)
	assert_equal(1, p.item_count)
	assert_equal(UI_SHAPE_OK, ui_paragraph_layout(p, text, 1, lb_tailor_default))
	assert_equal(3, p.line_count)
	for k in range(3):
		assert_equal(2, p.lines[k].byte_length)
		assert_equal(1, p.lines[k].item_count)
		assert_equal(isol, p.lines[k].items[0].run.glyphs[0].gid)
	ui_paragraph_free(p)

void test_layout_kinsoku():
	# Ideographs break anywhere, but never before the ideographic full
	# stop, so a line never starts with it.
	char* text = c"\xe6\xbc\xa2\xe5\xad\x97\xe3\x80\x82\xe6\xbc\xa2\xe5\xad\x97\xe3\x80\x82"
	int length = strlen(text)
	ui_paragraph* p = ui_paragraph_shape(text, length, 0, UI_SHAPE_AUTO)
	int width = paragraph_width(text, 6)
	assert_equal(UI_SHAPE_OK, ui_paragraph_layout(p, text, width, lb_tailor_default))
	asserts(c"wrapped", p.line_count >= 2)
	for k in range(p.line_count):
		ui_text_line* line = &p.lines[k]
		asserts(c"no line starts with the full stop", (text[line.byte_start] & 255) != 0xe3)
	# The first line holds the first ideograph only: the second may not
	# end it (the stop must follow), and with the stop it is too wide.
	assert_equal(3, p.lines[0].byte_length)
	ui_paragraph_free(p)

void test_layout_carets_and_hits():
	load_faces()
	char* text = mixed_text()
	int length = strlen(text)
	ui_paragraph* p = ui_paragraph_shape(text, length, 0, UI_SHAPE_AUTO)
	int width = p.advance / 2
	assert_equal(UI_SHAPE_OK, ui_paragraph_layout(p, text, width, lb_tailor_default))
	asserts(c"wrapped", p.line_count >= 2)
	expect_lines_tile(p, width)
	# Every grapheme boundary: its caret is on the line that holds it.
	int at = 0
	while (1):
		int index = -1
		int x = ui_paragraph_line_caret_x(p, text, at, &index)
		assert_equal(ui_paragraph_line_at(p, at), index)
		ui_text_line* line = &p.lines[index]
		asserts(c"offset on its line", (at >= line.byte_start) && (at <= line.byte_start + line.byte_length))
		# Hitting that caret finds an offset with the same caret (bidi
		# boundaries can share one x).
		int hit = ui_paragraph_hit_test(p, text, x, line.top + 1)
		int hit_line = -1
		assert_equal(x, ui_paragraph_line_caret_x(p, text, hit, &hit_line))
		assert_equal(index, hit_line)
		if (at >= length): break
		at = ui_grapheme_next_n(text, length, at)
	# A line boundary belongs to the next line; the end to the last.
	assert_equal(1, ui_paragraph_line_at(p, p.lines[1].byte_start))
	assert_equal(p.line_count - 1, ui_paragraph_line_at(p, length))
	# y outside the paragraph clamps to the first and last lines.
	assert_equal(0, ui_paragraph_line_at_y(p, -5))
	assert_equal(p.line_count - 1, ui_paragraph_line_at_y(p, p.height + 50))
	# Far right of a wrapped line: its last offset before the next line.
	int end = p.lines[0].byte_start + p.lines[0].byte_length
	int hit = ui_paragraph_hit_test(p, text, 1000000, 0)
	asserts(c"hit stays on the first line", hit < end)
	ui_renderer renderer
	ui_render_init_headless(&renderer)
	ui_render_begin(&renderer, 400, 120)
	assert_equal(1, ui_paragraph_draw_lines(&renderer, 10.0, 10.0, p, ui_gray(1.0)))
	asserts(c"lines drew glyph quads", renderer.layer_vert_count[UI_LAYER_BASE] > 0)
	ui_render_destroy(&renderer)
	ui_paragraph_free(p)

void test_layout_empty_and_invalid():
	ui_paragraph* p = ui_paragraph_shape(c"", 0, 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_OK, ui_paragraph_layout(p, c"", 100, lb_tailor_default))
	assert_equal(1, p.line_count)
	assert_equal(0, p.lines[0].item_count)
	assert_equal(p.ascent + p.descent, p.height)
	int index = -1
	assert_equal(0, ui_paragraph_line_caret_x(p, c"", 0, &index))
	assert_equal(0, index)
	assert_equal(0, ui_paragraph_hit_test(p, c"", 50, 3))
	ui_paragraph_free(p)
	p = ui_paragraph_shape(c"\xff", 1, 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_INVALID, ui_paragraph_layout(p, c"\xff", 100, lb_tailor_default))
	assert_equal(0, p.line_count)
	assert_equal(-1, ui_paragraph_line_at(p, 0))
	assert_equal(0, ui_paragraph_hit_test(p, c"\xff", 0, 0))
	assert_equal(0, ui_paragraph_draw_lines(cast(ui_renderer*, 0), 0.0, 0.0, p, ui_gray(1.0)))
	ui_paragraph_free(p)
	assert_equal(UI_SHAPE_INVALID, ui_paragraph_layout(cast(ui_paragraph*, 0), c"", 0, 0))
	# A text pointer is required for nonempty text.
	p = ui_paragraph_shape(c"ab", 2, 0, UI_SHAPE_AUTO)
	assert_equal(UI_SHAPE_INVALID, ui_paragraph_layout(p, cast(char*, 0), 100, lb_tailor_default))
	# Laying out again replaces the lines.
	assert_equal(UI_SHAPE_OK, ui_paragraph_layout(p, c"ab", 1, lb_tailor_default))
	assert_equal(2, p.line_count)
	assert_equal(UI_SHAPE_OK, ui_paragraph_layout(p, c"ab", p.advance, lb_tailor_default))
	assert_equal(1, p.line_count)
	ui_paragraph_free(p)
