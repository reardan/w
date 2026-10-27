# wbuild: name=graphics_ui_contrast_test x64
# The preset themes pass graphics.ui.contrast's WCAG pair check.
import lib.testing
import graphics.ui.contrast

void test_formula():
	assert_near(21.0, ui_contrast_ratio(ui_gray(0.0), ui_gray(1.0)))
	assert_near(1.0, ui_contrast_ratio(ui_gray(0.5), ui_gray(0.5)))
	# Symmetric, and the WCAG reference value for #777 on white (4.48).
	assert_near(ui_contrast_ratio(ui_gray(0.0), ui_gray(0.3)), ui_contrast_ratio(ui_gray(0.3), ui_gray(0.0)))
	float32 grey = 119.0 / 255.0
	asserts(c"#777 on white is just under 4.5", fabs(ui_contrast_ratio(ui_gray(grey), ui_gray(1.0)) - 4.48) < 0.01)

void test_preset_theme_contrast():
	ui_theme t
	ui_theme_light(&t)
	assert_equal(0, ui_theme_contrast_failures(c"light", &t))
	ui_theme_dark(&t)
	assert_equal(0, ui_theme_contrast_failures(c"dark", &t))
	ui_theme_ocean(&t)
	assert_equal(0, ui_theme_contrast_failures(c"ocean", &t))

# The checker itself must catch a failing pair (and name it).
void test_failing_pair_is_reported():
	ui_theme t
	ui_theme_light(&t)
	t.border = ui_gray(0.8)
	assert_equal(4, ui_theme_contrast_failures(c"pale-border", &t))
