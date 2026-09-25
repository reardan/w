# Shared headless fixture for the graphics UI tests: a GL-free renderer,
# the light theme and a context wired to both, plus scripted-event
# helpers that feed input the way a window backend would before a frame.
#
#	ui_fixture fx
#	ui_context* ctx = ui_fixture_init(&fx)
#	ui_test_click(ctx, 40, 20)
#	...
#	ui_render_destroy(&fx.r)
import graphics.event
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets


struct ui_fixture:
	ui_renderer r
	ui_theme theme
	ui_context ctx


# Headless renderer + light theme + context; returns the context.
ui_context* ui_fixture_init(ui_fixture* fx):
	ui_render_init_headless(&fx.r)
	ui_theme_light(&fx.theme)
	ui_context_init(&fx.ctx, &fx.r, &fx.theme)
	return &fx.ctx


# Feed one raw event.
void ui_test_event(ui_context* ctx, int kind, int code, int x, int y, int mods):
	gfx_event e
	e.kind = kind
	e.code = code
	e.x = x
	e.y = y
	e.mods = mods
	ui_feed_event(ctx, &e)


# Left-button press + release at x,y.
void ui_test_click(ui_context* ctx, int x, int y):
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, x, y, 0)
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, x, y, 0)


# Scroll-wheel notches with the pointer at x,y.
void ui_test_wheel(ui_context* ctx, int notches, int x, int y):
	ui_test_event(ctx, GFX_EVENT_SCROLL, notches, x, y, 0)


# One typed character.
void ui_test_char(ui_context* ctx, int code):
	ui_test_event(ctx, GFX_EVENT_CHAR, code, 0, 0, 0)


# Every character of a C string, in order.
void ui_test_text(ui_context* ctx, char* s):
	int i = 0
	while (s[i] != 0):
		ui_test_char(ctx, s[i])
		i++


# A navigation key (GFX_NAV_*) with modifier bits.
void ui_test_key(ui_context* ctx, int code, int mods):
	ui_test_event(ctx, GFX_EVENT_NAV, code, 0, 0, mods)


# A navigation key with no modifiers.
void ui_test_nav(ui_context* ctx, int code):
	ui_test_key(ctx, code, 0)
