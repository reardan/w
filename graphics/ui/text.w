/*
graphics.ui.text: string drawing over the batching renderer. Monospace
8x8 glyphs at an integer scale; ASCII 32..126 (anything else draws as
space, per graphics.ui.font_data). char* + strlen/s[i] like the rest
of graphics/ — no UTF-8 shaping in stage 1
(docs/projects/ui_framework.md §9).
*/
import lib.lib
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render


void ui_draw_text(ui_renderer* r, float32 x, float32 y, char* s, int scale, ui_color color):
	float32 advance = cast(float32, 8 * scale)
	float32 pen = x
	int len = strlen(s)
	int i = 0
	while (i < len):
		ui_render_glyph(r, pen, y, s[i] & 255, scale, color)
		pen = pen + advance
		i = i + 1


void ui_draw_text_centered(ui_renderer* r, ui_rect rect, char* s, int scale, ui_color color):
	float32 tx = rect.x + (rect.w - cast(float32, ui_text_width(s, scale))) * 0.5
	float32 ty = rect.y + (rect.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(r, tx, ty, s, scale, color)
