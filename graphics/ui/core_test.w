# Unit tests for the pure graphics/ui core: rect geometry, theme token
# parity, baked glyph data, atlas construction, text measurement. No
# GL or windowing imports, so it runs on the default 32-bit target,
# x64, and wasm alike.
# wbuild: name=graphics_ui_core_test x64 group=wasm_smoke_test@wasm
import lib.testing
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font_data
import graphics.ui.font


void test_rect_contains_and_edges():
	ui_rect r = ui_rect_new(10.0, 20.0, 30.0, 40.0)
	assert_equal(1, ui_rect_contains(r, 10.0, 20.0))
	assert_equal(1, ui_rect_contains(r, 39.0, 59.0))
	# right/bottom edges are exclusive
	assert_equal(0, ui_rect_contains(r, 40.0, 30.0))
	assert_equal(0, ui_rect_contains(r, 20.0, 60.0))
	assert_equal(0, ui_rect_contains(r, 9.0, 30.0))


void test_rect_inset():
	ui_rect r = ui_rect_inset(ui_rect_new(10.0, 10.0, 20.0, 20.0), 4.0)
	asserts(c"inset x", r.x == 14.0)
	asserts(c"inset y", r.y == 14.0)
	asserts(c"inset w", r.w == 12.0)
	asserts(c"inset h", r.h == 12.0)


void test_theme_presets_share_tokens_with_different_values():
	ui_theme light
	ui_theme dark
	ui_theme_light(&light)
	ui_theme_dark(&dark)
	# grayscale default: background/text are gray in both
	asserts(c"light bg gray", light.background.r == light.background.g)
	asserts(c"dark bg gray", dark.background.r == dark.background.b)
	# modes differ where it matters, metrics agree
	asserts(c"bg differs", light.background.r != dark.background.r)
	asserts(c"text differs", light.text.r != dark.text.r)
	assert_equal(light.unit, dark.unit)
	assert_equal(light.widget_height, dark.widget_height)
	assert_equal(8, light.unit)


void test_glyph_bits():
	# 'A' has ink, space does not; out-of-range maps to space.
	char* a = ui_font_glyph_bits(65)
	int ink = 0
	int i = 0
	while (i < 8):
		ink = ink | (a[i] & 255)
		i = i + 1
	asserts(c"A has ink", ink != 0)

	char* sp = ui_font_glyph_bits(32)
	int blank = 0
	i = 0
	while (i < 8):
		blank = blank | (sp[i] & 255)
		i = i + 1
	assert_equal(0, blank)

	char* mapped = ui_font_glyph_bits(200)
	i = 0
	while (i < 8):
		assert_equal(sp[i] & 255, mapped[i] & 255)
		i = i + 1


void test_atlas_cells():
	char* pixels = ui_font_build_atlas()
	int width = ui_font_atlas_w()

	# 'A' is cell 33 (65 - 32): its cell has both ink and background.
	int cell = 65 - ui_font_first_char()
	int cell_x = (cell % ui_font_atlas_cols()) * 8
	int cell_y = (cell / ui_font_atlas_cols()) * 8
	int ink = 0
	int background = 0
	int row = 0
	while (row < 8):
		int col = 0
		while (col < 8):
			int value = pixels[(cell_y + row) * width + cell_x + col] & 255
			if (value == 255):
				ink = ink + 1
			else:
				assert_equal(0, value)
				background = background + 1
			col = col + 1
		row = row + 1
	asserts(c"A cell has ink", ink > 0)
	asserts(c"A cell has background", background > 0)

	# The white cell is solid 255.
	int white_x = (ui_font_white_cell() % ui_font_atlas_cols()) * 8
	int white_y = (ui_font_white_cell() / ui_font_atlas_cols()) * 8
	row = 0
	while (row < 8):
		int col2 = 0
		while (col2 < 8):
			assert_equal(255, pixels[(white_y + row) * width + white_x + col2] & 255)
			col2 = col2 + 1
		row = row + 1
	free(pixels)


void test_text_measurement():
	assert_equal(48, ui_text_width(c"abc", 2))
	assert_equal(0, ui_text_width(c"", 2))
	assert_equal(16, ui_text_height(2))
