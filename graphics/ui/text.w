/*
graphics.ui.text: string drawing over the batching renderer. Strings
are UTF-8, drawn in any strike (graphics.ui.font: a face at a pixel
size) or in the body/title strike the theme's text_scale selects.
Glyphs are kerned pairwise; pens round to integer pixels so 1:1 LINEAR
sampling stays on texel centers and text renders crisp.

Styles (issue #379) combine as flags. UI_TEXT_ITALIC draws the
strike's true-italic companion (the default faces pair Regular with
Italic and Bold with Bold Italic; ui_font_face_set_italic pairs loaded
faces) and, for a face with no italic, leans each glyph quad about the
baseline instead (a synthetic oblique). UI_TEXT_UNDERLINE and
UI_TEXT_STRIKETHROUGH draw solid lines at the face's own post/OS/2
decoration metrics across the run's advance width. Bold is a strike
choice (the title strike, or ui_font_strike(UI_FACE_BOLD, px)), not a
flag.

Widgets draw through text_scale, so ui_theme_use_strike (or
ui_theme_use_font) points every widget at a loaded face or another
size.
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


# The strike and shear a style draws strike with: the true-italic
# companion when UI_TEXT_ITALIC is set and one exists, else strike
# sheared by ui_text_italic_skew().
int ui_text_style_strike(int strike, int style, float32* skew):
	skew[0] = 0.0
	if ((style & UI_TEXT_ITALIC) == 0):
		return strike
	int italic = ui_font_strike_italic(strike)
	if (italic >= 0):
		return italic
	skew[0] = ui_text_italic_skew()
	return strike


# Pixel width of s drawn in strike with style: a true italic has its
# own advances, so an italic run can measure differently from the
# upright one (a sheared run never does).
int ui_text_width_styled(char* s, int strike, int style):
	float32 skew = 0.0
	return ui_text_width_strike(s, ui_text_style_strike(strike, style, &skew))


# Draw the first limit bytes of s (limit < 0: all of it) in strike
# with the line box's top-left at x,y and the given style flags. y
# positions the box (ascent + descent tall), not the glyph ink.
void ui_draw_text_strike_n(ui_renderer* r, float32 x, float32 y, char* s, int limit, int strike, int style, ui_color color):
	float32 skew = 0.0
	strike = ui_text_style_strike(strike, style, &skew)
	int start = cast(int, x + 0.5)
	int pen = start
	int top = cast(int, y + 0.5)
	int i = 0
	ui_glyph prev
	prev.face = 0 - 1
	while ((s[i] != 0) && ((limit < 0) || (i < limit))):
		int cp = 0
		i = ui_utf8_next(s, i, &cp)
		ui_glyph g = ui_font_glyph(strike, cp)
		pen = pen + ui_font_kern(strike, &prev, &g)
		ui_render_glyph_strike(r, cast(float32, pen), cast(float32, top), cp, strike, skew, color)
		pen = pen + g.advance
		prev = g
	if (pen <= start): return
	int baseline = top + ui_font_strike_ascent(strike)
	float32 width = cast(float32, pen - start)
	if (style & UI_TEXT_UNDERLINE):
		# Upright even under italic, as typeset underlines are.
		float32 uy = cast(float32, baseline + ui_font_underline_top(strike))
		ui_render_rect(r, ui_rect_new(cast(float32, start), uy, width, cast(float32, ui_font_underline_thickness(strike))), color)
	if (style & UI_TEXT_STRIKETHROUGH):
		int thick = ui_font_strikeout_thickness(strike)
		int sy = baseline + ui_font_strikeout_top(strike)
		# Under a sheared italic the line shifts with the glyphs it
		# crosses: the lean at its own height above the baseline.
		float32 lean = skew * cast(float32, baseline - sy)
		ui_render_rect(r, ui_rect_new(cast(float32, start) + lean, cast(float32, sy), width, cast(float32, thick)), color)


void ui_draw_text_strike(ui_renderer* r, float32 x, float32 y, char* s, int strike, int style, ui_color color):
	ui_draw_text_strike_n(r, x, y, s, 0 - 1, strike, style, color)


# ui_draw_text_strike at the strike text_scale selects.
void ui_draw_text_styled(ui_renderer* r, float32 x, float32 y, char* s, int scale, int style, ui_color color):
	ui_draw_text_strike(r, x, y, s, ui_font_strike_from_scale(scale), style, color)


# Draw s with the line box's top-left at x,y. y positions the box
# (ascent + descent tall), not the glyph ink.
void ui_draw_text(ui_renderer* r, float32 x, float32 y, char* s, int scale, ui_color color):
	ui_draw_text_styled(r, x, y, s, scale, UI_TEXT_PLAIN, color)


# The first limit bytes of s, plain, at the strike text_scale selects
# (a line of a larger buffer, or the part of a field that fits).
void ui_draw_text_n(ui_renderer* r, float32 x, float32 y, char* s, int limit, int scale, ui_color color):
	ui_draw_text_strike_n(r, x, y, s, limit, ui_font_strike_from_scale(scale), UI_TEXT_PLAIN, color)


void ui_draw_text_centered(ui_renderer* r, ui_rect rect, char* s, int scale, ui_color color):
	float32 tx = rect.x + (rect.w - cast(float32, ui_text_width(s, scale))) * 0.5
	float32 ty = rect.y + (rect.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(r, tx, ty, s, scale, color)


# Point a theme's text at strike: every widget measures and draws
# through theme.text_scale, so they all switch to it, and
# widget_height grows (never shrinks below the 8px-grid default of 32)
# to keep a pad of text height around the line.
void ui_theme_use_strike(ui_theme* theme, int strike):
	theme.text_scale = ui_font_scale_of(strike)
	int height = ui_text_height_strike(strike) + theme.pad * 2
	if (height < 32): height = 32
	theme.widget_height = height


# ui_theme_use_strike for face at px pixels (a loaded face, or a
# default one at another size). Returns the strike, or -1 (leaving
# the theme alone) for a bad face or size.
int ui_theme_use_font(ui_theme* theme, int face, int px):
	int strike = ui_font_strike(face, px)
	if (strike >= 0): ui_theme_use_strike(theme, strike)
	return strike
