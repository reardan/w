/*
graphics.ui.widgets.time_picker: a time range field with hour and
minute spinners in a popover (docs/projects/ui_widgets.md §4.7, §6).

	ui_time_range_state tp
	ui_time_range_init(&tp)
	int32 open_at = 9 * 60
	int32 close_at = 17 * 60
	...
	if (ui_time_range_picker(ctx, 180.0, &tp, &open_at, &close_at, 15)):
		save(open_at, close_at)

Times are caller-owned minutes since midnight, 0..1439. The field
shows "HH:MM – HH:MM"; clicking it opens a popover with a From and a To
row, each an hour spinner and a minute spinner ([-] value [+]). Every
spinner click changes the caller's value at once and returns 1; escape,
return or a press outside closes the popover.

Spinners wrap within their own unit and do not carry: 23 + 1 hour is 0
with the minutes unchanged, and 55 + 5 minutes is 0 with the hour
unchanged, the way a native time spinner behaves. Minutes step by the
caller's minute_step, snapping to its multiples: an off-grid 07 steps
to 10 up or 05 down.

The overnight rule: the two ends are independent, and an end before
the start means the range crosses midnight (22:00 – 06:00 is eight
hours), which the field marks with a trailing "+1". Clamping one end
against the other would fight the wrap-around, and a night shift is a
real range. Equal ends are an empty range. ui_time_range_minutes gives
the length under that rule.

Like the date pickers it reads no clock and reserves its ids (the
field plus two per spinner) every frame, open or not.
*/
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.overlay
import graphics.ui.widgets.popover
import graphics.ui.widgets.date_picker


int ui_minutes_per_day():
	return 1440


# Minutes since midnight, wrapped into 0..1439.
int ui_time_wrap(int minutes):
	int m = minutes % ui_minutes_per_day()
	if (m < 0):
		m = m + ui_minutes_per_day()
	return m


# Length of the range start..end in minutes. An end before the start
# crosses midnight; equal ends are empty.
int ui_time_range_minutes(int start, int end):
	return ui_time_wrap(end - start)


# One spinner step of value in 0..modulo-1, snapping to multiples of
# step and wrapping at either end without carrying. dir is +1 or -1.
int ui_spin_step(int value, int modulo, int step, int dir):
	if (step < 1):
		step = 1
	int v = 0
	if (dir > 0):
		v = (value / step + 1) * step
		if (v >= modulo):
			v = 0
	else:
		if ((value % step) != 0):
			v = (value / step) * step
		else:
			v = value - step
		if (v < 0):
			v = ((modulo - 1) / step) * step
	return v


# Write "HH:MM" into out (no NUL).
void ui_time_write(int minutes, char* out):
	int m = ui_time_wrap(minutes)
	int h = m / 60
	m = m % 60
	out[0] = '0' + h / 10
	out[1] = '0' + h % 10
	out[2] = ':'
	out[3] = '0' + m / 10
	out[4] = '0' + m % 10


# Write "HH:MM – HH:MM", plus " +1" when the range crosses midnight,
# and a NUL into out (20 bytes; the dash is a three-byte en dash).
void ui_time_range_format(int start, int end, char* out):
	ui_time_write(start, out)
	out[5] = ' '
	out[6] = 0xe2
	out[7] = 0x80
	out[8] = 0x93
	out[9] = ' '
	ui_time_write(end, &out[10])
	if (ui_time_wrap(end) < ui_time_wrap(start)):
		out[15] = ' '
		out[16] = '+'
		out[17] = '1'
		out[18] = 0
	else:
		out[15] = 0


struct ui_time_range_state:
	int32 open


void ui_time_range_init(ui_time_range_state* st):
	st.open = 0


int ui_time_range_ids():
	return 9


# Spinner geometry: a square button either side of the value.
float32 ui_spinner_button_w(ui_context* ctx):
	return cast(float32, ctx.theme.widget_height) - 8.0


float32 ui_spinner_value_w(ui_context* ctx):
	return cast(float32, ui_text_width(c"00", ctx.theme.text_scale) + ctx.theme.pad * 2)


float32 ui_spinner_w(ui_context* ctx):
	return ui_spinner_button_w(ctx) * 2.0 + ui_spinner_value_w(ctx)


float32 ui_time_label_w(ui_context* ctx):
	return cast(float32, ui_text_width(c"From", ctx.theme.text_scale) + ctx.theme.pad)


float32 ui_time_colon_w():
	return 12.0


float32 ui_time_popover_w(ui_context* ctx):
	return ui_time_label_w(ctx) + ui_spinner_w(ctx) * 2.0 + ui_time_colon_w() + cast(float32, ctx.theme.pad) * 2.0


float32 ui_time_popover_h(ui_context* ctx):
	return cast(float32, ctx.theme.widget_height * 2 + ctx.theme.gap + ctx.theme.pad * 2)


# The minus and plus buttons of a spinner whose left edge is x in row.
ui_rect ui_spinner_minus_rect(ui_context* ctx, ui_rect row, float32 x):
	float32 b = ui_spinner_button_w(ctx)
	return ui_rect_new(x, row.y + (row.h - b) * 0.5, b, b)


ui_rect ui_spinner_plus_rect(ui_context* ctx, ui_rect row, float32 x):
	float32 b = ui_spinner_button_w(ctx)
	return ui_rect_new(x + b + ui_spinner_value_w(ctx), row.y + (row.h - b) * 0.5, b, b)


void ui_spinner_button_draw(ui_context* ctx, int id, ui_rect r, char* mark):
	ui_draw_rrect(ctx.rndr, r, r.h * 0.5, ui_widget_fill(ctx, id))
	ui_draw_text_centered(ctx.rndr, r, mark, ctx.theme.text_scale, ui_text_color(ctx))


# One spinner at x in row over value in 0..modulo-1, ids base_id and
# base_id + 1. Returns the new value.
int ui_spinner_at(ui_context* ctx, int base_id, ui_rect row, float32 x, int value, int modulo, int step):
	ui_rect minus = ui_spinner_minus_rect(ctx, row, x)
	ui_rect plus = ui_spinner_plus_rect(ctx, row, x)
	int v = value
	if (ui_click_behavior(ctx, base_id, minus)):
		v = ui_spin_step(v, modulo, step, -1)
	if (ui_click_behavior(ctx, base_id + 1, plus)):
		v = ui_spin_step(v, modulo, step, 1)
	ui_spinner_button_draw(ctx, base_id, minus, c"-")
	ui_spinner_button_draw(ctx, base_id + 1, plus, c"+")
	char[3] text
	text[0] = '0' + v / 10
	text[1] = '0' + v % 10
	text[2] = 0
	ui_draw_text_centered(ctx.rndr, ui_rect_new(minus.x + minus.w, row.y, ui_spinner_value_w(ctx), row.h), &text[0], ctx.theme.text_scale, ui_text_color(ctx))
	return v


# Left edges of a row's hour and minute spinners.
float32 ui_time_hour_x(ui_context* ctx, ui_rect row):
	return row.x + ui_time_label_w(ctx)


float32 ui_time_minute_x(ui_context* ctx, ui_rect row):
	return ui_time_hour_x(ctx, row) + ui_spinner_w(ctx) + ui_time_colon_w()


# One "label HH : MM" row over *minutes, ids base_id .. base_id + 3.
# Returns 1 when it changed.
int ui_time_row(ui_context* ctx, int base_id, char* label, int32* minutes, int minute_step):
	int scale = ctx.theme.text_scale
	ui_rect row = ui_layout_next(ctx, ui_time_popover_w(ctx) - cast(float32, ctx.theme.pad) * 2.0, cast(float32, ctx.theme.widget_height))
	int m = ui_time_wrap(minutes[0])
	int h = ui_spinner_at(ctx, base_id, row, ui_time_hour_x(ctx, row), m / 60, 24, 1)
	int mm = ui_spinner_at(ctx, base_id + 2, row, ui_time_minute_x(ctx, row), m % 60, 60, minute_step)
	float32 ty = row.y + (row.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_draw_text(ctx.rndr, row.x, ty, label, scale, ctx.theme.text_muted)
	ui_draw_text_centered(ctx.rndr, ui_rect_new(ui_time_minute_x(ctx, row) - ui_time_colon_w(), row.y, ui_time_colon_w(), row.h), c":", scale, ui_text_color(ctx))
	int v = h * 60 + mm
	if (v != minutes[0]):
		minutes[0] = v
		return 1
	return 0


# A time range field over caller-owned *start and *end, in minutes
# since midnight. minute_step is the minute spinners' step (1, 5, 15,
# ...). Returns 1 on every frame a spinner changes either end.
int ui_time_range_picker(ui_context* ctx, float32 w, ui_time_range_state* st, int32* start, int32* end, int minute_step):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + ui_time_range_ids()
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))
	ui_picker_field_click(ctx, id, r, &st.open)

	char[20] text
	ui_time_range_format(start[0], end[0], &text[0])
	ui_picker_field_draw(ctx, id, r, &text[0], 0)

	int changed = 0
	if (ui_popover_begin(ctx, id, r, ui_time_popover_w(ctx), ui_time_popover_h(ctx), &st.open)):
		if (ui_time_row(ctx, id + 1, c"From", start, minute_step)):
			changed = 1
		if (ui_time_row(ctx, id + 5, c"To", end, minute_step)):
			changed = 1
		ui_popover_end(ctx)
		# Return closes too: there is nothing to confirm, the spinners
		# have already written through.
		int i = 0
		while (i < ctx.char_count):
			if (ctx.chars[i] == 13):
				st.open = 0
				ui_popup_dismiss(ctx, id)
			i = i + 1
	return changed
