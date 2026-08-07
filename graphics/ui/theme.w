/*
graphics.ui.theme: the design-token color layer plus the material-ish
metric scale (docs/projects/ui_framework.md §5). Widgets read every
color through a ui_theme pointer and never hardcode one, so dark/light
mode is a pointer swap plus a redraw — the two presets below share the
same token names with different values, and "fully customizable" is
"fill your own ui_theme".

The default aesthetic is grayscale with a single non-gray accent token
(Material's one-accent-on-neutral convention, per the issue's ask).
Metrics follow an 8px base unit.
*/


struct ui_color:
	float32 r
	float32 g
	float32 b
	float32 a


ui_color ui_color_new(float32 r, float32 g, float32 b, float32 a):
	ui_color c
	c.r = r
	c.g = g
	c.b = b
	c.a = a
	return c


ui_color ui_gray(float32 v):
	return ui_color_new(v, v, v, 1.0)


struct ui_theme:
	# color tokens (stage-1 set; stage 3 grows it)
	ui_color background
	ui_color surface
	ui_color border
	ui_color text
	ui_color text_muted
	ui_color widget
	ui_color widget_hot
	ui_color widget_active
	ui_color accent
	# metric tokens: everything is a small multiple of unit
	int32 unit
	int32 text_scale
	int32 widget_height
	int32 pad
	int32 gap


void ui_theme_metrics(ui_theme* out):
	out.unit = 8
	out.text_scale = 2
	out.widget_height = 32
	out.pad = 8
	out.gap = 8


void ui_theme_light(ui_theme* out):
	out.background = ui_gray(0.95)
	out.surface = ui_gray(1.0)
	out.border = ui_gray(0.62)
	out.text = ui_gray(0.13)
	out.text_muted = ui_gray(0.45)
	out.widget = ui_gray(0.87)
	out.widget_hot = ui_gray(0.8)
	out.widget_active = ui_gray(0.7)
	out.accent = ui_color_new(0.15, 0.45, 0.85, 1.0)
	ui_theme_metrics(out)


void ui_theme_dark(ui_theme* out):
	out.background = ui_gray(0.11)
	out.surface = ui_gray(0.16)
	out.border = ui_gray(0.38)
	out.text = ui_gray(0.92)
	out.text_muted = ui_gray(0.6)
	out.widget = ui_gray(0.25)
	out.widget_hot = ui_gray(0.32)
	out.widget_active = ui_gray(0.42)
	out.accent = ui_color_new(0.35, 0.6, 0.95, 1.0)
	ui_theme_metrics(out)
