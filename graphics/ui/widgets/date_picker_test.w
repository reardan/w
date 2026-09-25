# Headless unit tests for the date pickers: the field, the calendar
# popover it opens, picking by click and by keyboard, and closing
# without a pick (docs/projects/ui_widgets.md §4.7). No GL context or
# display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_date_picker_test arch_only=x64
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


void feed_char(ui_context* ctx, int code):
	gfx_event e
	e.kind = GFX_EVENT_CHAR
	e.code = code
	e.x = 0
	e.y = 0
	e.mods = 0
	ui_feed_event(ctx, &e)


void feed_nav(ui_context* ctx, int code):
	gfx_event e
	e.kind = GFX_EVENT_NAV
	e.code = code
	e.x = 0
	e.y = 0
	e.mods = 0
	ui_feed_event(ctx, &e)


void assert_date(ui_date* d, int year, int month, int day):
	assert_equal(year, d.year)
	assert_equal(month, d.month)
	assert_equal(day, d.day)


# The picker's field, issued first in a 400x400 frame: the root
# region's top-left, 200 wide.
ui_rect field_rect(ui_context* ctx):
	float32 pad = cast(float32, ctx.theme.pad)
	return ui_rect_new(pad, pad, 200.0, cast(float32, ctx.theme.widget_height))


void click_field(ui_context* ctx):
	ui_rect f = field_rect(ctx)
	feed_click(ctx, cast(int, f.x + 20.0), cast(int, f.y + f.h * 0.5))


void click_cell(ui_context* ctx, int cell):
	ui_rect c = ui_calendar_cell_rect(ctx, ui_date_picker_calendar_rect(ctx, field_rect(ctx)), cell)
	feed_click(ctx, cast(int, c.x + c.w * 0.5), cast(int, c.y + c.h * 0.5))


# One frame: the picker, then a button below it; bg counts the
# button's clicks.
int picker_frame(ui_context* ctx, ui_date_picker_state* st, ui_date* value, ui_date* today, int32* bg):
	ui_begin(ctx, 400, 400)
	int changed = ui_date_picker(ctx, 200.0, st, value, today, c"Pick a date")
	if (ui_button(ctx, c"behind")):
		bg[0] = bg[0] + 1
	ui_end(ctx)
	return changed


void test_the_field_opens_a_calendar_on_todays_month():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_clear(&value)
	ui_date today
	ui_date_set(&today, 2026, 9, 25)
	int32 bg = 0

	assert_equal(0, picker_frame(&ctx, &st, &value, &today, &bg))
	assert_equal(0, st.open)
	assert_equal(0, r.layer_vert_count[UI_LAYER_POPUP])

	click_field(&ctx)
	assert_equal(0, picker_frame(&ctx, &st, &value, &today, &bg))
	assert_equal(1, st.open)
	assert_equal(1, ctx.popup_depth)
	assert_equal(2026, st.cal.year)
	assert_equal(9, st.cal.month)
	asserts(c"the calendar drew on the popup layer", r.layer_vert_count[UI_LAYER_POPUP] > 0)
	ui_render_destroy(&r)


# A set value wins over today for the page the popover opens on.
void test_the_popover_opens_on_the_values_month():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_set(&value, 2024, 2, 29)
	ui_date today
	ui_date_set(&today, 2026, 9, 25)
	int32 bg = 0

	click_field(&ctx)
	picker_frame(&ctx, &st, &value, &today, &bg)
	assert_equal(2024, st.cal.year)
	assert_equal(2, st.cal.month)
	ui_render_destroy(&r)


# Clicking a day picks it, closes the popover and returns 1 — and the
# page behind is live again in the same frame.
void test_clicking_a_day_picks_it_and_closes():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_clear(&value)
	ui_date today
	ui_date_set(&today, 2026, 9, 25)
	int32 bg = 0

	click_field(&ctx)
	picker_frame(&ctx, &st, &value, &today, &bg)
	# September 2026 starts on a Tuesday: cell 2 + 9 is the 10th.
	click_cell(&ctx, 11)
	assert_equal(1, picker_frame(&ctx, &st, &value, &today, &bg))
	assert_date(&value, 2026, 9, 10)
	assert_equal(0, st.open)
	assert_equal(0, ctx.popup_depth)
	assert_equal(0, ctx.focus)

	# Reopening and picking the same day is not a change, but closes.
	click_field(&ctx)
	picker_frame(&ctx, &st, &value, &today, &bg)
	click_cell(&ctx, 11)
	assert_equal(0, picker_frame(&ctx, &st, &value, &today, &bg))
	assert_equal(0, st.open)
	ui_render_destroy(&r)


# The grid has the keys as soon as the popover opens: arrows move the
# cursor without touching the value, return picks the cursor's day.
void test_the_keyboard_picks_with_return():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_set(&value, 2026, 9, 30)
	int32 bg = 0

	click_field(&ctx)
	picker_frame(&ctx, &st, &value, 0, &bg)
	feed_nav(&ctx, GFX_NAV_RIGHT)
	feed_nav(&ctx, GFX_NAV_DOWN)
	assert_equal(0, picker_frame(&ctx, &st, &value, 0, &bg))
	assert_date(&value, 2026, 9, 30)
	assert_date(&st.cursor, 2026, 10, 8)
	assert_equal(10, st.cal.month)
	assert_equal(1, st.open)

	feed_char(&ctx, 13)
	assert_equal(1, picker_frame(&ctx, &st, &value, 0, &bg))
	assert_date(&value, 2026, 10, 8)
	assert_equal(0, st.open)
	ui_render_destroy(&r)


# Escape and a press outside both close without a pick; the outside
# press is consumed, so the button behind does not fire.
void test_escape_and_outside_presses_close_without_picking():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_clear(&value)
	int32 bg = 0

	click_field(&ctx)
	picker_frame(&ctx, &st, &value, 0, &bg)
	feed_char(&ctx, 27)
	assert_equal(0, picker_frame(&ctx, &st, &value, 0, &bg))
	assert_equal(0, st.open)
	assert_equal(0, ctx.popup_depth)
	assert_equal(0, ui_date_is_set(&value))

	click_field(&ctx)
	picker_frame(&ctx, &st, &value, 0, &bg)
	assert_equal(1, st.open)
	feed_click(&ctx, 390, 20)
	assert_equal(0, picker_frame(&ctx, &st, &value, 0, &bg))
	assert_equal(0, st.open)
	assert_equal(0, ui_date_is_set(&value))

	# Clicking the field while open closes it (the press is outside the
	# surface) rather than reopening it.
	click_field(&ctx)
	picker_frame(&ctx, &st, &value, 0, &bg)
	click_field(&ctx)
	picker_frame(&ctx, &st, &value, 0, &bg)
	assert_equal(0, st.open)
	assert_equal(0, bg)
	ui_render_destroy(&r)


# Open or closed, the picker takes the same ids, so the button after it
# keeps its id.
void test_ids_do_not_shift_when_it_opens():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_clear(&value)
	int32 bg = 0

	picker_frame(&ctx, &st, &value, 0, &bg)
	int closed_ids = ctx.next_id
	click_field(&ctx)
	picker_frame(&ctx, &st, &value, 0, &bg)
	assert_equal(1, st.open)
	assert_equal(closed_ids, ctx.next_id)
	assert_equal(2 + ui_date_picker_ids(), closed_ids)
	ui_render_destroy(&r)
