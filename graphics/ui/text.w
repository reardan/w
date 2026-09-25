/*
graphics.ui.text: string drawing over the batching renderer.
Proportional Liberation Sans strikes from the baked atlas (body or
title via the scale value, graphics.ui.font), or any runtime strike
ui_font_load_ttf added (the _strike entry points). Pens round to
integer pixels so 1:1 LINEAR sampling stays on texel centers and text
renders crisp. char* + s[i] like the rest of graphics/ — no UTF-8
shaping yet (issue #379).

Styles (issue #379) combine as flags: UI_TEXT_ITALIC leans each glyph
quad about the baseline (a synthetic oblique, so it works on every
strike without an italic face), UI_TEXT_UNDERLINE and
UI_TEXT_STRIKETHROUGH draw solid lines at the face's own post/OS/2
decoration metrics across the run's advance width. Bold is a strike
choice (the title strike, or a runtime bold face), not a flag.
*/
import lib.lib
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render


# Text style flags; combine with |.
enum ui_text_style:
	UI_TEXT_PLAIN = 0
	UI_TEXT_ITALIC = 1
	UI_TEXT_UNDERLINE = 2
	UI_TEXT_STRIKETHROUGH = 4


# Synthetic-oblique lean: pixels of x per pixel of height, about 11
# degrees (Liberation Sans Italic's own slant is 12).
float32 ui_text_italic_skew():
	return 0.2


# Draw s in strike with the line box's top-left at x,y and the given
# style flags. y positions the box (ascent + descent tall), not the
# glyph ink. Advance widths are the upright ones, so styling never
# changes layout: ui_text_width_strike still measures the run.
void ui_draw_text_strike(ui_renderer* r, float32 x, float32 y, char* s, int strike, int style, ui_color color):
	int start = cast(int, x + 0.5)
	int pen = start
	int top = cast(int, y + 0.5)
	float32 skew = 0.0
	if (style & UI_TEXT_ITALIC):
		skew = ui_text_italic_skew()
	int i = 0
	while (s[i] != 0):
		pen = pen + ui_render_glyph_strike(r, cast(float32, pen), cast(float32, top), s[i] & 255, strike, skew, color)
		i = i + 1
	if (pen <= start):
		return
	int baseline = top + ui_font_strike_ascent(strike)
	float32 width = cast(float32, pen - start)
	if (style & UI_TEXT_UNDERLINE):
		# Upright even under italic, as typeset underlines are.
		float32 uy = cast(float32, baseline + ui_font_underline_top(strike))
		ui_render_rect(r, ui_rect_new(cast(float32, start), uy, width, cast(float32, ui_font_underline_thickness(strike))), color)
	if (style & UI_TEXT_STRIKETHROUGH):
		int thick = ui_font_strikeout_thickness(strike)
		int sy = baseline + ui_font_strikeout_top(strike)
		# Under italic the line shifts with the glyphs it crosses: the
		# lean at its own height above the baseline.
		float32 lean = skew * cast(float32, baseline - sy)
		ui_render_rect(r, ui_rect_new(cast(float32, start) + lean, cast(float32, sy), width, cast(float32, thick)), color)


# ui_draw_text_strike at the strike text_scale selects.
void ui_draw_text_styled(ui_renderer* r, float32 x, float32 y, char* s, int scale, int style, ui_color color):
	ui_draw_text_strike(r, x, y, s, ui_font_strike_from_scale(scale), style, color)


# Draw s with the line box's top-left at x,y. y positions the box
# (ascent + descent tall), not the glyph ink.
void ui_draw_text(ui_renderer* r, float32 x, float32 y, char* s, int scale, ui_color color):
	ui_draw_text_styled(r, x, y, s, scale, UI_TEXT_PLAIN, color)


void ui_draw_text_centered(ui_renderer* r, ui_rect rect, char* s, int scale, ui_color color):
	float32 tx = rect.x + (rect.w - cast(float32, ui_text_width(s, scale))) * 0.5
	float32 ty = rect.y + (rect.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(r, tx, ty, s, scale, color)
