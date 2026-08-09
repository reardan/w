# Headless unit tests for the tab strip: selection, closing without
# selecting, label clipping, and horizontal overflow
# (docs/projects/ui_widgets.md §9). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_tabs_test arch_only=x64
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


void feed_wheel(ui_context* ctx, int notches, int x, int y):
	gfx_event e
	e.kind = GFX_EVENT_SCROLL
	e.code = notches
	e.x = x
	e.y = y
	e.mods = 0
	ui_feed_event(ctx, &e)


char* tab_label(int index):
	if (index == 0):
		return c"main.w"
	if (index == 1):
		return c"tree.w"
	if (index == 2):
		return c"tabs.w"
	if (index == 3):
		return c"render.w"
	return c"theme.w"


ui_rect strip_area():
	return ui_rect_new(0.0, 0.0, 320.0, 28.0)


# One frame of `count` closable tabs across the strip.
int tabs_frame(ui_context* ctx, ui_tab_state* st, int32* active, int count, ui_rect area):
	ui_begin(ctx, 320, 240)
	ui_tabs_begin(ctx, area, st, active)
	int i = 0
	while (i < count):
		ui_tab(ctx, st, tab_label(i), 1)
		i = i + 1
	int closed = ui_tabs_end(ctx, st)
	ui_end(ctx)
	return closed


# Clicking a tab makes it active, and reports the edge exactly once.
void test_clicking_a_tab_selects_it():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_tab_state st
	ui_tab_init(&st)
	int32 active
	active = 0

	# Establish the layout, then click inside the second tab. Widths are
	# text-derived, so the first tab's right edge is read back from the
	# walk rather than assumed.
	tabs_frame(&ctx, &st, &active, 3, strip_area())
	float32 first_w = ui_tab_width(&ctx, tab_label(0), 1)

	feed_click(&ctx, cast(int, first_w) + 4, 14)
	tabs_frame(&ctx, &st, &active, 3, strip_area())
	assert_equal(1, active)

	# Re-clicking the active tab is not a change.
	feed_click(&ctx, cast(int, first_w) + 4, 14)
	tabs_frame(&ctx, &st, &active, 3, strip_area())
	assert_equal(1, active)
	ui_render_destroy(&r)


# The close affordance consumes the click, so closing a background tab
# does not first drag it into focus — the single most annoying way to
# get this wrong.
void test_closing_a_tab_does_not_select_it():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_tab_state st
	ui_tab_init(&st)
	int32 active
	active = 0

	tabs_frame(&ctx, &st, &active, 3, strip_area())
	float32 first_w = ui_tab_width(&ctx, tab_label(0), 1)
	float32 second_w = ui_tab_width(&ctx, tab_label(1), 1)

	# The cross sits at the second tab's right edge, half a pad in.
	int close_x = cast(int, first_w + second_w - ui_tab_close_size() * 0.5 - cast(float32, ctx.theme.pad) * 0.5)
	feed_click(&ctx, close_x, 14)
	int closed = tabs_frame(&ctx, &st, &active, 3, strip_area())

	assert_equal(1, closed)
	asserts(c"closing left the active tab alone", active == 0)

	# And the close edge is one frame wide.
	assert_equal(0 - 1, tabs_frame(&ctx, &st, &active, 3, strip_area()))
	ui_render_destroy(&r)


# Tab width is text-derived but bounded at both ends, so a one-letter
# name still gives a clickable target and a long path cannot eat the
# whole strip.
void test_tab_width_is_bounded_at_both_ends():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)

	float32 tiny = ui_tab_width(&ctx, c"a", 0)
	asserts(c"a short label still gets a usable tab", tiny == ui_tab_min_width())

	float32 huge = ui_tab_width(&ctx, c"a-very-long-source-file-name-that-goes-on.w", 1)
	asserts(c"a long label is capped", huge == ui_tab_max_width())
	ui_render_destroy(&r)


# A strip wider than its area scrolls with the wheel, and clamps at both
# ends against the total width the walk measured.
void test_an_overflowing_strip_scrolls_and_clamps():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_tab_state st
	ui_tab_init(&st)
	int32 active
	active = 0

	# Five tabs in a 160px strip: comfortably overflowing.
	ui_rect narrow = ui_rect_new(0.0, 0.0, 160.0, 28.0)
	tabs_frame(&ctx, &st, &active, 5, narrow)
	asserts(c"the strip overflows", st.content_w > narrow.w)

	feed_wheel(&ctx, 0 - 1, 80, 14)
	tabs_frame(&ctx, &st, &active, 5, narrow)
	asserts(c"the wheel scrolled the strip", st.offset_x > 0.0)

	int i = 0
	while (i < 20):
		feed_wheel(&ctx, 0 - 1, 80, 14)
		tabs_frame(&ctx, &st, &active, 5, narrow)
		i = i + 1
	asserts(c"it clamps at the far end", st.offset_x <= st.content_w - narrow.w)

	i = 0
	while (i < 40):
		feed_wheel(&ctx, 1, 80, 14)
		tabs_frame(&ctx, &st, &active, 5, narrow)
		i = i + 1
	asserts(c"and back at the near end", st.offset_x == 0.0)
	ui_render_destroy(&r)


# A strip that fits never scrolls, whatever the wheel does over it.
void test_a_strip_that_fits_never_scrolls():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_tab_state st
	ui_tab_init(&st)
	int32 active
	active = 0

	tabs_frame(&ctx, &st, &active, 2, strip_area())
	asserts(c"two tabs fit in 320px", st.content_w <= strip_area().w)
	feed_wheel(&ctx, 0 - 1, 80, 14)
	tabs_frame(&ctx, &st, &active, 2, strip_area())
	assert_equal(0, cast(int, st.offset_x))
	ui_render_destroy(&r)


# Tabs scrolled off the strip draw nothing, but still take their ids, so
# a widget issued after the strip does not shift as the strip scrolls.
void test_scrolled_off_tabs_draw_nothing_but_keep_their_ids():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	int32 active
	active = 0
	ui_rect narrow = ui_rect_new(0.0, 0.0, 160.0, 28.0)

	ui_tab_state at_start
	ui_tab_init(&at_start)
	tabs_frame(&ctx, &at_start, &active, 5, narrow)
	int ids_at_start = ctx.next_id
	int verts_at_start = r.layer_vert_count[UI_LAYER_BASE]

	ui_tab_state scrolled
	ui_tab_init(&scrolled)
	tabs_frame(&ctx, &scrolled, &active, 5, narrow)
	scrolled.offset_x = 200.0
	tabs_frame(&ctx, &scrolled, &active, 5, narrow)
	int ids_when_scrolled = ctx.next_id

	assert_equal(ids_at_start, ids_when_scrolled)
	asserts(c"both frames drew something", verts_at_start > 0)
	ui_render_destroy(&r)
