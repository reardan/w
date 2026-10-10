# WCAG relative luminance and contrast for opaque sRGB theme tokens.
import lib.fmath
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
