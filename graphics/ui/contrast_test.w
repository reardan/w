# wbuild: name=graphics_ui_contrast_test x64
import lib.testing
import graphics.ui.contrast

void check_theme_contrast(ui_theme* t):
	asserts(c"body text on background", ui_contrast_ratio(t.text, t.background) >= 4.5)
	asserts(c"body text on surface", ui_contrast_ratio(t.text, t.surface) >= 4.5)
	asserts(c"muted text on surface", ui_contrast_ratio(t.text_muted, t.surface) >= 4.5)
	asserts(c"text on widget", ui_contrast_ratio(t.text, t.widget) >= 4.5)
	asserts(c"button label", ui_contrast_ratio(t.on_accent, t.accent) >= 4.5)
	asserts(c"button hover label", ui_contrast_ratio(t.on_accent, t.accent_hot) >= 4.5)
	asserts(c"focus on background", ui_contrast_ratio(t.focus, t.background) >= 3.0)
	asserts(c"focus on surface", ui_contrast_ratio(t.focus, t.surface) >= 3.0)
	asserts(c"error on surface", ui_contrast_ratio(t.error, t.surface) >= 4.5)

void test_default_theme_contrast():
	ui_theme t
	ui_theme_light(&t)
	check_theme_contrast(&t)
	ui_theme_dark(&t)
	check_theme_contrast(&t)
	asserts(c"black white 21", fabs(ui_contrast_ratio(ui_gray(0.0), ui_gray(1.0)) - 21.0) < 0.001)
	asserts(c"same color 1", fabs(ui_contrast_ratio(t.text, t.text) - 1.0) < 0.001)
