# Headless unit tests for the splitter: the two panes tile their area
# exactly, a drag moves the divider, and the clamp holds at both ends
# and under a window too small for both minimums
# (docs/projects/ui_widgets.md §9). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_splitter_test arch_only=x64
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


void feed_press(ui_context* ctx, int x, int y):
	gfx_event e
	e.kind = GFX_EVENT_MOUSE_DOWN
	e.code = 1
	e.x = x
	e.y = y
	e.mods = 0
	ui_feed_event(ctx, &e)


# Move the pointer without releasing, which is what a drag is: the
# press edge fired on an earlier frame and mouse_down is still set.
void feed_move(ui_context* ctx, int x, int y):
	ctx.input.mouse_x = x
	ctx.input.mouse_y = y


void feed_release(ui_context* ctx, int x, int y):
	gfx_event e
	e.kind = GFX_EVENT_MOUSE_UP
	e.code = 1
	e.x = x
	e.y = y
	e.mods = 0
	ui_feed_event(ctx, &e)


# One frame of a single splitter over the whole test window.
void split_frame(ui_context* ctx, ui_split_state* st, int vertical, ui_rect* a, ui_rect* b):
	ui_begin(ctx, 320, 240)
	ui_split(ctx, ui_rect_new(0.0, 0.0, 320.0, 240.0), vertical, st, a, b)
	ui_end(ctx)


# The panes plus the handle must account for every pixel of the area,
# and must not overlap — otherwise a caller's content either goes
# missing or sits under an undraggable divider.
void test_panes_tile_the_area_without_overlapping():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_split_state st
	ui_split_init(&st, 100.0)
	ui_rect a
	ui_rect b
	split_frame(&ctx, &st, 1, &a, &b)

	asserts(c"pane a starts at the area's left", a.x == 0.0)
	asserts(c"pane a stops at the divider", a.w == 100.0)
	asserts(c"pane b starts past the handle", b.x == 100.0 + ui_split_handle())
	asserts(c"the two panes plus the handle fill the area", a.w + ui_split_handle() + b.w == 320.0)
	asserts(c"both panes are full height", a.h == 240.0)
	asserts(c"both panes are full height", b.h == 240.0)

	# Horizontal divider: same arithmetic on the other axis.
	ui_split_state h
	ui_split_init(&h, 80.0)
	split_frame(&ctx, &h, 0, &a, &b)
	asserts(c"pane a is the top strip", a.h == 80.0)
	asserts(c"pane b starts below the handle", b.y == 80.0 + ui_split_handle())
	asserts(c"the strips plus the handle fill the height", a.h + ui_split_handle() + b.h == 240.0)
	ui_render_destroy(&r)


# Pressing the divider and moving the pointer moves it, and by the
# pointer's delta rather than snapping the handle's edge to the cursor.
void test_dragging_the_divider_moves_it_by_the_pointer_delta():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_split_state st
	ui_split_init(&st, 100.0)
	ui_rect a
	ui_rect b

	# Press 2px into the handle, so a snap-to-cursor bug would show up
	# as a 2px jump on the very first drag frame.
	feed_press(&ctx, 102, 120)
	split_frame(&ctx, &st, 1, &a, &b)
	asserts(c"the press alone does not move it", st.pos == 100.0)

	feed_move(&ctx, 152, 120)
	split_frame(&ctx, &st, 1, &a, &b)
	asserts(c"the divider followed the pointer's delta", st.pos == 150.0)

	feed_release(&ctx, 152, 120)
	split_frame(&ctx, &st, 1, &a, &b)
	feed_move(&ctx, 200, 120)
	split_frame(&ctx, &st, 1, &a, &b)
	asserts(c"the drag ended with the release", st.pos == 150.0)
	ui_render_destroy(&r)


# A press that misses the handle belongs to whatever the caller put in
# the pane, not to the splitter.
void test_a_press_outside_the_handle_starts_no_drag():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_split_state st
	ui_split_init(&st, 100.0)
	ui_rect a
	ui_rect b

	feed_press(&ctx, 40, 120)
	split_frame(&ctx, &st, 1, &a, &b)
	feed_move(&ctx, 200, 120)
	split_frame(&ctx, &st, 1, &a, &b)
	asserts(c"no drag started", st.drag_id == 0)
	asserts(c"the divider stayed put", st.pos == 100.0)
	ui_render_destroy(&r)


# Dragging past either end stops at the minimum pane size instead of
# collapsing a pane to nothing or off the area entirely.
void test_the_clamp_holds_at_both_ends():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_split_state st
	ui_split_init(&st, 100.0)
	st.min_a = 40.0
	st.min_b = 60.0
	ui_rect a
	ui_rect b

	feed_press(&ctx, 100, 120)
	split_frame(&ctx, &st, 1, &a, &b)
	feed_move(&ctx, 0 - 500, 120)
	split_frame(&ctx, &st, 1, &a, &b)
	asserts(c"pane a keeps its minimum", st.pos == 40.0)
	asserts(c"and pane b gets the rest", b.w == 320.0 - 40.0 - ui_split_handle())

	feed_move(&ctx, 900, 120)
	split_frame(&ctx, &st, 1, &a, &b)
	asserts(c"pane b keeps its minimum", st.pos == 320.0 - 60.0 - ui_split_handle())
	asserts(c"neither pane went negative", a.w > 0.0)
	asserts(c"neither pane went negative", b.w > 0.0)
	ui_render_destroy(&r)


# An area too narrow to honour both minimums is the case where a naive
# clamp inverts and hands pane b a negative width. Both panes should end
# up cramped; neither should end up nonsensical.
void test_an_area_too_small_for_both_minimums_stays_sane():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_split_state st
	ui_split_init(&st, 50.0)
	st.min_a = 200.0
	st.min_b = 200.0
	ui_rect a
	ui_rect b

	ui_begin(&ctx, 320, 240)
	ui_split(&ctx, ui_rect_new(0.0, 0.0, 100.0, 240.0), 1, &st, &a, &b)
	ui_end(&ctx)

	asserts(c"pane a is not negative", a.w >= 0.0)
	asserts(c"pane b is not negative", b.w >= 0.0)
	asserts(c"pane a still starts at the area's origin", a.x == 0.0)
	ui_render_destroy(&r)


# The splitter costs exactly one widget id whatever its state, so the
# widgets a caller issues after it never shift. Same invariant the
# scroll viewport's thumb id was fixed to hold.
void test_the_splitter_costs_one_id_whatever_its_state():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_rect a
	ui_rect b

	ui_split_state idle
	ui_split_init(&idle, 100.0)
	split_frame(&ctx, &idle, 1, &a, &b)
	int ids_idle = ctx.next_id

	ui_split_state dragging
	ui_split_init(&dragging, 100.0)
	feed_press(&ctx, 100, 120)
	split_frame(&ctx, &dragging, 1, &a, &b)
	int ids_dragging = ctx.next_id

	asserts(c"the drag really started", dragging.drag_id != 0)
	assert_equal(ids_idle, ids_dragging)
	ui_render_destroy(&r)
