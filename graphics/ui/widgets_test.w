# Headless widget-interaction tests: scripted event frames against the
# GL-free renderer seam (ui_render_init_headless). Press-inside then
# release-inside clicks; release-outside does not; a press+release in
# ONE frame still clicks (the event queue's whole point); checkbox
# toggles caller state; drawing accumulates vertices without GL.
# x64-only: the widget module imports graphics.gl/graphics.window,
# which link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_widgets_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.widgets


# One scripted frame around a single button; feeds an optional event
# before the frame like ui_begin_window would. Returns the click.
int frame_with_button(ui_context* ctx, gfx_event* e):
	if (e != 0):
		ui_feed_event(ctx, e)
	ui_begin(ctx, 320, 240)
	int clicked = ui_button(ctx, c"Click")
	ui_end(ctx)
	return clicked


gfx_event make_event(int kind, int x, int y):
	gfx_event e
	e.kind = kind
	e.code = 1
	e.x = x
	e.y = y
	return e


# Default metrics put the first widget row at (8,8); the "Click"
# button is 5 chars * 16px + 2*8 pad = 96 wide, 32 tall.
void test_press_release_inside_clicks():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	assert_equal(0, frame_with_button(&ctx, 0))

	gfx_event press = make_event(GFX_EVENT_MOUSE_DOWN, 20, 20)
	assert_equal(0, frame_with_button(&ctx, &press))
	asserts(c"press claims active", ctx.active != 0)

	gfx_event release = make_event(GFX_EVENT_MOUSE_UP, 24, 22)
	assert_equal(1, frame_with_button(&ctx, &release))
	assert_equal(0, ctx.active)
	ui_render_destroy(&r)


void test_release_outside_does_not_click():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	gfx_event press = make_event(GFX_EVENT_MOUSE_DOWN, 20, 20)
	assert_equal(0, frame_with_button(&ctx, &press))

	gfx_event release = make_event(GFX_EVENT_MOUSE_UP, 300, 200)
	assert_equal(0, frame_with_button(&ctx, &release))
	assert_equal(0, ctx.active)
	ui_render_destroy(&r)


void test_press_and_release_same_frame_clicks():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	# Both events land in one poll cycle — the snapshot model lost
	# this; the queue must not.
	gfx_event press = make_event(GFX_EVENT_MOUSE_DOWN, 20, 20)
	ui_feed_event(&ctx, &press)
	gfx_event release = make_event(GFX_EVENT_MOUSE_UP, 20, 20)
	assert_equal(1, frame_with_button(&ctx, &release))
	ui_render_destroy(&r)


void test_checkbox_toggles_caller_state():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)
	int32 checked = 0

	# Row at (8,8): box 16px + gap + text, 32 tall. Click the box.
	gfx_event press = make_event(GFX_EVENT_MOUSE_DOWN, 12, 24)
	ui_feed_event(&ctx, &press)
	gfx_event release = make_event(GFX_EVENT_MOUSE_UP, 12, 24)
	ui_feed_event(&ctx, &release)
	ui_begin(&ctx, 320, 240)
	assert_equal(1, ui_checkbox(&ctx, c"dark", &checked))
	ui_end(&ctx)
	assert_equal(1, checked)

	# No input: no toggle.
	ui_begin(&ctx, 320, 240)
	assert_equal(0, ui_checkbox(&ctx, c"dark", &checked))
	ui_end(&ctx)
	assert_equal(1, checked)

	# Second click pair flips it back.
	ui_feed_event(&ctx, &press)
	ui_feed_event(&ctx, &release)
	ui_begin(&ctx, 320, 240)
	assert_equal(1, ui_checkbox(&ctx, c"dark", &checked))
	ui_end(&ctx)
	assert_equal(0, checked)
	ui_render_destroy(&r)


void test_widgets_accumulate_vertices():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	ui_begin(&ctx, 320, 240)
	ui_label(&ctx, c"W UI demo")
	int after_label = r.vert_count
	asserts(c"label drew glyphs", after_label == 9 * 6)
	ui_button(&ctx, c"Click")
	int after_button = r.vert_count
	# button = 1 fill quad + 5 glyphs
	assert_equal(after_label + 6 * 6, after_button)
	int32 checked = 1
	ui_checkbox(&ctx, c"dark", &checked)
	# checkbox = box quad + accent quad + 4 glyphs
	assert_equal(after_button + 6 * 6, r.vert_count)
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_same_line_layout():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	ui_begin(&ctx, 320, 240)
	ui_button(&ctx, c"a")
	float32 first_right = ctx.last_right
	ui_same_line(&ctx)
	ui_button(&ctx, c"b")
	# second button starts right of the first, on the same row
	asserts(c"same row", ctx.last_top == 8.0)
	asserts(c"to the right", ctx.last_right > first_right)
	ui_button(&ctx, c"c")
	# back to the stack: below both, at the left origin
	asserts(c"next row", ctx.last_top > 8.0)
	ui_end(&ctx)
	ui_render_destroy(&r)
