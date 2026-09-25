# Headless unit tests for the font system's second round (issue #379):
# UTF-8 text, pair kerning, true italic faces, strikes at any size,
# fallback faces, the atlas growing mid-frame, and widgets drawing in
# a loaded face — through ui_render_init_headless, no GL context or
# display. Runs from the repo root (it loads the committed tools/ui
# faces).
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_text_font_test arch_only=x64
import lib.testing
import lib.ttf
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets
import graphics.ui.testing


float32 vert(ui_renderer* r, int index, int field):
	return r.layer_verts[UI_LAYER_BASE][index * 8 + field]


# Quads in the base layer (6 vertices each).
int quads(ui_renderer* r):
	return r.layer_vert_count[UI_LAYER_BASE] / 6


# ---- UTF-8 ------------------------------------------------------------

void test_utf8_decoding():
	int cp = 0
	# "é" (2 bytes), "€" (3), U+1F600 (4).
	assert_equal(2, ui_utf8_next(c"\xc3\xa9", 0, &cp))
	assert_equal(233, cp)
	assert_equal(3, ui_utf8_next(c"\xe2\x82\xac", 0, &cp))
	assert_equal(8364, cp)
	assert_equal(4, ui_utf8_next(c"\xf0\x9f\x98\x80", 0, &cp))
	assert_equal(128512, cp)
	# A stray continuation byte, a truncated sequence and an overlong
	# encoding each read as one U+FFFD byte, so a scan always ends.
	assert_equal(1, ui_utf8_next(c"\xa9x", 0, &cp))
	assert_equal(65533, cp)
	assert_equal(1, ui_utf8_next(c"\xe2\x82", 0, &cp))
	assert_equal(65533, cp)
	assert_equal(1, ui_utf8_next(c"\xc0\xaf", 0, &cp))
	assert_equal(65533, cp)
	# Stepping back lands on the start of the character.
	char* s = c"a\xc3\xa9\xe2\x82\xac"
	assert_equal(3, ui_utf8_prev(s, 6))
	assert_equal(1, ui_utf8_prev(s, 3))
	assert_equal(0, ui_utf8_prev(s, 1))
	# Encoding round-trips.
	char[4] out
	assert_equal(3, ui_utf8_encode(&out[0], 8364))
	assert_equal(226, out[0] & 255)
	assert_equal(3, ui_utf8_next(&out[0], 0, &cp))
	assert_equal(8364, cp)


# Non-ASCII text draws one quad per inked character and measures in
# whole characters: Latin-1, Greek and Cyrillic all come from the
# embedded default faces.
void test_non_ascii_text_draws():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	# "héllo wörld"
	ui_draw_text(&r, 10.0, 20.0, c"h\xc3\xa9llo w\xc3\xb6rld", 2, ui_gray(0.0))
	assert_equal(10, quads(&r))
	ui_glyph e_acute = ui_font_glyph(0, 233)
	asserts(c"e-acute is a real glyph", (e_acute.gid != 0) && (e_acute.w > 0))
	asserts(c"accent reaches above the x-height", e_acute.bearing_top > ui_font_glyph(0, 'e').bearing_top)
	# Omega and Cyrillic zhe.
	asserts(c"Greek", ui_font_glyph(0, 937).gid != 0)
	asserts(c"Cyrillic", ui_font_glyph(1, 1046).gid != 0)
	# Width counts characters, not bytes: "é" is one glyph.
	assert_equal(e_acute.advance, ui_text_width(c"\xc3\xa9", 2))
	assert_equal(ui_text_width(c"h", 2), ui_text_prefix_width(c"h\xc3\xa9", 1, 2))
	assert_equal(ui_text_width(c"h\xc3\xa9", 2), ui_text_prefix_width(c"h\xc3\xa9", 3, 2))
	# Carets land on character boundaries: past the "é" is byte 3.
	assert_equal(3, ui_text_caret_from_x(c"h\xc3\xa9x", 2, ui_text_width(c"h\xc3\xa9", 2) + 1))
	ui_render_destroy(&r)


# A codepoint the strike's face lacks comes from a fallback face; one
# no face has draws the face's .notdef box and still advances.
void test_fallback_faces():
	# An ASCII-only subset of Regular, loaded as a face of its own.
	ttf_font full
	asserts(c"load regular", ttf_load(&full, c"tools/ui/LiberationSans-Regular.ttf"))
	int* ranges = cast(int*, malloc(2 * __word_size__))
	ranges[0] = 32
	ranges[1] = 126
	int size = 0
	char* data = ttf_subset(&full, ranges, 1, &size)
	int face = ui_font_face_load_bytes(data, size)
	free(data)
	asserts(c"subset face loads", face >= 4)
	int strike = ui_font_strike(face, 16)
	ui_glyph a = ui_font_glyph(strike, 'a')
	assert_equal(face, a.face)
	# "é" is not in the subset: the default Regular supplies it.
	ui_glyph e = ui_font_glyph(strike, 233)
	assert_equal(UI_FACE_REGULAR, e.face)
	asserts(c"fallback glyph has ink", e.w > 0)
	# CJK is in no face: .notdef of the strike's own face.
	ui_glyph cjk = ui_font_glyph(strike, 20013)
	assert_equal(face, cjk.face)
	assert_equal(0, cjk.gid)
	asserts(c".notdef advances", cjk.advance > 0)
	# A registered fallback is tried before the default.
	int bold = ui_font_face_load_ttf(c"tools/ui/LiberationSans-Bold.ttf")
	ui_font_add_fallback(bold)
	assert_equal(bold, ui_font_glyph(strike, 246).face)
	ttf_free(&full)


# ---- kerning ----------------------------------------------------------

# "AV" sets tighter than its two advances; the draw path and every
# measurement agree on the kerned pen.
void test_kerning():
	ui_glyph a = ui_font_glyph(0, 'A')
	ui_glyph v = ui_font_glyph(0, 'V')
	int kern = ui_font_kern(0, &a, &v)
	asserts(c"AV kerns", kern < 0)
	assert_equal(a.advance + v.advance + kern, ui_text_width(c"AV", 2))
	assert_equal(a.advance, ui_text_prefix_width(c"AV", 1, 2))
	# Unkerned pairs are plain sums.
	ui_glyph o = ui_font_glyph(0, 'o')
	assert_equal(o.advance * 2, ui_text_width(c"oo", 2))
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_text(&r, 0.0, 0.0, c"AV", 2, ui_gray(0.0))
	assert_equal(2, quads(&r))
	# The V quad starts at the kerned pen plus its bearing.
	asserts(c"V drawn at the kerned pen", vert(&r, 6, 0) == cast(float32, a.advance + kern + v.bearing_x))
	ui_render_destroy(&r)


# ---- italic -----------------------------------------------------------

# The default faces have true italics: UI_TEXT_ITALIC swaps in the
# Italic (or Bold Italic) face at the same size and draws it upright —
# no shear — with its own advances.
void test_true_italic():
	int italic = ui_font_strike_italic(0)
	asserts(c"body has an italic", italic >= 0)
	assert_equal(UI_FACE_ITALIC, ui_font_strike_face(italic))
	assert_equal(ui_font_strike_ppem(0), ui_font_strike_ppem(italic))
	assert_equal(UI_FACE_BOLD_ITALIC, ui_font_strike_face(ui_font_strike_italic(1)))
	# An italic strike is its own italic.
	assert_equal(italic, ui_font_strike_italic(italic))
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_text_styled(&r, 20.0, 20.0, c"l", 2, UI_TEXT_ITALIC, ui_gray(0.0))
	assert_equal(1, quads(&r))
	ui_glyph g = ui_font_glyph(italic, 'l')
	# Upright quad: left edge vertical.
	asserts(c"not sheared", vert(&r, 0, 0) == vert(&r, 5, 0))
	asserts(c"italic texels", vert(&r, 0, 2) == ui_render_u(g.x))
	# The italic outline leans on its own: wider ink than the roman 'l'.
	asserts(c"slanted outline", g.w > ui_font_glyph(0, 'l').w)
	asserts(c"italic measures in its own advances", ui_text_width_styled(c"l", 0, UI_TEXT_ITALIC) == g.advance)
	ui_render_destroy(&r)


# ---- any size ---------------------------------------------------------

# Any size from 4 to 200 is its own strike, rasterized from the
# outlines: metrics scale with the size and glyphs stay 1:1 texels.
void test_any_size():
	int big = ui_font_strike(UI_FACE_REGULAR, 48)
	asserts(c"48 px strike", big >= 2)
	assert_equal(big, ui_font_strike(UI_FACE_REGULAR, 48))
	assert_equal(big, ui_font_strike_resized(0, 48))
	assert_equal(48, ui_font_strike_ppem(big))
	# 3x the body size: metrics within rounding of 3x.
	int ascent = ui_font_strike_ascent(big)
	asserts(c"ascent scales", (ascent >= ui_font_strike_ascent(0) * 3 - 3) && (ascent <= ui_font_strike_ascent(0) * 3 + 3))
	ui_glyph h = ui_font_glyph(big, 'H')
	ui_glyph h16 = ui_font_glyph(0, 'H')
	asserts(c"glyph scales", (h.h >= h16.h * 3 - 6) && (h.h <= h16.h * 3 + 3))
	# Every size in range works, odd ones included; out of range fails.
	asserts(c"13 px", ui_font_strike(UI_FACE_BOLD, 13) >= 0)
	assert_equal(0 - 1, ui_font_strike(UI_FACE_REGULAR, 3))
	assert_equal(0 - 1, ui_font_strike(UI_FACE_REGULAR, 201))
	assert_equal(0 - 1, ui_font_strike(99, 16))
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 640, 480)
	ui_draw_text_strike(&r, 0.0, 0.0, c"H", big, UI_TEXT_PLAIN, ui_gray(0.0))
	# Drawn at the rasterized size: one texel per pixel.
	assert_equal(1, quads(&r))
	asserts(c"1:1 width", vert(&r, 1, 0) - vert(&r, 0, 0) == cast(float32, h.w))
	asserts(c"1:1 height", vert(&r, 2, 1) - vert(&r, 0, 1) == cast(float32, h.h))
	ui_render_destroy(&r)


# Glyphs rasterized during a frame can double the atlas; the renderer
# rescales the v of everything batched before, so each quad still
# samples its own texels.
void test_atlas_grows_mid_frame():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 640, 480)
	ui_draw_text(&r, 0.0, 0.0, c"x", 2, ui_gray(0.0))
	ui_glyph x = ui_font_glyph(0, 'x')
	int rows = ui_font_atlas_rows()
	# Big glyphs until the atlas doubles.
	int huge = ui_font_strike(UI_FACE_BOLD, 180)
	int cp = 'A'
	while ((ui_font_atlas_rows() == rows) && (cp <= 'Z')):
		ui_font_glyph(huge, cp)
		cp = cp + 1
	asserts(c"atlas grew", ui_font_atlas_rows() > rows)
	# Until the sync, v still uses the frame's denominator.
	asserts(c"frame denominator", vert(&r, 0, 3) == cast(float32, x.y) / cast(float32, rows))
	ui_render_end(&r)
	asserts(c"rescaled v", vert(&r, 0, 3) == cast(float32, x.y) / cast(float32, ui_font_atlas_rows()))
	assert_equal(ui_font_atlas_rows(), ui_font_uv_rows())
	ui_render_destroy(&r)


# ---- widgets in a loaded font -----------------------------------------

# ui_theme_use_font points every widget at another face and size: they
# measure and draw with it, and widget_height grows to fit.
void test_widgets_use_a_loaded_font():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	int face = ui_font_face_load_ttf(c"tools/ui/LiberationSans-Bold.ttf")
	int strike = ui_theme_use_font(&fx.theme, face, 30)
	asserts(c"strike made", strike >= 0)
	assert_equal(strike, ui_font_strike_from_scale(fx.theme.text_scale))
	assert_equal(ui_text_height_strike(strike), ui_text_height(fx.theme.text_scale))
	asserts(c"taller widgets", fx.theme.widget_height >= ui_text_height_strike(strike) + fx.theme.pad * 2)
	ui_begin(ctx, 640, 480)
	ui_label(ctx, c"W")
	ui_end(ctx)
	assert_equal(1, quads(&fx.r))
	ui_glyph w = ui_font_glyph(strike, 'W')
	asserts(c"label drew the loaded glyph", vert(&fx.r, 0, 2) == ui_render_u(w.x))
	asserts(c"at the loaded size", vert(&fx.r, 2, 1) - vert(&fx.r, 0, 1) == cast(float32, w.h))
	# Too-small sizes leave the theme alone.
	int scale = fx.theme.text_scale
	assert_equal(0 - 1, ui_theme_use_font(&fx.theme, face, 2))
	assert_equal(scale, fx.theme.text_scale)
	ui_render_destroy(&fx.r)


# The textbox takes typed codepoints as UTF-8 and edits whole
# characters.
void test_textbox_edits_utf8():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state tb
	ui_textbox_init(&tb)
	ui_test_click(ctx, 20, 20)
	ui_begin(ctx, 320, 240)
	ui_textbox(ctx, 200.0, &tb)
	ui_end(ctx)
	ui_test_char(ctx, 'a')
	ui_test_char(ctx, 233)
	ui_test_char(ctx, 937)
	ui_begin(ctx, 320, 240)
	ui_textbox(ctx, 200.0, &tb)
	ui_end(ctx)
	# a (1) + é (2) + Ω (2) bytes.
	assert_equal(5, tb.length)
	assert_equal(5, tb.caret)
	asserts(c"utf-8 text", strcmp(&tb.text[0], c"a\xc3\xa9\xce\xa9") == 0)
	# Left steps over Ω whole; backspace then deletes é whole (a frame
	# apart: the textbox drains characters before navigation).
	ui_test_nav(ctx, GFX_NAV_LEFT)
	ui_begin(ctx, 320, 240)
	ui_textbox(ctx, 200.0, &tb)
	ui_end(ctx)
	assert_equal(3, tb.caret)
	ui_test_char(ctx, 8)
	ui_begin(ctx, 320, 240)
	ui_textbox(ctx, 200.0, &tb)
	ui_end(ctx)
	asserts(c"deleted e-acute", strcmp(&tb.text[0], c"a\xce\xa9") == 0)
	assert_equal(1, tb.caret)
	# C1 controls are not text.
	ui_test_char(ctx, 150)
	ui_begin(ctx, 320, 240)
	ui_textbox(ctx, 200.0, &tb)
	ui_end(ctx)
	assert_equal(3, tb.length)
	ui_render_destroy(&fx.r)


void textarea_frame(ui_context* ctx, ui_textarea_state* st):
	ui_begin(ctx, 320, 240)
	ui_textarea(ctx, ui_rect_new(10.0, 10.0, 200.0, 120.0), st)
	ui_end(ctx)


# The textarea does the same over its buffer (a frame per step: it
# drains characters before navigation).
void test_textarea_edits_utf8():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"\xc3\xa9t\xc3\xa9")
	ui_test_click(ctx, 12, 12)
	textarea_frame(ctx, &st)
	ui_textarea_set_caret(&st, 0)
	ui_test_nav(ctx, GFX_NAV_RIGHT)
	textarea_frame(ctx, &st)
	assert_equal(2, ui_textarea_caret_offset(&st))
	ui_test_char(ctx, 1046)
	textarea_frame(ctx, &st)
	asserts(c"inserted after the first character", strcmp(st.buf.data, c"\xc3\xa9\xd0\x96t\xc3\xa9") == 0)
	assert_equal(4, ui_textarea_caret_offset(&st))
	ui_test_nav(ctx, GFX_NAV_DELETE)
	textarea_frame(ctx, &st)
	ui_test_char(ctx, 8)
	textarea_frame(ctx, &st)
	asserts(c"deleted whole characters", strcmp(st.buf.data, c"\xc3\xa9\xc3\xa9") == 0)
	assert_equal(2, ui_textarea_caret_offset(&st))
	ui_textarea_free(&st)
	ui_render_destroy(&fx.r)
