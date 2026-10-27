# WCAG relative luminance and contrast for opaque sRGB theme tokens.
import lib.fmath
import lib.lib
import lib.format
import graphics.ui.theme

float32 ui_srgb_linear(float32 component):
	if (component < 0.0): component = 0.0
	if (component > 1.0): component = 1.0
	if (component <= 0.04045): return component / 12.92
	return fpow((component + 0.055) / 1.055, 2.4)

float32 ui_color_luminance(ui_color color):
	return 0.2126 * ui_srgb_linear(color.r) + 0.7152 * ui_srgb_linear(color.g) + 0.0722 * ui_srgb_linear(color.b)

# Caller composites translucent tokens against their actual surface first.
float32 ui_contrast_ratio(ui_color a, ui_color b):
	float32 light = ui_color_luminance(a)
	float32 dark = ui_color_luminance(b)
	if (light < dark):
		float32 swap = light
		light = dark
		dark = swap
	return (light + 0.05) / (dark + 0.05)

int ui_contrast_failures

void ui_contrast_need(char* theme, char* fg_name, ui_color fg, char* bg_name, ui_color bg, float32 minimum):
	float32 ratio = ui_contrast_ratio(fg, bg)
	if (ratio >= minimum): return
	print2(theme)
	print2(c": ")
	print2(fg_name)
	print2(c" on ")
	print2(bg_name)
	print2(c" is ")
	print2(ftoa(ratio))
	print2(c":1, needs ")
	println2(ftoa(minimum))
	ui_contrast_failures = ui_contrast_failures + 1

# WCAG 2.1 contrast of every theme token pair the widgets actually draw
# (graphics/ui/widgets). graphics_ui_contrast_test runs it on the light,
# dark and ocean presets; an application can run it on its own theme.
#   1.4.3  text (labels, values, placeholders, error messages, toast and
#          button labels) needs 4.5:1 against the fill it sits on;
#   1.4.11 non-text UI (checkbox and radio edges, the off switch track,
#          field baselines, scroll thumbs, the selected-row marker, tab
#          and progress indicators, focus rings, the error underline)
#          needs 3:1 against its neighbours.
# Disabled controls are exempt (WCAG "inactive user interface
# components"), so disabled_text/disabled_widget are not asserted.
# Prints each failing pair (theme name, tokens, measured ratio) to stderr
# and returns how many failed.
int ui_theme_contrast_failures(char* name, ui_theme* t):
	ui_contrast_failures = 0
	float32 text = 4.5
	float32 ui = 3.0
	# Body text and values on every fill a label or value is drawn on.
	ui_contrast_need(name, c"text", t.text, c"background", t.background, text)
	ui_contrast_need(name, c"text", t.text, c"surface", t.surface, text)
	ui_contrast_need(name, c"text", t.text, c"widget", t.widget, text)
	ui_contrast_need(name, c"text", t.text, c"widget_hot", t.widget_hot, text)
	ui_contrast_need(name, c"text", t.text, c"widget_active", t.widget_active, text)
	# Muted text: placeholders inside fields, table headers, inactive tabs.
	ui_contrast_need(name, c"text_muted", t.text_muted, c"background", t.background, text)
	ui_contrast_need(name, c"text_muted", t.text_muted, c"surface", t.surface, text)
	ui_contrast_need(name, c"text_muted", t.text_muted, c"widget", t.widget, text)
	# Button, chip, calendar-day and toast labels on the accent.
	ui_contrast_need(name, c"on_accent", t.on_accent, c"accent", t.accent, text)
	ui_contrast_need(name, c"on_accent", t.on_accent, c"accent_hot", t.accent_hot, text)
	# Form validation messages.
	ui_contrast_need(name, c"error", t.error, c"background", t.background, text)
	ui_contrast_need(name, c"error", t.error, c"surface", t.surface, text)
	# Unchecked checkbox/radio edges, the off switch track, field
	# baselines, scroll thumbs and dividers.
	ui_contrast_need(name, c"border", t.border, c"background", t.background, ui)
	ui_contrast_need(name, c"border", t.border, c"surface", t.surface, ui)
	ui_contrast_need(name, c"border", t.border, c"widget", t.widget, ui)
	# Hovered edges and chevrons on a hovered field.
	ui_contrast_need(name, c"text_muted", t.text_muted, c"widget_hot", t.widget_hot, ui)
	# Checked checkbox/radio, the on switch track, progress, the selected
	# tab underline and the selected-row marker.
	ui_contrast_need(name, c"accent", t.accent, c"background", t.background, ui)
	ui_contrast_need(name, c"accent", t.accent, c"surface", t.surface, ui)
	ui_contrast_need(name, c"accent", t.accent, c"widget", t.widget, ui)
	ui_contrast_need(name, c"accent", t.accent, c"widget_active", t.widget_active, ui)
	ui_contrast_need(name, c"accent_hot", t.accent_hot, c"background", t.background, ui)
	ui_contrast_need(name, c"accent_hot", t.accent_hot, c"surface", t.surface, ui)
	# Focus ring outside a control, the focused field baseline and the
	# tree's keyboard cursor.
	ui_contrast_need(name, c"focus", t.focus, c"background", t.background, ui)
	ui_contrast_need(name, c"focus", t.focus, c"surface", t.surface, ui)
	ui_contrast_need(name, c"focus", t.focus, c"widget", t.widget, ui)
	ui_contrast_need(name, c"focus", t.focus, c"widget_hot", t.widget_hot, ui)
	# The error underline under an invalid field.
	ui_contrast_need(name, c"error", t.error, c"widget", t.widget, ui)
	# Switch knobs on their tracks.
	ui_contrast_need(name, c"surface knob", t.surface, c"border", t.border, ui)
	ui_contrast_need(name, c"on_accent knob", t.on_accent, c"accent", t.accent, ui)
	return ui_contrast_failures
