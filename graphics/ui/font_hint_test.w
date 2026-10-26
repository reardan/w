# wbuild: name=graphics_ui_font_hint_test arch_only=x64 deps=tests/data/fonts/
# Hinted strikes (graphics.ui.font over lib.ttf_hint, issue #824):
# hinting is a per-strike option that companions (resized, italic,
# fallback-face and paragraph strikes) inherit, it changes glyph
# bitmaps but never advances, text widths, carets or shaped positions,
# and drawing a paragraph in a hinted strike uses hinted glyphs.
# Headless; needs no display.
import lib.testing
import graphics.ui.itemize

void test_strike_options():
	int plain = ui_font_strike(UI_FACE_REGULAR, 13)
	int hinted = ui_font_strike_hinted(UI_FACE_REGULAR, 13, UI_HINT_LIGHT)
	asserts(c"strikes exist", (plain >= 0) && (hinted >= 0))
	asserts(c"hinting makes a separate strike", plain != hinted)
	assert_equal(plain, ui_font_strike_hinted(UI_FACE_REGULAR, 13, UI_HINT_NONE))
	assert_equal(hinted, ui_font_strike_hinted(UI_FACE_REGULAR, 13, UI_HINT_LIGHT))
	assert_equal(UI_HINT_NONE, ui_font_strike_hinting(plain))
	assert_equal(UI_HINT_LIGHT, ui_font_strike_hinting(hinted))
	assert_equal(hinted, ui_font_strike_with_hinting(plain, UI_HINT_LIGHT))
	assert_equal(plain, ui_font_strike_with_hinting(hinted, UI_HINT_NONE))
	assert_equal(0 - 1, ui_font_strike_hinted(UI_FACE_REGULAR, 13, 7))
	# Line metrics are the face's at that size either way.
	assert_equal(ui_font_strike_ascent(plain), ui_font_strike_ascent(hinted))
	assert_equal(ui_font_strike_descent(plain), ui_font_strike_descent(hinted))
	# Companions keep the mode.
	int big = ui_font_strike_resized(hinted, 15)
	assert_equal(UI_HINT_LIGHT, ui_font_strike_hinting(big))
	assert_equal(15, ui_font_strike_ppem(big))
	assert_equal(UI_HINT_NONE, ui_font_strike_hinting(ui_font_strike_resized(plain, 15)))
	int italic = ui_font_strike_italic(hinted)
	asserts(c"italic companion", italic >= 0)
	assert_equal(UI_HINT_LIGHT, ui_font_strike_hinting(italic))
	assert_equal(UI_FACE_ITALIC, ui_font_strike_face(italic))
	asserts(c"distinct from the unhinted italic", italic != ui_font_strike_italic(plain))
	assert_equal(UI_HINT_LIGHT, ui_font_strike_hinting(ui_font_strike_sibling(hinted, UI_FACE_BOLD, 13)))

void test_hinting_keeps_layout():
	int plain = ui_font_strike(UI_FACE_REGULAR, 11)
	int hinted = ui_font_strike_hinted(UI_FACE_REGULAR, 11, UI_HINT_LIGHT)
	char* text = c"Hinted text keeps its widths: AVTo fix 0123"
	assert_equal(ui_text_width_strike(text, plain), ui_text_width_strike(text, hinted))
	assert_equal(ui_text_height_strike(plain), ui_text_height_strike(hinted))
	int differs = 0
	int i = 0
	while (text[i] != 0):
		ui_glyph a = ui_font_glyph(plain, text[i])
		ui_glyph b = ui_font_glyph(hinted, text[i])
		assert_equal(a.advance, b.advance)
		assert_equal(a.bearing_x, b.bearing_x)
		assert_equal(a.w, b.w)
		if ((a.h != b.h) || (a.bearing_top != b.bearing_top)): differs = differs + 1
		i = i + 1
	asserts(c"hinting moves glyph rows", differs > 0)
	# The x-height lands on a whole pixel: 'x' is crisp on top and bottom.
	ui_glyph x = ui_font_glyph(hinted, 'x')
	char* pixels = ui_font_st.pixels
	int w = ui_font_atlas_w()
	int row0 = x.y - ui_font_atlas_h()
	int first = 0 - 1
	int last = 0 - 1
	int widest = 0
	for r in range(x.h):
		int sum = 0
		for c in range(x.w): sum = sum + (pixels[(row0 + r) * w + x.x + c] & 255)
		if (sum > 0):
			if (first < 0): first = r
			last = r
		if (sum > widest): widest = sum
	asserts(c"x has ink", first >= 0)
	int top_sum = 0
	for c in range(x.w): top_sum = top_sum + (pixels[(row0 + first) * w + x.x + c] & 255)
	asserts(c"x-height row is solid", top_sum * 3 >= widest * 2)
	assert_equal(x.bearing_top - last, 1)

void test_shaped_runs_and_paragraphs():
	int face = ui_font_face_load_ttf(c"tests/data/fonts/NotoSans-cff-subset.otf")
	asserts(c"cff face", face >= 0)
	int plain = ui_font_strike(face, 12)
	int hinted = ui_font_strike_hinted(face, 12, UI_HINT_LIGHT)
	char* text = c"office 0123"
	ui_shaped_run* a = ui_shape_portable_utf8(text, strlen(text), plain, UI_SHAPE_LTR, 0, 0, 64)
	ui_shaped_run* b = ui_shape_portable_utf8(text, strlen(text), hinted, UI_SHAPE_LTR, 0, 0, 64)
	assert_equal(UI_SHAPE_OK, a.status)
	assert_equal(UI_SHAPE_OK, b.status)
	assert_equal(a.count, b.count)
	assert_equal(a.advance, b.advance)
	for i in range(a.count):
		assert_equal(a.glyphs[i].gid, b.glyphs[i].gid)
		assert_equal(a.glyphs[i].x_advance, b.glyphs[i].x_advance)
		assert_equal(a.glyphs[i].x_offset, b.glyphs[i].x_offset)
		assert_equal(a.glyphs[i].y_offset, b.glyphs[i].y_offset)
	ui_renderer renderer
	ui_render_init_headless(&renderer)
	ui_render_begin(&renderer, 200, 60)
	assert_equal(1, ui_draw_shaped_run(&renderer, 4.0, 4.0, b, ui_gray(1.0)))
	ui_render_destroy(&renderer)
	ui_shaped_run_free(a)
	ui_shaped_run_free(b)
	# A paragraph shaped in a hinted strike shapes every item, including
	# fallback-face ones, in hinted strikes of the same size.
	int jp = ui_font_face_load_ttf(c"tests/data/fonts/NotoSansJP-subset.otf")
	asserts(c"cjk face", jp >= 0)
	ui_font_add_fallback(jp)
	char* mixed = c"Ab \xe6\x97\xa5 12"
	ui_paragraph* p = ui_paragraph_shape(mixed, strlen(mixed), ui_font_strike_hinted(UI_FACE_REGULAR, 12, UI_HINT_LIGHT), UI_SHAPE_LTR)
	assert_equal(UI_SHAPE_OK, p.status)
	asserts(c"items", p.item_count > 0)
	int fallback_items = 0
	for i in range(p.item_count):
		assert_equal(UI_HINT_LIGHT, ui_font_strike_hinting(p.items[i].strike))
		assert_equal(12, ui_font_strike_ppem(p.items[i].strike))
		if (p.items[i].face == jp): fallback_items = fallback_items + 1
	asserts(c"the kanji comes from the fallback face", fallback_items > 0)
	ui_paragraph* q = ui_paragraph_shape(mixed, strlen(mixed), ui_font_strike(UI_FACE_REGULAR, 12), UI_SHAPE_LTR)
	assert_equal(q.advance, p.advance)
	assert_equal(UI_HINT_NONE, ui_font_strike_hinting(q.items[0].strike))
	ui_paragraph_free(p)
	ui_paragraph_free(q)
