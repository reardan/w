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
	# stage-3 tokens: disabled reads dimmer than the live pair, and
	# on_accent contrasts with the accent it sits on.
	asserts(c"light disabled text lighter", light.disabled_text.r > light.text.r)
	asserts(c"dark disabled text dimmer", dark.disabled_text.r < dark.text.r)
	asserts(c"light on_accent contrasts", light.on_accent.r != light.accent.r)


void test_ocean_theme_is_not_grayscale():
	ui_theme ocean
	ui_theme_ocean(&ocean)
	# The §5 "fully customizable" proof: every channel family diverges
	# (a gray token has r == g == b).
	asserts(c"bg tinted", ocean.background.r != ocean.background.b)
	asserts(c"widget tinted", ocean.widget.r != ocean.widget.b)
	asserts(c"text tinted", ocean.text.r != ocean.text.b)
	# The focus ring is its own token, not the accent reused.
	asserts(c"focus differs from accent", ocean.focus.r != ocean.accent.r)
	# Metrics stay on the shared 8px scale.
	ui_theme light
	ui_theme_light(&light)
	assert_equal(light.unit, ocean.unit)
	assert_equal(light.widget_height, ocean.widget_height)


void test_glyph_metrics():
	# 'A' has ink and a plausible body advance; space is inkless but
	# still advances; out-of-range maps to space.
	ui_glyph a = ui_font_glyph(0, 'A')
	asserts(c"A has ink", (a.w > 0) && (a.h > 0))
	asserts(c"A advance plausible", (a.advance >= 9) && (a.advance <= 13))
	ui_glyph sp = ui_font_glyph(0, ' ')
	assert_equal(0, sp.w)
	asserts(c"space advances", sp.advance > 0)
	ui_glyph mapped = ui_font_glyph(0, 200)
	assert_equal(sp.advance, mapped.advance)
	assert_equal(0, mapped.w)
	# The title strike is a larger bold face: at least as wide.
	ui_glyph title_a = ui_font_glyph(1, 'A')
	asserts(c"title A wider", title_a.advance > a.advance)
	# Below-baseline ink ('_') decodes a negative bearing_top.
	ui_glyph under = ui_font_glyph(0, '_')
	asserts(c"underscore below baseline", under.bearing_top <= 0)


void test_mask_records():
	# Masks carry their baked sizes and pack in id order.
	ui_glyph white = ui_font_mask(ui_mask_white())
	assert_equal(8, white.w)
	ui_glyph corner = ui_font_mask(ui_mask_corner())
	assert_equal(32, corner.w)
	ui_glyph shadow = ui_font_mask(ui_mask_shadow())
	assert_equal(48, shadow.w)
	asserts(c"mask rects distinct", white.x != corner.x)


void test_atlas_decode():
	char* pixels = ui_font_build_atlas()
	int width = ui_font_atlas_w()

	# The white mask is solid 255.
	ui_glyph white = ui_font_mask(ui_mask_white())
	int row = 0
	while (row < white.h):
		int col = 0
		while (col < white.w):
			assert_equal(255, pixels[(white.y + row) * width + white.x + col] & 255)
			col = col + 1
		row = row + 1

	# 'A' body glyph: solid ink, background, and antialiased edges.
	ui_glyph a = ui_font_glyph(0, 'A')
	int solid = 0
	int background = 0
	int partial = 0
	row = 0
	while (row < a.h):
		int col2 = 0
		while (col2 < a.w):
			int value = pixels[(a.y + row) * width + a.x + col2] & 255
			if (value == 255):
				solid = solid + 1
			else if (value == 0):
				background = background + 1
			else:
				partial = partial + 1
			col2 = col2 + 1
		row = row + 1
	asserts(c"A has solid ink", solid > 0)
	asserts(c"A has background", background > 0)
	asserts(c"A is antialiased", partial > 0)

	# Disc mask: opaque center, transparent corner.
	ui_glyph disc = ui_font_mask(ui_mask_disc())
	assert_equal(255, pixels[(disc.y + disc.h / 2) * width + disc.x + disc.w / 2] & 255)
	assert_equal(0, pixels[disc.y * width + disc.x] & 255)

	# Corner mask: opaque at the arc's center corner, transparent at
	# the opposite one.
	ui_glyph corner = ui_font_mask(ui_mask_corner())
	assert_equal(255, pixels[(corner.y + corner.h - 1) * width + corner.x + corner.w - 1] & 255)
	assert_equal(0, pixels[corner.y * width + corner.x] & 255)

	# Shadow tile: dark inner corner, faded outer corner.
	ui_glyph shadow = ui_font_mask(ui_mask_shadow())
	assert_equal(255, pixels[(shadow.y + shadow.h - 1) * width + shadow.x + shadow.w - 1] & 255)
	assert_equal(0, pixels[shadow.y * width + shadow.x] & 255)
	free(pixels)


void test_text_measurement():
	# Proportional: the string width is the sum of its advances.
	int want = 0
	ui_glyph a = ui_font_glyph(0, 'a')
	ui_glyph b = ui_font_glyph(0, 'b')
	ui_glyph c = ui_font_glyph(0, 'c')
	want = a.advance + b.advance + c.advance
	assert_equal(want, ui_text_width(c"abc", 2))
	assert_equal(0, ui_text_width(c"", 2))
	# 'i' is narrower than 'm' — the proportional point.
	asserts(c"proportional", ui_text_width(c"iii", 2) < ui_text_width(c"mmm", 2))
	# Line box = ascent + descent; body lands near the old 16px look.
	assert_equal(ui_font_ascent(0) + ui_font_descent(0), ui_text_height(2))
	asserts(c"body height sane", (ui_text_height(2) >= 16) && (ui_text_height(2) <= 20))
	# The title strike is taller.
	asserts(c"title taller", ui_text_height(3) > ui_text_height(2))


void test_prefix_and_caret():
	ui_glyph a = ui_font_glyph(0, 'a')
	ui_glyph b = ui_font_glyph(0, 'b')
	assert_equal(0, ui_text_prefix_width(c"abc", 0, 2))
	assert_equal(a.advance, ui_text_prefix_width(c"abc", 1, 2))
	assert_equal(a.advance + b.advance, ui_text_prefix_width(c"abc", 2, 2))
	# Count past the end clamps to the whole string.
	assert_equal(ui_text_width(c"abc", 2), ui_text_prefix_width(c"abc", 9, 2))
	# Caret snaps to the nearest boundary: left edge, mid-glyph both
	# sides, past the end.
	assert_equal(0, ui_text_caret_from_x(c"abc", 2, 0 - 5))
	assert_equal(0, ui_text_caret_from_x(c"abc", 2, 0))
	assert_equal(1, ui_text_caret_from_x(c"abc", 2, a.advance - 1))
	assert_equal(3, ui_text_caret_from_x(c"abc", 2, 1000))
