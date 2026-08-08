/*
graphics.ui.text: string drawing over the batching renderer.
Proportional Liberation Sans strikes from the baked atlas (body or
title via the scale value, graphics.ui.font); pens round to integer
pixels so 1:1 LINEAR sampling stays on texel centers and text renders
crisp. char* + s[i] like the rest of graphics/ — no UTF-8 shaping yet
(issue #379).
*/
import lib.lib
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render


# Draw s with the line box's top-left at x,y. y positions the box
# (ascent + descent tall), not the glyph ink.
void ui_draw_text(ui_renderer* r, float32 x, float32 y, char* s, int scale, ui_color color):
	int pen = cast(int, x + 0.5)
	int top = cast(int, y + 0.5)
	int i = 0
	while (s[i] != 0):
		pen = pen + ui_render_glyph(r, cast(float32, pen), cast(float32, top), s[i] & 255, scale, color)
		i = i + 1


void ui_draw_text_centered(ui_renderer* r, ui_rect rect, char* s, int scale, ui_color color):
	float32 tx = rect.x + (rect.w - cast(float32, ui_text_width(s, scale))) * 0.5
	float32 ty = rect.y + (rect.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(r, tx, ty, s, scale, color)
