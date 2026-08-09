# Headless unit tests for the toast: expiry against a caller-supplied
# clock, the top layer, and staying out of the way of input
# (docs/projects/ui_widgets.md §9.3). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_toast_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets


void setup(ui_renderer* r, ui_theme* theme, ui_context* ctx):
	ui_render_init_headless(r)
	ui_theme_light(theme)
	ui_context_init(ctx, r, theme)


void feed_click(ui_context* ctx, int x, int y):
	gfx_event press
	press.kind = GFX_EVENT_MOUSE_DOWN
	press.code = 1
	press.x = x
	press.y = y
	press.mods = 0
	ui_feed_event(ctx, &press)
	gfx_event release
	release.kind = GFX_EVENT_MOUSE_UP
	release.code = 1
	release.x = x
	release.y = y
	release.mods = 0
	ui_feed_event(ctx, &release)


# One frame: a button, then the toast over it.
int toast_frame(ui_context* ctx, ui_toast_state* st, int32* bg, int now_ms):
	ui_begin(ctx, 320, 240)
	if (ui_button(ctx, c"behind")):
		bg[0] = bg[0] + 1
	int alive = ui_toast(ctx, st, now_ms)
	ui_end(ctx)
	return alive


# The clock comes in as an argument, so expiry is exactly testable: no
# sleeping, no frame counting, no real clock at all.
void test_a_toast_lives_exactly_its_duration():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_toast_state st
	ui_toast_init(&st)
	int32 bg
	bg = 0

	assert_equal(0, toast_frame(&ctx, &st, &bg, 1000))

	ui_toast_show(&st, c"Saved", 1000, 2000)
	assert_equal(1, toast_frame(&ctx, &st, &bg, 1000))
	assert_equal(1, toast_frame(&ctx, &st, &bg, 2999))
	# The far edge is exclusive: at exactly its duration it is gone.
	assert_equal(0, toast_frame(&ctx, &st, &bg, 3000))
	assert_equal(0, toast_frame(&ctx, &st, &bg, 9999))
	ui_render_destroy(&r)


# Showing again restarts the timer, so a burst of notifications does not
# all expire on the first one's clock.
void test_showing_again_restarts_the_timer():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_toast_state st
	ui_toast_init(&st)
	int32 bg
	bg = 0

	ui_toast_show(&st, c"First", 1000, 2000)
	assert_equal(1, toast_frame(&ctx, &st, &bg, 2500))
	ui_toast_show(&st, c"Second", 2500, 2000)
	# Past the first toast's expiry, alive on the second's.
	assert_equal(1, toast_frame(&ctx, &st, &bg, 3500))
	assert_equal(0, toast_frame(&ctx, &st, &bg, 4500))
	ui_render_destroy(&r)


# Elapsed time is a difference, so a monotonic clock that wraps a 32-bit
# int — which time_monotonic_ms() does, after about 24.8 days — still
# measures a short interval correctly across the wrap.
void test_expiry_survives_the_clock_wrapping():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_toast_state st
	ui_toast_init(&st)
	int32 bg
	bg = 0

	# Shown 100ms before the wrap, checked 100ms after it.
	int before_wrap = 2147483647
	ui_toast_show(&st, c"Wrapped", before_wrap - 100, 1000)
	assert_equal(1, toast_frame(&ctx, &st, &bg, before_wrap))
	ui_render_destroy(&r)


# A toast draws above everything, including a modal: that case is what
# motivates a third render layer at all.
void test_a_toast_draws_on_the_top_layer():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_toast_state st
	ui_toast_init(&st)
	int32 bg
	bg = 0

	toast_frame(&ctx, &st, &bg, 1000)
	assert_equal(0, r.layer_vert_count[UI_LAYER_TOP])

	ui_toast_show(&st, c"Saved", 1000, 2000)
	toast_frame(&ctx, &st, &bg, 1000)
	asserts(c"the toast drew on the top layer", r.layer_vert_count[UI_LAYER_TOP] > 0)

	# And it put the layer back, so whatever the caller issues next is
	# not silently promoted above everything.
	assert_equal(UI_LAYER_BASE, r.layer)
	ui_render_destroy(&r)


# A toast takes no input and opens no scope. Notifications that steal
# clicks are notifications that lose work.
void test_a_toast_does_not_steal_input():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_toast_state st
	ui_toast_init(&st)
	int32 bg
	bg = 0

	ui_toast_show(&st, c"Saved", 1000, 5000)
	toast_frame(&ctx, &st, &bg, 1000)
	assert_equal(0, ctx.popup_depth)

	feed_click(&ctx, 20, 20)
	toast_frame(&ctx, &st, &bg, 1200)
	assert_equal(1, bg)
	ui_render_destroy(&r)


# A message longer than the buffer truncates rather than running off the
# end of it — the fixed-capacity convention, held explicitly.
void test_a_long_message_truncates_safely():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_toast_state st
	ui_toast_init(&st)
	int32 bg
	bg = 0

	ui_toast_show(&st, c"0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789", 0, 1000)
	assert_equal(1, toast_frame(&ctx, &st, &bg, 0))
	assert_equal(0, st.text[ui_toast_capacity() - 1])
	ui_render_destroy(&r)


# Dismissing early is the caller's prerogative and takes effect at once.
void test_dismiss_takes_effect_immediately():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_toast_state st
	ui_toast_init(&st)
	int32 bg
	bg = 0

	ui_toast_show(&st, c"Saved", 0, 10000)
	assert_equal(1, toast_frame(&ctx, &st, &bg, 100))
	ui_toast_dismiss(&st)
	assert_equal(0, toast_frame(&ctx, &st, &bg, 100))
	ui_render_destroy(&r)
