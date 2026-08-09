# Headless unit tests for the scrollable viewport: the wheel claim,
# clamping at both ends, the no-overflow case, and clip composing with
# scroll so content out of view costs nothing
# (docs/projects/ui_widgets.md §4). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_scroll_test arch_only=x64
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


# Turn the wheel notches times at x,y, the way the event queue would.
void feed_wheel(ui_context* ctx, int notches, int x, int y):
	gfx_event e
	e.kind = GFX_EVENT_SCROLL
	e.code = notches
	e.x = x
	e.y = y
	e.mods = 0
	ui_feed_event(ctx, &e)


# One frame of a viewport holding `rows` stacked widgets.
void scroll_frame(ui_context* ctx, ui_rect area, ui_scroll_state* st, int rows):
	ui_begin(ctx, 320, 240)
	ui_scroll_begin(ctx, area, st)
	int i = 0
	while (i < rows):
		ui_label(ctx, c"row")
		i = i + 1
	ui_scroll_end(ctx, st)
	ui_end(ctx)


void test_feed_event_consumes_scroll():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	# GFX_EVENT_SCROLL was produced by X11 and the web host and then
	# dropped on the floor; it reaches widget code now.
	feed_wheel(&ctx, 0 - 1, 40, 40)
	assert_equal(0 - 1, ctx.input.scroll_y)
	assert_equal(40, ctx.input.scroll_at_x)
	# Notches accumulate over a frame.
	feed_wheel(&ctx, 0 - 1, 40, 40)
	assert_equal(0 - 2, ctx.input.scroll_y)
	# ...and are cleared with the other per-frame edges.
	ui_begin(&ctx, 320, 240)
	ui_end(&ctx)
	assert_equal(0, ctx.input.scroll_y)
	ui_render_destroy(&r)


void test_wheel_moves_the_offset():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_scroll_state st
	ui_scroll_init(&st)
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 100.0)

	# First frame measures the content; nothing has scrolled yet.
	scroll_frame(&ctx, area, &st, 20)
	asserts(c"offset starts at 0", st.offset_y == 0.0)
	asserts(c"content measured", st.content_h > st.view_h)
	assert_equal(1, ui_scroll_overflows(&st))

	# A notch toward the user scrolls down by one notch's worth.
	feed_wheel(&ctx, 0 - 1, 50, 50)
	scroll_frame(&ctx, area, &st, 20)
	asserts(c"scrolled down", st.offset_y == cast(float32, ui_scroll_notch()))

	# And back up.
	feed_wheel(&ctx, 1, 50, 50)
	scroll_frame(&ctx, area, &st, 20)
	asserts(c"scrolled back", st.offset_y == 0.0)
	ui_render_destroy(&r)


void test_wheel_outside_the_viewport_is_ignored():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_scroll_state st
	ui_scroll_init(&st)
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 100.0)
	scroll_frame(&ctx, area, &st, 20)

	feed_wheel(&ctx, 0 - 1, 300, 220)
	scroll_frame(&ctx, area, &st, 20)
	asserts(c"not scrolled", st.offset_y == 0.0)
	ui_render_destroy(&r)


void test_offset_clamps_at_both_ends():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_scroll_state st
	ui_scroll_init(&st)
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 100.0)
	scroll_frame(&ctx, area, &st, 20)
	float32 max = ui_scroll_max(&st)
	asserts(c"has room", max > 0.0)

	# Far past the bottom: stops at the last row.
	int i = 0
	while (i < 40):
		feed_wheel(&ctx, 0 - 1, 50, 50)
		scroll_frame(&ctx, area, &st, 20)
		i = i + 1
	asserts(c"clamped at bottom", st.offset_y == max)

	# Far past the top: stops at zero, never negative.
	i = 0
	while (i < 40):
		feed_wheel(&ctx, 1, 50, 50)
		scroll_frame(&ctx, area, &st, 20)
		i = i + 1
	asserts(c"clamped at top", st.offset_y == 0.0)
	ui_render_destroy(&r)


void test_content_shorter_than_view_never_scrolls():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_scroll_state st
	ui_scroll_init(&st)
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 200.0)

	scroll_frame(&ctx, area, &st, 2)
	assert_equal(0, ui_scroll_overflows(&st))
	asserts(c"no room", ui_scroll_max(&st) == 0.0)

	# The wheel does nothing, and no bar is drawn: two rows' worth of
	# geometry is all there is.
	ui_begin(&ctx, 320, 240)
	ui_scroll_begin(&ctx, area, &st)
	ui_label(&ctx, c"row")
	ui_label(&ctx, c"row")
	ui_scroll_end(&ctx, &st)
	int without_bar = r.layer_vert_count[UI_LAYER_BASE]
	ui_end(&ctx)

	feed_wheel(&ctx, 0 - 1, 50, 50)
	scroll_frame(&ctx, area, &st, 2)
	asserts(c"still at top", st.offset_y == 0.0)

	# Same content in a viewport it overflows does draw a bar.
	ui_scroll_state tall
	ui_scroll_init(&tall)
	ui_rect small = ui_rect_new(10.0, 10.0, 200.0, 40.0)
	scroll_frame(&ctx, small, &tall, 2)
	ui_begin(&ctx, 320, 240)
	ui_scroll_begin(&ctx, small, &tall)
	ui_label(&ctx, c"row")
	ui_label(&ctx, c"row")
	ui_scroll_end(&ctx, &tall)
	asserts(c"bar drawn when overflowing", r.layer_vert_count[UI_LAYER_BASE] > without_bar)
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_widget_scrolled_out_of_view_emits_no_vertices():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_scroll_state st
	ui_scroll_init(&st)
	# A viewport one row tall, holding four rows.
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 24.0)

	ui_begin(&ctx, 320, 240)
	ui_scroll_begin(&ctx, area, &st)
	ui_label(&ctx, c"first")
	int after_first = r.layer_vert_count[UI_LAYER_BASE]
	asserts(c"first row drew", after_first > 0)
	ui_label(&ctx, c"second")
	ui_label(&ctx, c"third")
	ui_label(&ctx, c"fourth")
	# Rows past the viewport are clipped away entirely — the property
	# that keeps a long list inside the vertex budget.
	assert_equal(after_first, r.layer_vert_count[UI_LAYER_BASE])
	ui_scroll_end(&ctx, &st)
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_scrolling_swaps_which_rows_draw():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_scroll_state st
	ui_scroll_init(&st)
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 24.0)
	scroll_frame(&ctx, area, &st, 8)

	# Scroll down: the first row is now above the viewport and costs
	# nothing, while a later one has come into view.
	ui_scroll_to(&st, ui_scroll_max(&st))
	ui_begin(&ctx, 320, 240)
	ui_scroll_begin(&ctx, area, &st)
	ui_label(&ctx, c"first")
	assert_equal(0, r.layer_vert_count[UI_LAYER_BASE])
	int i = 1
	while (i < 8):
		ui_label(&ctx, c"row")
		i = i + 1
	asserts(c"later rows drew", r.layer_vert_count[UI_LAYER_BASE] > 0)
	ui_scroll_end(&ctx, &st)
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_reveal_moves_the_minimum():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_scroll_state st
	ui_scroll_init(&st)
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 100.0)
	scroll_frame(&ctx, area, &st, 40)

	# Already visible: nothing moves.
	ui_scroll_to(&st, 0.0)
	ui_scroll_reveal(&st, 10.0, 20.0)
	asserts(c"no move needed", st.offset_y == 0.0)

	# Below the fold: scrolls just far enough to show its bottom.
	ui_scroll_reveal(&st, 200.0, 20.0)
	asserts(c"revealed below", st.offset_y == 200.0 + 20.0 - 100.0)

	# Above the fold: scrolls to its top.
	ui_scroll_reveal(&st, 40.0, 20.0)
	asserts(c"revealed above", st.offset_y == 40.0)
	ui_render_destroy(&r)


void test_nested_viewports_do_not_share_a_notch():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_scroll_state outer
	ui_scroll_state inner
	ui_scroll_init(&outer)
	ui_scroll_init(&inner)
	ui_rect outer_area = ui_rect_new(0.0, 0.0, 300.0, 120.0)
	ui_rect inner_area = ui_rect_new(20.0, 20.0, 200.0, 40.0)

	int frame = 0
	while (frame < 2):
		if (frame == 1):
			feed_wheel(&ctx, 0 - 1, 60, 40)
		ui_begin(&ctx, 320, 240)
		ui_scroll_begin(&ctx, outer_area, &outer)
		ui_scroll_begin(&ctx, inner_area, &inner)
		int i = 0
		while (i < 10):
			ui_label(&ctx, c"row")
			i = i + 1
		ui_scroll_end(&ctx, &inner)
		i = 0
		while (i < 10):
			ui_label(&ctx, c"row")
			i = i + 1
		ui_scroll_end(&ctx, &outer)
		ui_end(&ctx)
		frame = frame + 1

	# The inner viewport ends first, so it claims the notch; the outer
	# one sees nothing left to claim.
	asserts(c"inner scrolled", inner.offset_y > 0.0)
	asserts(c"outer did not", outer.offset_y == 0.0)
	ui_render_destroy(&r)


# A viewport takes exactly one widget id whether or not it has a thumb.
# Ids are sequential in call order, so allocating the thumb's id only on
# the overflow path would shift every later widget by one the moment the
# content grew past the viewport — and ctx.focus persists across frames,
# so a focused field issued after a growing region would silently lose
# focus to its neighbour.
void test_viewport_id_cost_does_not_depend_on_overflow():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)

	# Same three rows either way; only the viewport's height differs, so
	# the sole possible difference in id count is the thumb's.
	ui_scroll_state roomy
	ui_scroll_init(&roomy)
	scroll_frame(&ctx, ui_rect_new(10.0, 10.0, 120.0, 200.0), &roomy, 3)
	int ids_without_thumb = ctx.next_id

	ui_scroll_state cramped
	ui_scroll_init(&cramped)
	scroll_frame(&ctx, ui_rect_new(10.0, 10.0, 120.0, 40.0), &cramped, 3)
	int ids_with_thumb = ctx.next_id

	asserts(c"the roomy viewport did not overflow", ui_scroll_overflows(&roomy) == 0)
	asserts(c"the cramped one did", ui_scroll_overflows(&cramped))
	assert_equal(ids_without_thumb, ids_with_thumb)
	ui_render_destroy(&r)
