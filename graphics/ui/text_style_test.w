# Headless unit tests for text styles and runtime fonts (issue #379):
# underline/strikethrough lines at the face's decoration metrics,
# italic's baseline shear for a face with no italic, and
# ui_font_load_ttf strikes matching the embedded default glyph for
# glyph — all through ui_render_init_headless, no GL context or
# display. Runs from the repo root (it loads the
# committed tools/ui faces).
# x64-only: the renderer imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_text_style_test arch_only=x64
import lib.testing
import lib.ttf
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text


float32 vert(ui_renderer* r, int index, int field):
	return r.layer_verts[UI_LAYER_BASE][index * 8 + field]


# Quads in the base layer (6 vertices each).
int quads(ui_renderer* r):
	return r.layer_vert_count[UI_LAYER_BASE] / 6


void test_plain_text_is_glyphs_only():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_text(&r, 10.0, 20.0, c"Hi there", 2, ui_gray(0.0))
	# Seven inked glyphs; the space pushes nothing.
	assert_equal(7, quads(&r))
	ui_render_destroy(&r)


# The underline is one extra quad under the run: the run's advance
# width, at the strike's underline row below the baseline.
void test_underline_spans_the_run():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_text_styled(&r, 10.0, 20.0, c"Hi there", 2, UI_TEXT_UNDERLINE, ui_gray(0.0))
	assert_equal(8, quads(&r))
	int q = 7 * 6
	float32 baseline = 20.0 + cast(float32, ui_font_ascent(0))
	asserts(c"underline x", vert(&r, q, 0) == 10.0)
	asserts(c"underline y", vert(&r, q, 1) == baseline + cast(float32, ui_font_underline_top(0)))
	float32 width = cast(float32, ui_text_width(c"Hi there", 2))
	asserts(c"underline right", vert(&r, q + 2, 0) == 10.0 + width)
	asserts(c"underline thickness", vert(&r, q + 2, 1) - vert(&r, q, 1) == cast(float32, ui_font_underline_thickness(0)))
	asserts(c"underline sits below the baseline", ui_font_underline_top(0) > 0)
	ui_render_destroy(&r)


void test_strikethrough_crosses_the_x_height():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_text_styled(&r, 10.0, 20.0, c"xo", 2, UI_TEXT_STRIKETHROUGH, ui_gray(0.0))
	assert_equal(3, quads(&r))
	int q = 2 * 6
	float32 baseline = 20.0 + cast(float32, ui_font_ascent(0))
	float32 line_y = baseline + cast(float32, ui_font_strikeout_top(0))
	asserts(c"strike y", vert(&r, q, 1) == line_y)
	# Between the baseline and the top of the x-height ink.
	ui_glyph x = ui_font_glyph(0, 'x')
	asserts(c"strike above the baseline", line_y < baseline)
	asserts(c"strike below the x-height", line_y > baseline - cast(float32, x.bearing_top))
	ui_render_destroy(&r)


# Both decorations together, on the title strike.
void test_underline_and_strikethrough_combine():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_text_styled(&r, 0.0, 0.0, c"ab", 3, UI_TEXT_UNDERLINE | UI_TEXT_STRIKETHROUGH, ui_gray(0.0))
	assert_equal(4, quads(&r))
	asserts(c"title underline is thicker", ui_font_underline_thickness(1) >= ui_font_underline_thickness(0))
	ui_render_destroy(&r)


# A face with no italic companion (a loaded file, unpaired) gets a
# synthetic oblique: italic keeps the glyph's texels and advance, and
# leans the quad about the baseline — the top edge moves right by
# skew * its height above the baseline, the bottom edge by skew * its
# own (negative below the baseline).
void test_italic_shears_about_the_baseline():
	int strike = ui_font_load_ttf(c"tools/ui/LiberationSans-Regular.ttf", 16)
	assert_equal(0 - 1, ui_font_strike_italic(strike))
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_text_strike(&r, 50.0, 60.0, c"p", strike, UI_TEXT_ITALIC, ui_gray(0.0))
	assert_equal(1, quads(&r))
	ui_glyph g = ui_font_glyph(strike, 'p')
	float32 skew = ui_text_italic_skew()
	float32 baseline = 60.0 + cast(float32, ui_font_ascent(strike))
	float32 gx = 50.0 + cast(float32, g.bearing_x)
	float32 gy = baseline - cast(float32, g.bearing_top)
	float32 gy1 = gy + cast(float32, g.h)
	asserts(c"top-left leans right", vert(&r, 0, 0) == gx + skew * (baseline - gy))
	asserts(c"top y unchanged", vert(&r, 0, 1) == gy)
	asserts(c"bottom-right leans left of upright", vert(&r, 2, 0) == gx + cast(float32, g.w) + skew * (baseline - gy1))
	# 'p' descends: its bottom edge sits left of the upright position.
	asserts(c"descender leans back", vert(&r, 5, 0) < gx)
	asserts(c"same texels", vert(&r, 0, 2) == ui_render_u(g.x))
	asserts(c"layout unchanged", ui_text_width_styled(c"p", strike, UI_TEXT_ITALIC) == g.advance)
	ui_render_destroy(&r)


# Loading the committed Regular face at 16 ppem at run time reproduces
# the embedded body strike exactly: the subset keeps the outlines, and
# both go through the same rasterizer and coverage boost.
void test_runtime_strike_matches_embedded():
	int strike = ui_font_load_ttf(c"tools/ui/LiberationSans-Regular.ttf", 16)
	asserts(c"runtime strike id follows the defaults", strike >= ui_font_strike_count())
	assert_equal(ui_font_ascent(0), ui_font_strike_ascent(strike))
	assert_equal(ui_font_descent(0), ui_font_strike_descent(strike))
	# Glyphs rasterize on first use, each growing the atlas.
	int generation = ui_font_atlas_generation()
	ui_font_glyph(strike, 'Q')
	assert_equal(generation + 1, ui_font_atlas_generation())

	# Rasterize both strikes before snapshotting the atlas.
	int ch = 32
	while (ch <= 126):
		ui_font_glyph(0, ch)
		ui_font_glyph(strike, ch)
		ch = ch + 1
	char* atlas = ui_font_build_atlas()
	int w = ui_font_atlas_w()
	ch = 32
	while (ch <= 126):
		ui_glyph baked = ui_font_glyph(0, ch)
		ui_glyph loaded = ui_font_glyph(strike, ch)
		asserts(c"same width", baked.w == loaded.w)
		asserts(c"same height", baked.h == loaded.h)
		asserts(c"same advance", baked.advance == loaded.advance)
		asserts(c"same bearing_x", baked.bearing_x == loaded.bearing_x)
		asserts(c"same bearing_top", baked.bearing_top == loaded.bearing_top)
		if (loaded.w > 0):
			asserts(c"packed below the baked rows", loaded.y >= ui_font_atlas_h())
			asserts(c"a glyph of its own", loaded.y != baked.y || loaded.x != baked.x)
			int y = 0
			while (y < loaded.h):
				for x in range(loaded.w):
					int a = atlas[(baked.y + y) * w + baked.x + x] & 255
					int b = atlas[(loaded.y + y) * w + loaded.x + x] & 255
					asserts(c"same coverage", a == b)
				y = y + 1
		ch = ch + 1
	free(atlas)
	assert_equal(ui_text_width(c"Hello, world", 2), ui_text_width_strike(c"Hello, world", strike))
	assert_equal(ui_text_height(2), ui_text_height_strike(strike))


# Runtime strikes draw through the same path, with UVs over the grown
# atlas.
void test_runtime_strike_draws():
	int strike = ui_font_load_ttf(c"tools/ui/LiberationSans-Bold.ttf", 28)
	asserts(c"bold loads", strike >= ui_font_strike_count())
	ui_renderer r
	ui_render_init_headless(&r)
	ui_render_begin(&r, 320, 240)
	ui_draw_text_strike(&r, 10.0, 10.0, c"W", strike, UI_TEXT_UNDERLINE, ui_gray(0.0))
	assert_equal(2, quads(&r))
	ui_glyph g = ui_font_glyph(strike, 'W')
	asserts(c"bigger than the title strike", g.h > ui_font_glyph(1, 'W').h)
	ui_render_end(&r)
	asserts(c"v over the grown atlas", vert(&r, 0, 3) == cast(float32, g.y) / cast(float32, ui_font_atlas_rows()))
	asserts(c"inside the atlas", vert(&r, 2, 3) <= 1.0)
	ui_render_destroy(&r)


void test_runtime_load_from_bytes():
	int size = 0
	char* data = ttf_read_file(c"tools/ui/LiberationSans-Regular.ttf", &size)
	int strike = ui_font_load_ttf_bytes(data, size, 12)
	free(data)
	asserts(c"bytes load", strike >= ui_font_strike_count())
	asserts(c"smaller than body", ui_font_glyph(strike, 'M').h < ui_font_glyph(0, 'M').h)


# A failed load changes nothing: no strike, no generation bump, no
# atlas rows.
void test_bad_runtime_load_changes_nothing():
	int generation = ui_font_atlas_generation()
	int rows = ui_font_atlas_rows()
	int total = ui_font_strike_total()
	assert_equal(0 - 1, ui_font_load_ttf(c"tools/ui/no-such-font.ttf", 16))
	assert_equal(0 - 1, ui_font_load_ttf(c"tools/ui/LiberationSans-Regular.ttf", 1000))
	assert_equal(generation, ui_font_atlas_generation())
	assert_equal(rows, ui_font_atlas_rows())
	assert_equal(total, ui_font_strike_total())
	# An unknown strike id falls back to the body strike rather than
	# reading past the strike table.
	ui_glyph g = ui_font_glyph(total + 3, 'A')
	assert_equal(ui_font_glyph(0, 'A').advance, g.advance)
