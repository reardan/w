# Headless unit tests for the month calendar: grid placement against
# the weekday of the 1st, month paging across year ends, leap
# Februaries, click and keyboard selection (docs/projects/ui_widgets.md
# §4.7). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_calendar_test arch_only=x64
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


# Where a calendar issued first in a frame lands: the root region's
# top-left, inset by the theme pad.
ui_rect calendar_rect(ui_context* ctx):
	float32 pad = cast(float32, ctx.theme.pad)
	return ui_rect_new(pad, pad, ui_calendar_width(ctx), ui_calendar_height(ctx))


void click_cell(ui_context* ctx, int cell):
	ui_rect c = ui_calendar_cell_rect(ctx, calendar_rect(ctx), cell)
	feed_click(ctx, cast(int, c.x + c.w * 0.5), cast(int, c.y + c.h * 0.5))


int calendar_frame(ui_context* ctx, ui_calendar_state* st, ui_date* selected, ui_date* today):
	ui_begin(ctx, 400, 400)
	int changed = ui_calendar(ctx, st, selected, today)
	ui_end(ctx)
	return changed


# The grid's first in-month cell is the weekday of the 1st, and cell 0
# is the right day of the previous month.
void test_the_grid_starts_on_the_weekday_of_the_first():
	ui_calendar_state st
	ui_date d

	# September 2026 starts on a Tuesday.
	ui_calendar_init(&st, 2026, 9)
	assert_equal(2, ui_calendar_lead(&st))
	ui_calendar_cell_date(&st, 0, &d)
	assert_date(&d, 2026, 8, 30)
	ui_calendar_cell_date(&st, 2, &d)
	assert_date(&d, 2026, 9, 1)
	ui_calendar_cell_date(&st, 31, &d)
	assert_date(&d, 2026, 9, 30)
	ui_calendar_cell_date(&st, 41, &d)
	assert_date(&d, 2026, 10, 10)

	# February 2026 starts on a Sunday: no leading days at all.
	ui_calendar_init(&st, 2026, 2)
	assert_equal(0, ui_calendar_lead(&st))
	ui_calendar_cell_date(&st, 0, &d)
	assert_date(&d, 2026, 2, 1)

	# June 2025 on a Sunday; December 1969, before the epoch, a Monday.
	ui_calendar_init(&st, 2025, 6)
	assert_equal(0, ui_calendar_lead(&st))
	ui_calendar_init(&st, 1969, 12)
	assert_equal(1, ui_calendar_lead(&st))
	ui_calendar_cell_date(&st, 0, &d)
	assert_date(&d, 1969, 11, 30)


# Weeks starting on Monday shift every month's lead by one, wrapping a
# Sunday 1st to the end of the first row.
void test_monday_first_weeks():
	ui_calendar_state st
	ui_calendar_init(&st, 2026, 9)
	st.first_weekday = 1
	assert_equal(1, ui_calendar_lead(&st))
	ui_calendar_init(&st, 2026, 2)
	st.first_weekday = 1
	assert_equal(6, ui_calendar_lead(&st))


void test_leap_februaries():
	ui_calendar_state st
	ui_date d
	# 2024: Feb 1st on a Thursday, 29 days, so March 1st is cell 33.
	ui_calendar_init(&st, 2024, 2)
	assert_equal(4, ui_calendar_lead(&st))
	ui_calendar_cell_date(&st, 32, &d)
	assert_date(&d, 2024, 2, 29)
	ui_calendar_cell_date(&st, 33, &d)
	assert_date(&d, 2024, 3, 1)
	# 2023: Wednesday, 28 days.
	ui_calendar_init(&st, 2023, 2)
	assert_equal(3, ui_calendar_lead(&st))
	ui_calendar_cell_date(&st, 30, &d)
	assert_date(&d, 2023, 2, 28)
	ui_calendar_cell_date(&st, 31, &d)
	assert_date(&d, 2023, 3, 1)
	# 1900 was not a leap year, 2000 was.
	ui_date_set(&d, 1900, 2, 29)
	ui_date_normalize(&d)
	assert_date(&d, 1900, 3, 1)
	ui_date_set(&d, 2000, 2, 29)
	ui_date_normalize(&d)
	assert_date(&d, 2000, 2, 29)


void test_month_paging_wraps_years():
	ui_calendar_state st
	ui_calendar_init(&st, 2026, 12)
	ui_calendar_show_month(&st, 1)
	assert_equal(2027, st.year)
	assert_equal(1, st.month)
	ui_calendar_show_month(&st, -1)
	assert_equal(2026, st.year)
	assert_equal(12, st.month)
	ui_calendar_init(&st, 2026, 1)
	ui_calendar_show_month(&st, -1)
	assert_equal(2025, st.year)
	assert_equal(12, st.month)
	ui_calendar_show_month(&st, -25)
	assert_equal(2023, st.year)
	assert_equal(11, st.month)


void test_date_arithmetic():
	ui_date d
	ui_date_set(&d, 2026, 12, 31)
	ui_date_add_days(&d, 1)
	assert_date(&d, 2027, 1, 1)
	ui_date_add_days(&d, -1)
	assert_date(&d, 2026, 12, 31)
	# Month steps clamp to the shorter month.
	ui_date_set(&d, 2024, 1, 31)
	ui_date_add_months(&d, 1)
	assert_date(&d, 2024, 2, 29)
	ui_date_set(&d, 2024, 3, 31)
	ui_date_add_months(&d, -13)
	assert_date(&d, 2023, 2, 28)

	ui_date a
	ui_date b
	ui_date_set(&a, 2024, 2, 28)
	ui_date_set(&b, 2024, 3, 1)
	assert_equal(-2, ui_date_compare(&a, &b))
	char[11] text
	ui_date_format(&a, &text[0])
	assert_strings_equal(c"2024-02-28", &text[0])


# The header arrows turn the page, across the year end too.
void test_the_arrows_page_months():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_calendar_state st
	ui_calendar_init(&st, 2026, 12)
	ui_date sel
	ui_date_clear(&sel)

	ui_rect cal = calendar_rect(&ctx)
	float32 s = ui_calendar_cell_size(&ctx)
	feed_click(&ctx, cast(int, cal.x + cal.w - s * 0.5), cast(int, cal.y + s * 0.5))
	assert_equal(0, calendar_frame(&ctx, &st, &sel, 0))
	assert_equal(2027, st.year)
	assert_equal(1, st.month)

	feed_click(&ctx, cast(int, cal.x + s * 0.5), cast(int, cal.y + s * 0.5))
	calendar_frame(&ctx, &st, &sel, 0)
	feed_click(&ctx, cast(int, cal.x + s * 0.5), cast(int, cal.y + s * 0.5))
	calendar_frame(&ctx, &st, &sel, 0)
	assert_equal(2026, st.year)
	assert_equal(11, st.month)
	assert_equal(0, ui_date_is_set(&sel))
	ui_render_destroy(&r)


void test_clicking_a_day_selects_it():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_calendar_state st
	ui_calendar_init(&st, 2026, 9)
	ui_date sel
	ui_date_clear(&sel)
	ui_date today
	ui_date_set(&today, 2026, 9, 25)

	# A frame with nothing happening changes nothing.
	assert_equal(0, calendar_frame(&ctx, &st, &sel, &today))

	# Cell 2 + 14 is September 15th.
	click_cell(&ctx, 16)
	assert_equal(1, calendar_frame(&ctx, &st, &sel, &today))
	assert_date(&sel, 2026, 9, 15)

	# Clicking it again is not a change.
	click_cell(&ctx, 16)
	assert_equal(0, calendar_frame(&ctx, &st, &sel, &today))
	ui_render_destroy(&r)


# A muted day of the next month selects it and turns the page there.
void test_clicking_a_trailing_day_turns_the_page():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_calendar_state st
	ui_calendar_init(&st, 2026, 12)
	ui_date sel
	ui_date_clear(&sel)

	# December 2026 starts on a Tuesday; cell 41 is January 9th.
	click_cell(&ctx, 41)
	assert_equal(1, calendar_frame(&ctx, &st, &sel, 0))
	assert_date(&sel, 2027, 1, 9)
	assert_equal(2027, st.year)
	assert_equal(1, st.month)
	ui_render_destroy(&r)


# A press on one day released over another is no click.
void test_a_drag_between_days_selects_nothing():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_calendar_state st
	ui_calendar_init(&st, 2026, 9)
	ui_date sel
	ui_date_clear(&sel)
	ui_rect a = ui_calendar_cell_rect(&ctx, calendar_rect(&ctx), 10)
	ui_rect b = ui_calendar_cell_rect(&ctx, calendar_rect(&ctx), 11)

	gfx_event press
	press.kind = GFX_EVENT_MOUSE_DOWN
	press.code = 1
	press.x = cast(int, a.x + 4.0)
	press.y = cast(int, a.y + 4.0)
	press.mods = 0
	ui_feed_event(&ctx, &press)
	gfx_event release
	release.kind = GFX_EVENT_MOUSE_UP
	release.code = 1
	release.x = cast(int, b.x + 4.0)
	release.y = cast(int, b.y + 4.0)
	release.mods = 0
	ui_feed_event(&ctx, &release)
	assert_equal(0, calendar_frame(&ctx, &st, &sel, 0))
	assert_equal(0, ui_date_is_set(&sel))
	ui_render_destroy(&r)


# After a click the grid holds focus: arrows move by days and weeks,
# page keys by months, and the page follows the selection.
void test_the_keyboard_moves_the_selection():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_calendar_state st
	ui_calendar_init(&st, 2026, 9)
	ui_date sel
	ui_date_clear(&sel)

	# September 30th is cell 31.
	click_cell(&ctx, 31)
	calendar_frame(&ctx, &st, &sel, 0)
	assert_date(&sel, 2026, 9, 30)

	feed_nav(&ctx, GFX_NAV_RIGHT)
	assert_equal(1, calendar_frame(&ctx, &st, &sel, 0))
	assert_date(&sel, 2026, 10, 1)
	assert_equal(10, st.month)

	feed_nav(&ctx, GFX_NAV_UP)
	calendar_frame(&ctx, &st, &sel, 0)
	assert_date(&sel, 2026, 9, 24)
	assert_equal(9, st.month)

	feed_nav(&ctx, GFX_NAV_PAGE_DOWN)
	feed_nav(&ctx, GFX_NAV_PAGE_DOWN)
	feed_nav(&ctx, GFX_NAV_PAGE_DOWN)
	feed_nav(&ctx, GFX_NAV_PAGE_DOWN)
	calendar_frame(&ctx, &st, &sel, 0)
	assert_date(&sel, 2027, 1, 24)
	assert_equal(2027, st.year)

	# A click elsewhere drops focus, and the keys stop.
	feed_click(&ctx, 390, 390)
	calendar_frame(&ctx, &st, &sel, 0)
	feed_nav(&ctx, GFX_NAV_LEFT)
	assert_equal(0, calendar_frame(&ctx, &st, &sel, 0))
	assert_date(&sel, 2027, 1, 24)
	ui_render_destroy(&r)


# The calendar always takes the same ids and one layout slot, whatever
# month it shows.
void test_ids_and_layout_are_fixed():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_calendar_state st
	ui_calendar_init(&st, 2026, 2)
	ui_date sel
	ui_date_clear(&sel)

	ui_begin(&ctx, 400, 400)
	ui_calendar(&ctx, &st, &sel, 0)
	assert_equal(1 + ui_calendar_ids(), ctx.next_id)
	float32 bottom = ui_layout_top(&ctx).cursor_y
	ui_end(&ctx)

	ui_calendar_init(&st, 2026, 8)
	ui_begin(&ctx, 400, 400)
	ui_calendar(&ctx, &st, &sel, 0)
	assert_equal(1 + ui_calendar_ids(), ctx.next_id)
	asserts(c"same height every month", ui_layout_top(&ctx).cursor_y == bottom)
	ui_end(&ctx)
	ui_render_destroy(&r)


# Inside a disabled scope nothing selects.
void test_disabled_is_inert():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_calendar_state st
	ui_calendar_init(&st, 2026, 9)
	ui_date sel
	ui_date_clear(&sel)
	click_cell(&ctx, 16)
	ui_begin(&ctx, 400, 400)
	ui_disable(&ctx, 1)
	assert_equal(0, ui_calendar(&ctx, &st, &sel, 0))
	ui_disable(&ctx, 0)
	ui_end(&ctx)
	assert_equal(0, ui_date_is_set(&sel))
	ui_render_destroy(&r)
