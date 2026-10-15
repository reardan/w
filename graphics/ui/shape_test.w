# wbuild: name=graphics_ui_shape_test arch_only=x64
# HarfBuzz is optional; unavailable hosts report a visible skip. CPU rendering
# tests need no display. Font fixture inputs are already checked in.
import lib.testing
import graphics.ui.shape

void test_shape_validation():
	ui_shaped_run* run = ui_shape_utf8(c"\xff", 1, 0, UI_SHAPE_LTR, 0, 0, 100)
	assert_equal(UI_SHAPE_INVALID, run.status)
	ui_shaped_run_free(run)
	run = ui_shape_utf8(c"a", 1, -1, UI_SHAPE_LTR, 0, 0, 100)
	assert_equal(UI_SHAPE_INVALID, run.status)
	ui_shaped_run_free(run)
	run = ui_shape_utf8(c"a", 65537, 0, UI_SHAPE_LTR, 0, 0, 100)
	assert_equal(UI_SHAPE_LIMIT, run.status)
	ui_shaped_run_free(run)

# Replace the fixture face's GSUB with a minimal, deterministic Latin liga:
# f i -> A. Testing a known substitution avoids depending on a system font's
# optional ligatures. ScriptList/FeatureList/LookupList are OpenType structures.
int ligature_face(int face):
	ttf_font* font = ui_font_face_font(face)
	int size = font.size
	char* data = cast(char*, malloc(size + 80))
	mem_copy(data, font.data, size)
	mem_fill[char](data + size, 0, 80)
	int table = 0
	for i in range(load_be16(data + 4)):
		int offset = 12 + i * 16
		if (load_be32(data + offset) == 0x47535542): table = offset
	asserts(c"fixture has GSUB", table != 0)
	store_be32(data + table + 8, size)
	store_be32(data + table + 12, 80)
	char* g = data + size
	store_be32(g, 0x00010000)
	store_be16(g + 4, 10)
	store_be16(g + 6, 30)
	store_be16(g + 8, 44)
	store_be16(g + 10, 1)
	store_be32(g + 12, 0x6c61746e)
	store_be16(g + 16, 8)
	store_be16(g + 18, 4)
	store_be16(g + 24, 65535)
	store_be16(g + 26, 1)
	store_be16(g + 30, 1)
	store_be32(g + 32, 0x6c696761)
	store_be16(g + 36, 8)
	store_be16(g + 40, 1)
	store_be16(g + 44, 1)
	store_be16(g + 46, 4)
	store_be16(g + 48, 4)
	store_be16(g + 52, 1)
	store_be16(g + 54, 8)
	store_be16(g + 56, 1)
	store_be16(g + 58, 18)
	store_be16(g + 60, 1)
	store_be16(g + 62, 8)
	store_be16(g + 64, 1)
	store_be16(g + 66, 4)
	store_be16(g + 68, ttf_glyph_id(font, 65))
	store_be16(g + 70, 2)
	store_be16(g + 72, ttf_glyph_id(font, 105))
	store_be16(g + 74, 1)
	store_be16(g + 76, 1)
	store_be16(g + 78, ttf_glyph_id(font, 102))
	int result = ui_font_face_load_bytes(data, size + 80)
	free(data)
	return result

void test_native_shaping_and_rendering():
	if (!ui_shape_available()):
		print(c"SKIP: HarfBuzz Linux x64 shaping unavailable\n")
		return
	int face = ui_font_face_load_ttf(c"tools/ui/LiberationSans-Regular.ttf")
	asserts(c"loaded face", face >= 0)
	int strike = ui_font_strike(face, 24)
	ui_shaped_run* run = ui_shape_utf8(c"q\xcc\x81", 3, strike, UI_SHAPE_LTR, 0, 0, 10)
	assert_equal(UI_SHAPE_OK, run.status)
	assert_equal(2, run.count)
	assert_equal(0, run.glyphs[0].cluster)
	assert_equal(0, run.glyphs[1].cluster)
	assert_equal(0, run.glyphs[1].x_advance)
	asserts(c"mark positioned", (run.glyphs[1].x_offset != 0) || (run.glyphs[1].y_offset != 0))
	ui_renderer renderer
	ui_render_init_headless(&renderer)
	ui_render_begin(&renderer, 200, 100)
	assert_equal(1, ui_draw_shaped_run(&renderer, 20.0, 20.0, run, ui_gray(1.0)))
	assert_equal(12, renderer.layer_vert_count[UI_LAYER_BASE])
	ui_glyph mark = ui_font_glyph_id(strike, run.glyphs[1].gid)
	float32 mark_x = 20.0 + cast(float32, run.glyphs[0].x_advance + run.glyphs[1].x_offset) / 64.0 + cast(float32, mark.bearing_x)
	float32 mark_y = 20.0 - cast(float32, run.glyphs[1].y_offset) / 64.0 + cast(float32, ui_font_strike_ascent(strike) - mark.bearing_top)
	asserts(c"positioned mark x", renderer.layer_verts[UI_LAYER_BASE][48] == mark_x)
	asserts(c"positioned mark y", renderer.layer_verts[UI_LAYER_BASE][49] == mark_y)
	int cached = ui_font_st.glyph_count
	ui_draw_shaped_run(&renderer, 20.0, 20.0, run, ui_gray(1.0))
	assert_equal(cached, ui_font_st.glyph_count)
	ui_render_destroy(&renderer)
	ui_shaped_run_free(run)
	run = ui_shape_utf8(c"\xd7\x90\xd7\x91", 4, strike, UI_SHAPE_AUTO, 0, 0, 10)
	assert_equal(UI_SHAPE_OK, run.status)
	assert_equal(UI_SHAPE_RTL, run.direction)
	assert_equal(2, run.count)
	assert_equal(2, run.glyphs[0].cluster)
	assert_equal(0, run.glyphs[1].cluster)
	ui_shaped_run_free(run)
	int synthetic = ui_font_strike(ligature_face(face), 24)
	run = ui_shape_utf8(c"fi", 2, synthetic, UI_SHAPE_LTR, 0, 0, 10)
	assert_equal(UI_SHAPE_OK, run.status)
	assert_equal(1, run.count)
	assert_equal(ttf_glyph_id(ui_font_face_font(face), 65), run.glyphs[0].gid)
	assert_equal(0, run.glyphs[0].cluster)
	ui_shaped_run_free(run)
	run = ui_shape_utf8(c"abc", 3, strike, UI_SHAPE_LTR, 0, 0, 1)
	assert_equal(UI_SHAPE_LIMIT, run.status)
	assert_equal(0, run.count)
	asserts(c"failure has no partial output", run.glyphs == 0)
	ui_shaped_run_free(run)
	run = ui_shape_utf8(c"a\0b", 3, strike, UI_SHAPE_LTR, 0, 0, 10)
	assert_equal(UI_SHAPE_OK, run.status)
	assert_equal(3, run.source_bytes)
	assert_equal(3, run.count)
	ui_shaped_run_free(run)
	run = ui_shape_utf8(0, 0, strike, UI_SHAPE_AUTO, 0, 0, 0)
	assert_equal(UI_SHAPE_OK, run.status)
	assert_equal(0, run.count)
	ui_shaped_run_free(run)
