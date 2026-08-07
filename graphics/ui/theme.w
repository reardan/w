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
	# color tokens (the full stage-3 set, design doc §5)
	ui_color background
	ui_color surface
	ui_color border
	ui_color text
	ui_color text_muted
	ui_color widget
	ui_color widget_hot
	ui_color widget_active
	ui_color accent
	ui_color accent_hot      # accent's hover shade (toggle track)
	ui_color on_accent       # ink drawn on accent fills (toggle knob)
	ui_color focus           # focus ring (focused textbox border)
	ui_color disabled_widget # fills inside a ui_disable scope
	ui_color disabled_text   # text inside a ui_disable scope
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
	out.accent_hot = ui_color_new(0.12, 0.4, 0.78, 1.0)
	out.on_accent = ui_gray(1.0)
	out.focus = ui_color_new(0.15, 0.45, 0.85, 1.0)
	out.disabled_widget = ui_gray(0.91)
	out.disabled_text = ui_gray(0.62)
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
	out.accent_hot = ui_color_new(0.45, 0.68, 0.97, 1.0)
	out.on_accent = ui_gray(0.08)
	out.focus = ui_color_new(0.35, 0.6, 0.95, 1.0)
	out.disabled_widget = ui_gray(0.2)
	out.disabled_text = ui_gray(0.42)
	ui_theme_metrics(out)


# The non-grayscale example theme (design doc §5's "fully
# customizable" proof): deep-sea blues with a warm accent and a cyan
# focus ring — every token re-colored, no widget code changes.
void ui_theme_ocean(ui_theme* out):
	out.background = ui_color_new(0.07, 0.12, 0.18, 1.0)
	out.surface = ui_color_new(0.1, 0.17, 0.24, 1.0)
	out.border = ui_color_new(0.25, 0.38, 0.48, 1.0)
	out.text = ui_color_new(0.85, 0.93, 0.96, 1.0)
	out.text_muted = ui_color_new(0.55, 0.68, 0.75, 1.0)
	out.widget = ui_color_new(0.15, 0.26, 0.35, 1.0)
	out.widget_hot = ui_color_new(0.19, 0.32, 0.42, 1.0)
	out.widget_active = ui_color_new(0.24, 0.4, 0.52, 1.0)
	out.accent = ui_color_new(1.0, 0.62, 0.26, 1.0)
	out.accent_hot = ui_color_new(1.0, 0.7, 0.38, 1.0)
	out.on_accent = ui_color_new(0.12, 0.08, 0.03, 1.0)
	out.focus = ui_color_new(0.35, 0.75, 0.85, 1.0)
	out.disabled_widget = ui_color_new(0.12, 0.2, 0.27, 1.0)
	out.disabled_text = ui_color_new(0.36, 0.46, 0.53, 1.0)
	ui_theme_metrics(out)
