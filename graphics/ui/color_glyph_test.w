# wbuild: name=graphics_ui_color_glyph_test arch_only=x64 deps=tests/data/fonts/ deps=tests/data/color_glyphs/
# Color glyphs through the atlas and renderer (issue #827): COLR, sbix
# and CBDT text drawn by ui_draw_text and ui_draw_shaped_run (through
# the itemizer, which prefers a color face for emoji presentation),
# rendered headless by graphics.ui.render_soft and compared with the
# golden images in tests/data/color_glyphs/. Color layers draw untinted
# but for the text's alpha; foreground layers take the text color.
#
# W_UPDATE_GOLDENS=1 bin/graphics_ui_color_glyph_test rewrites the
# goldens; a mismatch writes the actual image to bin/<name>_actual.png.
import lib.testing
import lib.stream
import lib.env
import structures.string
import graphics.image.png
import graphics.ui.text
import graphics.ui.itemize
import graphics.ui.render_soft


int v0_face
int v1_face
int sbix_face
int emoji_face


void load_faces():
	if (v0_face != 0): return
	v0_face = ui_font_face_load_ttf(c"tests/data/fonts/ColorTestCOLRv0.ttf")
	v1_face = ui_font_face_load_ttf(c"tests/data/fonts/ColorTestCOLRv1.ttf")
	sbix_face = ui_font_face_load_ttf(c"tests/data/fonts/ColorTestSbix.ttf")
	emoji_face = ui_font_face_load_ttf(c"tests/data/fonts/NotoColorEmoji-subset.ttf")
	asserts(c"fixture faces load", (v0_face > 0) && (v1_face > 0) && (sbix_face > 0) && (emoji_face > 0))
	ui_font_add_fallback(emoji_face)
	ui_font_add_fallback(v0_face)


ui_color ink():
	return ui_color_new(0.1, 0.2, 0.6, 1.0)


int strike_of(int face, int ppem):
	int strike = ui_font_strike(face, ppem)
	asserts(c"strike", strike >= 0)
	return strike


char* render(ui_renderer* r, int w, int h):
	ui_render_end(r)
	return ui_render_software(r, w, h, ui_gray(1.0))


# Compare rgba with tests/data/color_glyphs/<name>.png, each channel
# within 2; or rewrite the golden under W_UPDATE_GOLDENS.
void expect_golden(char* name, char* rgba, int w, int h):
	string_builder* path = string_new()
	string_append(path, c"tests/data/color_glyphs/")
	string_append(path, name)
	string_append(path, c".png")
	char* update = env_get(c"W_UPDATE_GOLDENS")
	if ((update != 0) && (update[0] != 0)):
		string_builder* png = png_encode_rgba(w, h, rgba)
		wstream* out = stream_open_write(path.data)
		asserts(c"golden writable", out != 0)
		stream_write(out, png.data, png.length)
		stream_close(out)
		string_free(png)
		string_free(path)
		return
	int size = 0
	char* data = ttf_read_file(path.data, &size)
	asserts(c"golden present", data != 0)
	wresult[rgba_image*]* decoded = png_decode_n(data, size, 0)
	asserts(c"golden decodes", decoded.ok)
	rgba_image* golden = decoded.value
	int bad = 0
	if ((golden.width != w) || (golden.height != h)): bad = 1
	else:
		for i in range(w * h * 4):
			int d = (golden.pixels[i] & 255) - (rgba[i] & 255)
			if ((d > 2) || (d < -2)): bad = bad + 1
	if (bad):
		string_builder* actual = string_new()
		string_append(actual, c"bin/")
		string_append(actual, name)
		string_append(actual, c"_actual.png")
		string_builder* png = png_encode_rgba(w, h, rgba)
		wstream* out = stream_open_write(actual.data)
		if (out != 0):
			stream_write(out, png.data, png.length)
			stream_close(out)
		print_error(c"golden mismatch: ")
		print_error(path.data)
		print_error(c" (actual in ")
		print_error(actual.data)
		print_error(c")\n")
	assert_equal(0, bad)
	rgba_image_free(golden)
	free(cast(char*, decoded))
	free(data)
	string_free(path)


# The RGBA pixel at (x, y) as 0xRRGGBB (alpha is always opaque here).
int pixel(char* rgba, int w, int x, int y):
	char* p = &rgba[(y * w + x) * 4]
	return ((p[0] & 255) << 16) | ((p[1] & 255) << 8) | (p[2] & 255)


# The emoji paragraph: Latin, a CBDT emoji, a skin-tone ligature, a ZWJ
# family ligature and a heart with VS16.
char* emoji_text():
	return c"Hi \xf0\x9f\x98\x80\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7\xe2\x9d\xa4\xef\xb8\x8f!"


void test_colr_text_golden():
	load_faces()
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 84)
	ui_draw_text_strike(&r, 4.0, 2.0, c"ABC", strike_of(v0_face, 32), UI_TEXT_PLAIN, ink())
	ui_draw_text_strike(&r, 4.0, 42.0, c"ABCDEFGH", strike_of(v1_face, 32), UI_TEXT_PLAIN, ink())
	char* rgba = render(&r, 320, 84)
	expect_golden(c"colr", rgba, 320, 84)
	free(rgba)
	ui_render_destroy(&r)


void test_bitmap_text_golden():
	load_faces()
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 400, 130)
	ui_draw_text_strike(&r, 4.0, 2.0, c"ABC", strike_of(sbix_face, 16), UI_TEXT_PLAIN, ink())
	ui_draw_text_strike(&r, 64.0, 2.0, c"ABC", strike_of(sbix_face, 40), UI_TEXT_PLAIN, ink())
	char* text = emoji_text()
	int body = strike_of(UI_FACE_REGULAR, 20)
	ui_paragraph* p = ui_paragraph_shape(text, strlen(text), body, UI_SHAPE_LTR)
	assert_equal(UI_SHAPE_OK, p.status)
	assert_equal(1, ui_paragraph_draw(&r, 4.0, 46.0, p, ink()))
	ui_paragraph_free(p)
	p = ui_paragraph_shape(text, strlen(text), strike_of(UI_FACE_REGULAR, 40), UI_SHAPE_LTR)
	ui_paragraph_draw(&r, 4.0, 74.0, p, ink())
	ui_paragraph_free(p)
	char* rgba = render(&r, 400, 130)
	expect_golden(c"bitmap", rgba, 400, 130)
	free(rgba)
	ui_render_destroy(&r)


void test_foreground_layers_take_text_color():
	load_faces()
	int strike = strike_of(v0_face, 50)
	ui_color red = ui_color_new(1.0, 0.0, 0.0, 1.0)
	ui_color green = ui_color_new(0.0, 1.0, 0.0, 1.0)
	char*[2] shots
	for k in range(2):
		ui_renderer r
		ui_render_init_headless(&r)
		ui_render_begin(&r, 64, 64)
		if (k == 0): ui_draw_text_strike(&r, 0.0, 0.0, c"A", strike, UI_TEXT_PLAIN, red)
		else: ui_draw_text_strike(&r, 0.0, 0.0, c"A", strike, UI_TEXT_PLAIN, green)
		shots[k] = render(&r, 64, 64)
		ui_render_destroy(&r)
	int baseline = ui_font_strike_ascent(strike)
	# The triangle (palette 0xFFFF) at font (500, 400): the text color.
	assert_equal_hex(0xff0000, pixel(shots[0], 64, 25, baseline - 20))
	assert_equal_hex(0x00ff00, pixel(shots[1], 64, 25, baseline - 20))
	# The square at (110, 10), outside the triangle and circle: palette
	# red whatever the text color.
	assert_equal_hex(0xff0000, pixel(shots[0], 64, 5, baseline - 1))
	assert_equal_hex(0xff0000, pixel(shots[1], 64, 5, baseline - 1))
	free(shots[0])
	free(shots[1])


void test_color_layers_are_untinted():
	load_faces()
	int strike = strike_of(UI_FACE_REGULAR, 24)
	char* smile = c"\xf0\x9f\x98\x80"
	char*[3] shots
	for k in range(3):
		ui_renderer r
		ui_render_init_headless(&r)
		ui_render_begin(&r, 40, 40)
		ui_color color = ui_color_new(1.0, 0.0, 0.0, 1.0)
		if (k == 1): color = ui_color_new(0.0, 0.0, 1.0, 1.0)
		if (k == 2): color.a = 0.5
		# Codepoint text falls back to the color face for an emoji.
		ui_draw_text_strike(&r, 2.0, 2.0, smile, strike, UI_TEXT_PLAIN, color)
		shots[k] = render(&r, 40, 40)
		ui_render_destroy(&r)
	int same = 1
	int faded = 0
	int inked = 0
	for i in range(40 * 40 * 4):
		if (shots[0][i] != shots[1][i]): same = 0
		if ((shots[0][i] & 255) != 255): inked = 1
		# Half the text alpha: halfway between the glyph and white.
		int full = shots[0][i] & 255
		int half = shots[2][i] & 255
		int want = (full + 255 + 1) / 2
		if ((half - want > 2) || (want - half > 2)): faded = faded + 1
	assert1(inked)
	assert1(same)
	assert_equal(0, faded)
	free(shots[0])
	free(shots[1])
	free(shots[2])


void test_itemizer_prefers_color_face_for_emoji():
	load_faces()
	int body = strike_of(UI_FACE_REGULAR, 20)
	char* text = emoji_text()
	ui_paragraph* p = ui_paragraph_shape(text, strlen(text), body, UI_SHAPE_LTR)
	assert_equal(UI_SHAPE_OK, p.status)
	assert_equal(3, p.item_count)
	assert_equal(UI_FACE_REGULAR, p.items[0].face)
	assert_equal(emoji_face, p.items[1].face)
	assert_equal(UI_FACE_REGULAR, p.items[2].face)
	# Four emoji glyphs: the skin tone and the ZWJ family are GSUB
	# ligatures, and VS16 adds no glyph.
	assert_equal(4, p.items[1].run.count)
	ui_paragraph_free(p)
	# 'A' + VS16 asks for emoji: the COLR face's colored A wins over the
	# Regular face that also has 'A'.
	p = ui_paragraph_shape(c"A\xef\xb8\x8f", 4, body, UI_SHAPE_LTR)
	assert_equal(1, p.item_count)
	assert_equal(v0_face, p.items[0].face)
	ui_paragraph_free(p)
	p = ui_paragraph_shape(c"A", 1, body, UI_SHAPE_LTR)
	assert_equal(UI_FACE_REGULAR, p.items[0].face)
	ui_paragraph_free(p)
	# 'A' + VS15 in a strike of the color face asks for text.
	p = ui_paragraph_shape(c"A\xef\xb8\x8e", 4, strike_of(v0_face, 20), UI_SHAPE_LTR)
	assert_equal(UI_FACE_REGULAR, p.items[0].face)
	ui_paragraph_free(p)
	# Codepoint text: an Emoji_Presentation character prefers the color
	# fallback, others keep the text face.
	int gid = 0
	assert_equal(emoji_face, ui_font_resolve(UI_FACE_REGULAR, 0x1f600, &gid))
	assert_equal(UI_FACE_REGULAR, ui_font_resolve(UI_FACE_REGULAR, 'A', &gid))
	assert1(ui_font_face_has_color(emoji_face))
	assert_equal(0, ui_font_face_has_color(UI_FACE_REGULAR))
	assert1(ui_font_face_glyph_has_color(v0_face, ttf_glyph_id(ui_font_face_font(v0_face), 'A')))
	assert_equal(0, ui_font_face_glyph_has_color(v0_face, ttf_glyph_id(ui_font_face_font(v0_face), 'C')))
	# Default-ignorables draw nothing in codepoint text.
	assert_equal(ui_text_width_strike(c"A", body), ui_text_width_strike(c"A\xef\xb8\x8f\xe2\x80\x8d", body))


void test_color_atlas_growth_mid_frame():
	load_faces()
	int small = strike_of(sbix_face, 24)
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 200, 200)
	ui_draw_text_strike(&r, 0.0, 0.0, c"A", small, UI_TEXT_PLAIN, ink())
	# Enough new color glyphs to grow the color atlas several times.
	int rows = ui_font_color_atlas_rows()
	int ppem = 60
	while ((ui_font_color_atlas_rows() <= rows * 2) && (ppem < 200)):
		ui_draw_text_strike(&r, 0.0, 100.0, c"AB", strike_of(v1_face, ppem), UI_TEXT_PLAIN, ink())
		ppem = ppem + 1
	asserts(c"color atlas grew", ui_font_color_atlas_rows() > rows * 2)
	char* first = render(&r, 200, 200)
	ui_render_destroy(&r)
	ui_render_init_headless(&r)
	ui_render_begin(&r, 200, 200)
	ui_draw_text_strike(&r, 0.0, 0.0, c"A", small, UI_TEXT_PLAIN, ink())
	char* again = render(&r, 200, 200)
	ui_render_destroy(&r)
	# The glyph batched before the atlas grew samples the same texels.
	for y in range(40):
		for x in range(40): assert_equal_hex(pixel(again, 200, x, y), pixel(first, 200, x, y))
	free(first)
	free(again)


void test_device_scale_draws_device_strike():
	load_faces()
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_set_pixel_scale(&r, 2.0)
	ui_render_begin(&r, 40, 40)
	ui_draw_text_strike(&r, 2.0, 2.0, c"\xf0\x9f\x98\x80", strike_of(UI_FACE_REGULAR, 16), UI_TEXT_PLAIN, ink())
	# One quad, from the 32 ppem device strike, at logical size.
	int verts = r.layer_vert_count[UI_LAYER_BASE]
	assert_equal(6, verts)
	float32* v = r.layer_verts[UI_LAYER_BASE]
	float32 width = v[8] - v[0]
	asserts(c"device glyph at logical size", (width > 18.0) && (width < 22.0))
	char* rgba = render(&r, 40, 40)
	assert1(pixel(rgba, 40, 12, 10) != 0xffffff)
	free(rgba)
	ui_render_destroy(&r)
