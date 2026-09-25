# Headless unit tests for the time range picker: spinner arithmetic,
# the popover and its spinners, and the overnight rule
# (docs/projects/ui_widgets.md §4.7). No GL context or
# display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_time_picker_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


ui_rect field_rect(ui_context* ctx):
	float32 pad = cast(float32, ctx.theme.pad)
	return ui_rect_new(pad, pad, 200.0, cast(float32, ctx.theme.widget_height))


void click_field(ui_context* ctx):
	ui_rect f = field_rect(ctx)
	ui_test_click(ctx, cast(int, f.x + 20.0), cast(int, f.y + f.h * 0.5))


# Row i (0 = From, 1 = To) of the open popover.
ui_rect row_rect(ui_context* ctx, int i):
	ui_rect s = ui_popover_place(field_rect(ctx), ui_time_popover_w(ctx), ui_time_popover_h(ctx), 400.0, 400.0)
	float32 pad = cast(float32, ctx.theme.pad)
	float32 wh = cast(float32, ctx.theme.widget_height)
	return ui_rect_new(s.x + pad, s.y + pad + cast(float32, i) * (wh + cast(float32, ctx.theme.gap)), ui_time_popover_w(ctx) - pad * 2.0, wh)


void click_rect(ui_context* ctx, ui_rect b):
	ui_test_click(ctx, cast(int, b.x + b.w * 0.5), cast(int, b.y + b.h * 0.5))


# Click a spinner button: row 0 = From, 1 = To; minutes 0 = the hour
# spinner, 1 = the minute one; dir -1 = minus, +1 = plus.
void click_spin(ui_context* ctx, int row, int minutes, int dir):
	ui_rect rr = row_rect(ctx, row)
	float32 x = ui_time_hour_x(ctx, rr)
	if (minutes):
		x = ui_time_minute_x(ctx, rr)
	if (dir < 0):
		click_rect(ctx, ui_spinner_minus_rect(ctx, rr, x))
	else:
		click_rect(ctx, ui_spinner_plus_rect(ctx, rr, x))


# One frame: the picker with a 5-minute step, then a button below it;
# bg counts the button's clicks.
int time_frame(ui_context* ctx, ui_time_range_state* st, int32* start, int32* end, int32* bg):
	ui_begin(ctx, 400, 400)
	int changed = ui_time_range_picker(ctx, 200.0, st, start, end, 5)
	if (ui_button(ctx, c"behind")):
		bg[0] = bg[0] + 1
	ui_end(ctx)
	return changed


void test_spinner_steps_snap_and_wrap():
	assert_equal(10, ui_spin_step(5, 60, 5, 1))
	assert_equal(0, ui_spin_step(55, 60, 5, 1))
	assert_equal(55, ui_spin_step(0, 60, 5, -1))
	# Off the step grid: snap to the neighbouring multiple.
	assert_equal(10, ui_spin_step(7, 60, 5, 1))
	assert_equal(5, ui_spin_step(7, 60, 5, -1))
	# A step that does not divide 60 wraps to its largest multiple.
	assert_equal(56, ui_spin_step(0, 60, 7, -1))
	assert_equal(0, ui_spin_step(56, 60, 7, 1))
	# Hours.
	assert_equal(0, ui_spin_step(23, 24, 1, 1))
	assert_equal(23, ui_spin_step(0, 24, 1, -1))
	# A step below 1 is 1.
	assert_equal(8, ui_spin_step(7, 60, 0, 1))


void test_the_overnight_rule():
	assert_equal(8 * 60, ui_time_range_minutes(9 * 60, 17 * 60))
	assert_equal(8 * 60, ui_time_range_minutes(22 * 60, 6 * 60))
	assert_equal(0, ui_time_range_minutes(12 * 60, 12 * 60))
	assert_equal(1439, ui_time_wrap(-1))
	assert_equal(0, ui_time_wrap(1440))


void test_the_field_text():
	char[20] text
	ui_time_range_format(9 * 60 + 5, 17 * 60 + 30, &text[0])
	assert_strings_equal(c"09:05 – 17:30", &text[0])
	ui_time_range_format(22 * 60, 6 * 60, &text[0])
	assert_strings_equal(c"22:00 – 06:00 +1", &text[0])
	ui_time_range_format(0, 0, &text[0])
	assert_strings_equal(c"00:00 – 00:00", &text[0])


void test_spinners_change_each_end():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_time_range_state st
	ui_time_range_init(&st)
	int32 start = 9 * 60
	int32 end = 17 * 60
	int32 bg = 0

	assert_equal(0, time_frame(ctx, &st, &start, &end, &bg))
	click_field(ctx)
	assert_equal(0, time_frame(ctx, &st, &start, &end, &bg))
	assert_equal(1, st.open)
	assert_equal(1, ctx.popup_depth)

	click_spin(ctx, 0, 0, 1)
	assert_equal(1, time_frame(ctx, &st, &start, &end, &bg))
	assert_equal(10 * 60, start)
	assert_equal(1, st.open)

	click_spin(ctx, 0, 1, 1)
	assert_equal(1, time_frame(ctx, &st, &start, &end, &bg))
	assert_equal(10 * 60 + 5, start)

	# Minutes wrap without carrying into the hour: 17:00 - 5 is 17:55.
	click_spin(ctx, 1, 1, -1)
	assert_equal(1, time_frame(ctx, &st, &start, &end, &bg))
	assert_equal(17 * 60 + 55, end)

	click_spin(ctx, 1, 0, -1)
	time_frame(ctx, &st, &start, &end, &bg)
	assert_equal(16 * 60 + 55, end)

	# A frame with no clicks changes nothing.
	assert_equal(0, time_frame(ctx, &st, &start, &end, &bg))
	assert_equal(0, bg)
	ui_render_destroy(&fx.r)


# Hours wrap at midnight, and an end pushed before the start is kept as
# an overnight range rather than clamped.
void test_hours_wrap_into_an_overnight_range():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_time_range_state st
	ui_time_range_init(&st)
	int32 start = 22 * 60
	int32 end = 23 * 60 + 30
	int32 bg = 0

	click_field(ctx)
	time_frame(ctx, &st, &start, &end, &bg)
	click_spin(ctx, 1, 0, 1)
	assert_equal(1, time_frame(ctx, &st, &start, &end, &bg))
	assert_equal(30, end)
	assert_equal(22 * 60, start)
	assert_equal(150, ui_time_range_minutes(start, end))
	ui_render_destroy(&fx.r)


void test_escape_return_and_outside_presses_close():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_time_range_state st
	ui_time_range_init(&st)
	int32 start = 9 * 60
	int32 end = 17 * 60
	int32 bg = 0

	click_field(ctx)
	time_frame(ctx, &st, &start, &end, &bg)
	ui_test_char(ctx, 27)
	time_frame(ctx, &st, &start, &end, &bg)
	assert_equal(0, st.open)
	assert_equal(0, ctx.popup_depth)

	click_field(ctx)
	time_frame(ctx, &st, &start, &end, &bg)
	ui_test_char(ctx, 13)
	time_frame(ctx, &st, &start, &end, &bg)
	assert_equal(0, st.open)
	assert_equal(0, ctx.popup_depth)

	click_field(ctx)
	time_frame(ctx, &st, &start, &end, &bg)
	ui_test_click(ctx, 390, 390)
	assert_equal(0, time_frame(ctx, &st, &start, &end, &bg))
	assert_equal(0, st.open)
	assert_equal(0, bg)
	assert_equal(9 * 60, start)
	assert_equal(17 * 60, end)
	ui_render_destroy(&fx.r)


# Open or closed, the picker takes the same ids, so the button after it
# keeps its id.
void test_ids_do_not_shift_when_it_opens():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_time_range_state st
	ui_time_range_init(&st)
	int32 start = 0
	int32 end = 0
	int32 bg = 0

	time_frame(ctx, &st, &start, &end, &bg)
	int closed_ids = ctx.next_id
	click_field(ctx)
	time_frame(ctx, &st, &start, &end, &bg)
	assert_equal(1, st.open)
	assert_equal(closed_ids, ctx.next_id)
	assert_equal(2 + ui_time_range_ids(), closed_ids)
	ui_render_destroy(&fx.r)
