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
import graphics.ui.testing


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
	ui_test_click(ctx, cast(int, f.x + 20.0), cast(int, f.y + f.h * 0.5))


void click_cell(ui_context* ctx, int cell):
	ui_rect c = ui_calendar_cell_rect(ctx, ui_date_picker_calendar_rect(ctx, field_rect(ctx)), cell)
	ui_test_click(ctx, cast(int, c.x + c.w * 0.5), cast(int, c.y + c.h * 0.5))


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
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_clear(&value)
	ui_date today
	ui_date_set(&today, 2026, 9, 25)
	int32 bg = 0

	assert_equal(0, picker_frame(ctx, &st, &value, &today, &bg))
	assert_equal(0, st.open)
	assert_equal(0, fx.r.layer_vert_count[UI_LAYER_POPUP])

	click_field(ctx)
	assert_equal(0, picker_frame(ctx, &st, &value, &today, &bg))
	assert_equal(1, st.open)
	assert_equal(1, ctx.popup_depth)
	assert_equal(2026, st.cal.year)
	assert_equal(9, st.cal.month)
	asserts(c"the calendar drew on the popup layer", fx.r.layer_vert_count[UI_LAYER_POPUP] > 0)
	ui_render_destroy(&fx.r)


# A set value wins over today for the page the popover opens on.
void test_the_popover_opens_on_the_values_month():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_set(&value, 2024, 2, 29)
	ui_date today
	ui_date_set(&today, 2026, 9, 25)
	int32 bg = 0

	click_field(ctx)
	picker_frame(ctx, &st, &value, &today, &bg)
	assert_equal(2024, st.cal.year)
	assert_equal(2, st.cal.month)
	ui_render_destroy(&fx.r)


# Clicking a day picks it, closes the popover and returns 1 — and the
# page behind is live again in the same frame.
void test_clicking_a_day_picks_it_and_closes():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_clear(&value)
	ui_date today
	ui_date_set(&today, 2026, 9, 25)
	int32 bg = 0

	click_field(ctx)
	picker_frame(ctx, &st, &value, &today, &bg)
	# September 2026 starts on a Tuesday: cell 2 + 9 is the 10th.
	click_cell(ctx, 11)
	assert_equal(1, picker_frame(ctx, &st, &value, &today, &bg))
	assert_date(&value, 2026, 9, 10)
	assert_equal(0, st.open)
	assert_equal(0, ctx.popup_depth)
	assert_equal(0, ctx.focus)

	# Reopening and picking the same day is not a change, but closes.
	click_field(ctx)
	picker_frame(ctx, &st, &value, &today, &bg)
	click_cell(ctx, 11)
	assert_equal(0, picker_frame(ctx, &st, &value, &today, &bg))
	assert_equal(0, st.open)
	ui_render_destroy(&fx.r)


# The grid has the keys as soon as the popover opens: arrows move the
# cursor without touching the value, return picks the cursor's day.
void test_the_keyboard_picks_with_return():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_set(&value, 2026, 9, 30)
	int32 bg = 0

	click_field(ctx)
	picker_frame(ctx, &st, &value, 0, &bg)
	ui_test_nav(ctx, GFX_NAV_RIGHT)
	ui_test_nav(ctx, GFX_NAV_DOWN)
	assert_equal(0, picker_frame(ctx, &st, &value, 0, &bg))
	assert_date(&value, 2026, 9, 30)
	assert_date(&st.cursor, 2026, 10, 8)
	assert_equal(10, st.cal.month)
	assert_equal(1, st.open)

	ui_test_char(ctx, 13)
	assert_equal(1, picker_frame(ctx, &st, &value, 0, &bg))
	assert_date(&value, 2026, 10, 8)
	assert_equal(0, st.open)
	ui_render_destroy(&fx.r)


# Escape and a press outside both close without a pick; the outside
# press is consumed, so the button behind does not fire.
void test_escape_and_outside_presses_close_without_picking():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_clear(&value)
	int32 bg = 0

	click_field(ctx)
	picker_frame(ctx, &st, &value, 0, &bg)
	ui_test_char(ctx, 27)
	assert_equal(0, picker_frame(ctx, &st, &value, 0, &bg))
	assert_equal(0, st.open)
	assert_equal(0, ctx.popup_depth)
	assert_equal(0, ui_date_is_set(&value))

	click_field(ctx)
	picker_frame(ctx, &st, &value, 0, &bg)
	assert_equal(1, st.open)
	ui_test_click(ctx, 390, 20)
	assert_equal(0, picker_frame(ctx, &st, &value, 0, &bg))
	assert_equal(0, st.open)
	assert_equal(0, ui_date_is_set(&value))

	# Clicking the field while open closes it (the press is outside the
	# surface) rather than reopening it.
	click_field(ctx)
	picker_frame(ctx, &st, &value, 0, &bg)
	click_field(ctx)
	picker_frame(ctx, &st, &value, 0, &bg)
	assert_equal(0, st.open)
	assert_equal(0, bg)
	ui_render_destroy(&fx.r)


# Open or closed, the picker takes the same ids, so the button after it
# keeps its id.
void test_ids_do_not_shift_when_it_opens():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_date_picker_state st
	ui_date_picker_init(&st)
	ui_date value
	ui_date_clear(&value)
	int32 bg = 0

	picker_frame(ctx, &st, &value, 0, &bg)
	int closed_ids = ctx.next_id
	click_field(ctx)
	picker_frame(ctx, &st, &value, 0, &bg)
	assert_equal(1, st.open)
	assert_equal(closed_ids, ctx.next_id)
	assert_equal(2 + ui_date_picker_ids(), closed_ids)
	ui_render_destroy(&fx.r)


int range_frame(ui_context* ctx, ui_date_range_state* st, ui_date* start, ui_date* end, int32* bg):
	ui_begin(ctx, 400, 400)
	int changed = ui_date_range_picker(ctx, 200.0, st, start, end, 0, c"Dates")
	if (ui_button(ctx, c"behind")):
		bg[0] = bg[0] + 1
	ui_end(ctx)
	return changed


# First click anchors and stays open; the second completes the range,
# closes and returns 1.
void test_a_range_takes_two_clicks():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_date_range_state st
	ui_date_range_init(&st)
	ui_date start
	ui_date end
	ui_date_set(&start, 2026, 9, 1)
	ui_date_set(&end, 2026, 9, 3)
	int32 bg = 0

	click_field(ctx)
	range_frame(ctx, &st, &start, &end, &bg)
	assert_equal(1, st.open)
	assert_equal(9, st.cal.month)

	# September 2026: cell 11 is the 10th, cell 16 the 15th.
	click_cell(ctx, 11)
	assert_equal(0, range_frame(ctx, &st, &start, &end, &bg))
	assert_equal(1, st.open)
	assert_date(&st.anchor, 2026, 9, 10)
	# Nothing reaches the caller until the range is complete.
	assert_date(&start, 2026, 9, 1)
	assert_date(&end, 2026, 9, 3)

	click_cell(ctx, 16)
	assert_equal(1, range_frame(ctx, &st, &start, &end, &bg))
	assert_date(&start, 2026, 9, 10)
	assert_date(&end, 2026, 9, 15)
	assert_equal(0, st.open)
	assert_equal(0, ctx.popup_depth)
	assert_equal(0, ui_date_is_set(&st.anchor))
	ui_render_destroy(&fx.r)


# An end before the start is swapped rather than refused, even across a
# page turn.
void test_a_backwards_range_is_swapped():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_date_range_state st
	ui_date_range_init(&st)
	ui_date start
	ui_date end
	ui_date_clear(&start)
	ui_date_clear(&end)
	int32 bg = 0

	click_field(ctx)
	range_frame(ctx, &st, &start, &end, &bg)
	# Unset and no today: the page is where init left it, January 1970,
	# which starts on a Thursday (cell 4 is the 1st).
	assert_equal(1970, st.cal.year)
	click_cell(ctx, 8)
	range_frame(ctx, &st, &start, &end, &bg)
	assert_date(&st.anchor, 1970, 1, 5)
	# A leading cell of the grid is December 1969: the page turns back.
	click_cell(ctx, 0)
	assert_equal(1, range_frame(ctx, &st, &start, &end, &bg))
	assert_date(&start, 1969, 12, 28)
	assert_date(&end, 1970, 1, 5)
	ui_render_destroy(&fx.r)


# The same day twice is a one-day range; return completes it from the
# keyboard too.
void test_a_one_day_range_from_the_keyboard():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_date_range_state st
	ui_date_range_init(&st)
	ui_date start
	ui_date end
	ui_date_set(&start, 2024, 2, 28)
	ui_date_set(&end, 2024, 3, 2)
	int32 bg = 0

	click_field(ctx)
	range_frame(ctx, &st, &start, &end, &bg)
	ui_test_nav(ctx, GFX_NAV_RIGHT)
	range_frame(ctx, &st, &start, &end, &bg)
	assert_date(&st.cursor, 2024, 2, 29)
	ui_test_char(ctx, 13)
	range_frame(ctx, &st, &start, &end, &bg)
	assert_date(&st.anchor, 2024, 2, 29)
	ui_test_char(ctx, 13)
	assert_equal(1, range_frame(ctx, &st, &start, &end, &bg))
	assert_date(&start, 2024, 2, 29)
	assert_date(&end, 2024, 2, 29)
	ui_render_destroy(&fx.r)


# Closing half-way drops the anchor and leaves the caller's range.
void test_closing_half_way_keeps_the_old_range():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_date_range_state st
	ui_date_range_init(&st)
	ui_date start
	ui_date end
	ui_date_set(&start, 2026, 9, 1)
	ui_date_set(&end, 2026, 9, 3)
	int32 bg = 0

	click_field(ctx)
	range_frame(ctx, &st, &start, &end, &bg)
	click_cell(ctx, 20)
	range_frame(ctx, &st, &start, &end, &bg)
	assert_equal(1, ui_date_is_set(&st.anchor))
	ui_test_char(ctx, 27)
	assert_equal(0, range_frame(ctx, &st, &start, &end, &bg))
	assert_equal(0, st.open)
	assert_equal(0, ui_date_is_set(&st.anchor))
	assert_date(&start, 2026, 9, 1)
	assert_date(&end, 2026, 9, 3)

	# Reopened, the next click is a fresh first anchor again.
	click_field(ctx)
	range_frame(ctx, &st, &start, &end, &bg)
	click_cell(ctx, 11)
	assert_equal(0, range_frame(ctx, &st, &start, &end, &bg))
	assert_equal(1, st.open)
	ui_render_destroy(&fx.r)


void test_the_range_field_text():
	ui_date a
	ui_date b
	ui_date_set(&a, 2026, 9, 1)
	ui_date_set(&b, 2026, 10, 12)
	char[28] text
	ui_date_range_format(&a, &b, &text[0])
	assert_strings_equal(c"2026-09-01 – 2026-10-12", &text[0])
