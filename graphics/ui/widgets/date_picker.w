/*
graphics.ui.widgets.date_picker: date fields that open a calendar in a
popover (docs/projects/ui_widgets.md §4.7, §6).

	ui_date_picker_state dp
	ui_date_picker_init(&dp)
	...
	if (ui_date_picker(ctx, 200.0, &dp, &due, &today, c"Due date")):
		save(due)

Collapsed, the picker is a button-look field showing the date as
YYYY-MM-DD, or the placeholder in the muted ink while the date is
unset. Clicking it opens the month grid (graphics.ui.widgets.calendar)
in a ui_popover_begin surface under the field, paged to the current
date, else to today, else wherever it was last left. Clicking a day
picks it, closes the popover and returns 1. The grid has keyboard focus
while open: arrows move a cursor ring, return picks the cursor's day,
and escape or a press outside closes without changing anything.

The picker keeps its own page and cursor (ui_date_picker_state); the
date itself stays the caller's, like a checkbox's value. Like the
calendar it reads no clock: today is an argument, possibly 0.

Ids: the field and its calendar are reserved every frame, open or not,
so a focused widget issued after the picker keeps its id while the
popover comes and goes.
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
import graphics.ui.widgets.calendar


# The collapsed field every date and time picker shares: a tonal
# rounded rect with the value (or muted placeholder) and a chevron.
void ui_picker_field_draw(ui_context* ctx, int id, ui_rect r, char* text, int is_placeholder):
	int scale = ctx.theme.text_scale
	ui_draw_rrect(ctx.rndr, r, cast(float32, ctx.theme.radius), ui_widget_fill(ctx, id))
	ui_color ink = ui_text_color(ctx)
	if (is_placeholder && (ctx.disabled == 0)):
		ink = ctx.theme.text_muted
	float32 chev = 12.0
	float32 pad = cast(float32, ctx.theme.pad)
	float32 ty = r.y + (r.h - cast(float32, ui_text_height(scale))) * 0.5
	ui_clip_push(ctx.rndr, ui_rect_new(r.x + pad, r.y, r.w - pad * 3.0 - chev, r.h))
	if (text != 0):
		ui_draw_text(ctx.rndr, r.x + pad, ty, text, scale, ink)
	ui_clip_pop(ctx.rndr)
	ui_draw_chevron(ctx.rndr, ui_rect_new(r.x + r.w - pad - chev, r.y + (r.h - chev) * 0.5, chev, chev), ctx.theme.text_muted)


# Open-on-click for a picker field: returns 1 on the frame the field is
# clicked while closed. The opening press is consumed, so the popover
# that opens in the same frame does not read it as a press outside
# itself and close again.
int ui_picker_field_click(ui_context* ctx, int id, ui_rect r, int32* open):
	if (open[0]):
		ctx.hot = id
		return 0
	if (ui_click_behavior(ctx, id, r)):
		open[0] = 1
		ctx.input.mouse_pressed = 0
		return 1
	return 0


# Surface size around a calendar.
float32 ui_date_popover_w(ui_context* ctx):
	return ui_calendar_width(ctx) + cast(float32, ctx.theme.pad) * 2.0


float32 ui_date_popover_h(ui_context* ctx):
	return ui_calendar_height(ctx) + cast(float32, ctx.theme.pad) * 2.0


# Where the calendar of a picker whose field is at `field` draws.
ui_rect ui_date_picker_calendar_rect(ui_context* ctx, ui_rect field):
	ui_rect s = ui_popover_place(field, ui_date_popover_w(ctx), ui_date_popover_h(ctx), cast(float32, ctx.rndr.vp_w), cast(float32, ctx.rndr.vp_h))
	float32 pad = cast(float32, ctx.theme.pad)
	return ui_rect_new(s.x + pad, s.y + pad, ui_calendar_width(ctx), ui_calendar_height(ctx))


# Page a calendar to the first set date of a, b; leave it be if neither.
void ui_date_picker_page_to(ui_calendar_state* cal, ui_date* a, ui_date* b):
	if (ui_date_is_set(a)):
		ui_calendar_show(cal, a)
	else if (ui_date_is_set(b)):
		ui_calendar_show(cal, b)


# Close a picker's popover from inside its own body: unregister it now,
# so widgets after it in this frame are live again, and drop the grid's
# keyboard focus with it.
void ui_date_picker_close(ui_context* ctx, int id, int32* open):
	open[0] = 0
	ui_popup_dismiss(ctx, id)
	if (ctx.focus == id + 3):
		ctx.focus = 0


struct ui_date_picker_state:
	ui_calendar_state cal  # the page on show while open
	ui_date cursor         # the keyboard's day while open
	int32 open


void ui_date_picker_init(ui_date_picker_state* st):
	ui_calendar_init(&st.cal, 1970, 1)
	ui_date_clear(&st.cursor)
	st.open = 0


# The field ids plus the calendar's.
int ui_date_picker_ids():
	return 1 + ui_calendar_ids


# A date field over caller-owned *value (day 0 = unset). placeholder
# (may be 0) shows while unset. Returns 1 on the frame a day is picked
# that differs from *value.
int ui_date_picker(ui_context* ctx, float32 w, ui_date_picker_state* st, ui_date* value, ui_date* today, char* placeholder):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + ui_date_picker_ids()
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))

	if (ui_picker_field_click(ctx, id, r, &st.open)):
		ui_date_picker_page_to(&st.cal, value, today)
		ui_date_copy(&st.cursor, value)
		# The grid takes the keys from the moment it opens.
		ctx.focus = id + 3

	char[12] text
	if (ui_date_is_set(value)):
		ui_date_format(value, &text[0])
		ui_picker_field_draw(ctx, id, r, &text[0], 0)
	else:
		ui_picker_field_draw(ctx, id, r, placeholder, 1)

	int changed = 0
	if (ui_popover_begin(ctx, id, r, ui_date_popover_w(ctx), ui_date_popover_h(ctx), &st.open)):
		ui_rect cr = ui_layout_next(ctx, ui_calendar_width(ctx), ui_calendar_height(ctx))
		ui_date picked
		ui_date_clear(&picked)
		int what = ui_calendar_grid(ctx, id + 1, cr, &st.cal, value, &st.cursor, 0, 0, today, &picked)
		ui_popover_end(ctx)
		if (what == UI_CALENDAR_MOVED):
			ui_date_copy(&st.cursor, &picked)
		else if ((what == UI_CALENDAR_CLICKED) || (what == UI_CALENDAR_COMMIT)):
			if (ui_date_equal(&picked, value) == 0):
				ui_date_copy(value, &picked)
				changed = 1
			ui_date_picker_close(ctx, id, &st.open)
	else if (ctx.focus == id + 3):
		ctx.focus = 0
	return changed


/*
The date range picker: the same field and popover, with two anchors
over one grid.

	if (ui_date_range_picker(ctx, 260.0, &rp, &from, &to, &today, c"Dates")):
		search(from, to)

The first pick sets an anchor and the popover stays open; while it is
anchored the band follows the pointer (or the keyboard cursor) to
preview the range. The second pick completes it: the earlier of the two
becomes the start, the popover closes and the call returns 1. Picking
the same day twice is a one-day range. Closing half-way (escape, a
press outside) drops the anchor and leaves the caller's range as it
was: *start and *end only ever change together.
*/
struct ui_date_range_state:
	ui_calendar_state cal
	ui_date anchor         # the first pick of a range in progress
	ui_date cursor         # the keyboard's day while open
	int32 open


void ui_date_range_init(ui_date_range_state* st):
	ui_calendar_init(&st.cal, 1970, 1)
	ui_date_clear(&st.anchor)
	ui_date_clear(&st.cursor)
	st.open = 0


# Write "YYYY-MM-DD – YYYY-MM-DD" plus a NUL (26 bytes; the dash is an
# en dash, three bytes of UTF-8).
void ui_date_range_format(ui_date* start, ui_date* end, char* out):
	ui_date_format(start, out)
	out[10] = ' '
	out[11] = 0xe2
	out[12] = 0x80
	out[13] = 0x93
	out[14] = ' '
	ui_date_format(end, &out[15])


# A date range field over caller-owned *start and *end (both unset, or
# both set with start <= end). Returns 1 on the frame a complete range
# is picked.
int ui_date_range_picker(ui_context* ctx, float32 w, ui_date_range_state* st, ui_date* start, ui_date* end, ui_date* today, char* placeholder):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + ui_date_picker_ids()
	ui_rect r = ui_layout_next(ctx, w, cast(float32, ctx.theme.widget_height))

	if (ui_picker_field_click(ctx, id, r, &st.open)):
		ui_date_picker_page_to(&st.cal, start, today)
		ui_date_clear(&st.anchor)
		ui_date_copy(&st.cursor, start)
		ctx.focus = id + 3

	char[28] text
	if (ui_date_is_set(start) && ui_date_is_set(end)):
		ui_date_range_format(start, end, &text[0])
		ui_picker_field_draw(ctx, id, r, &text[0], 0)
	else:
		ui_picker_field_draw(ctx, id, r, placeholder, 1)

	int changed = 0
	if (ui_popover_begin(ctx, id, r, ui_date_popover_w(ctx), ui_date_popover_h(ctx), &st.open)):
		ui_rect cr = ui_layout_next(ctx, ui_calendar_width(ctx), ui_calendar_height(ctx))
		# The band: the caller's range, or while anchored, the anchor to
		# the day under the pointer (else the keyboard cursor).
		ui_date a
		ui_date b
		ui_date_copy(&a, start)
		ui_date_copy(&b, end)
		if (ui_date_is_set(&st.anchor)):
			ui_date_copy(&a, &st.anchor)
			ui_date_copy(&b, &st.anchor)
			int hover = ui_calendar_cell_at(ctx, cr, ctx.input.mouse_x, ctx.input.mouse_y)
			if (hover >= 0):
				ui_calendar_cell_date(&st.cal, hover, &b)
			else if (ui_date_is_set(&st.cursor)):
				ui_date_copy(&b, &st.cursor)
		ui_date picked
		ui_date_clear(&picked)
		int what = ui_calendar_grid(ctx, id + 1, cr, &st.cal, 0, &st.cursor, &a, &b, today, &picked)
		ui_popover_end(ctx)
		if (what == UI_CALENDAR_MOVED):
			ui_date_copy(&st.cursor, &picked)
		else if ((what == UI_CALENDAR_CLICKED) || (what == UI_CALENDAR_COMMIT)):
			ui_date_copy(&st.cursor, &picked)
			if (ui_date_is_set(&st.anchor) == 0):
				ui_date_copy(&st.anchor, &picked)
			else:
				if (ui_date_compare(&picked, &st.anchor) < 0):
					ui_date_copy(start, &picked)
					ui_date_copy(end, &st.anchor)
				else:
					ui_date_copy(start, &st.anchor)
					ui_date_copy(end, &picked)
				ui_date_clear(&st.anchor)
				changed = 1
				ui_date_picker_close(ctx, id, &st.open)
	else:
		ui_date_clear(&st.anchor)
		if (ctx.focus == id + 3):
			ctx.focus = 0
	return changed
