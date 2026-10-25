# wbuild: name=graphics_ui_itemize_test arch_only=x64 deps=tests/data/fonts/
# Paragraph itemization (graphics.ui.itemize): bidi, script and face runs
# over the embedded default face with the committed Noto subsets as
# fallbacks, visual order, carets across runs, drawing, fitting and
# limits. Headless; needs no display.
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
