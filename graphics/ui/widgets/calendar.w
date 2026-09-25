/*
graphics.ui.widgets.calendar: a month grid (docs/projects/ui_widgets.md
§4.7, §6).

	ui_calendar_state cal
	ui_calendar_init(&cal, 2026, 9)
	ui_date picked
	ui_date_clear(&picked)
	...
	if (ui_calendar(ctx, &cal, &picked, &today)): use(picked)

A header (month name and year between previous/next arrows), a weekday
row, and a fixed 6x7 grid of days: six rows always fit, since a month
of 31 days starting on the last column needs 6 + 31 = 37 cells, and a
fixed height keeps the widget from jumping as the month changes. Days
of the neighbouring months fill the leading and trailing cells, muted,
and stay clickable: picking one selects it and turns the view to its
month.

The shown month is caller state (ui_calendar_state), separate from the
selected date, so a caller can page through months without losing the
selection. Selection is a ui_date, where day 0 means "none".

The calendar reads no clock. "Today" is an argument, possibly 0, per
§9.3: UI code should not read clocks.

Clicking a day focuses the grid; while focused, the arrow keys move the
selection a day (left/right) or a week (up/down) and page up/down move
it a month, turning the view to follow; escape drops focus. The date
pickers build on the same grid through ui_calendar_grid, which reports
what was picked instead of storing it and can shade a range.

A calendar takes three widget ids (previous, next, grid) every frame,
whatever it draws, so the ids after it never shift.
*/
import lib.time
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context


# A civil date. day 0 means "no date".
struct ui_date:
	int32 year
	int32 month            # 1..12
	int32 day              # 1..31, 0 = unset


void ui_date_set(ui_date* d, int year, int month, int day):
	d.year = year
	d.month = month
	d.day = day


void ui_date_clear(ui_date* d):
	d.year = 0
	d.month = 0
	d.day = 0


int ui_date_is_set(ui_date* d):
	if (d == 0): return 0
	if (d.day == 0): return 0
	return 1


# Copy a date field by field. A plain struct assignment of this
# 12-byte struct writes 16 bytes on x64, clobbering whatever follows
# it, so dates are never assigned whole.
void ui_date_copy(ui_date* dst, ui_date* src):
	dst.year = src.year
	dst.month = src.month
	dst.day = src.day


# Days since 1970-01-01, for ordering and range tests.
int ui_date_days(ui_date* d):
	return time_days_from_civil(d.year, d.month, d.day)


# <0, 0 or >0 as a is before, the same day as, or after b.
int ui_date_compare(ui_date* a, ui_date* b):
	return ui_date_days(a) - ui_date_days(b)


int ui_date_equal(ui_date* a, ui_date* b):
	if ((a.year == b.year) && (a.month == b.month) && (a.day == b.day)): return 1
	return 0


# Carry an out-of-range day into the neighbouring months (day 0 is the
# last of the previous month, day 32 of January is February 1st).
void ui_date_normalize(ui_date* d):
	while (d.day < 1):
		d.month = d.month - 1
		if (d.month < 1):
			d.month = 12
			d.year = d.year - 1
		d.day = d.day + time_days_in_month(d.year, d.month)
	int dim = time_days_in_month(d.year, d.month)
	while (d.day > dim):
		d.day = d.day - dim
		d.month = d.month + 1
		if (d.month > 12):
			d.month = 1
			d.year = d.year + 1
		dim = time_days_in_month(d.year, d.month)


void ui_date_add_days(ui_date* d, int n):
	d.day = d.day + n
	ui_date_normalize(d)


# Move by whole months, clamping the day to the target month's length
# (January 31st plus one month is February 28th or 29th).
void ui_date_add_months(ui_date* d, int n):
	int m = d.year * 12 + (d.month - 1) + n
	int y = m / 12
	int mi = m % 12
	if (mi < 0):
		mi = mi + 12
		y = y - 1
	d.year = y
	d.month = mi + 1
	int dim = time_days_in_month(d.year, d.month)
	if (d.day > dim): d.day = dim


# Write d as "YYYY-MM-DD" plus a NUL into out (11 bytes).
void ui_date_format(ui_date* d, char* out):
	time_write_4_digits(out, d.year)
	out[4] = '-'
	time_write_2_digits(&out[5], d.month)
	out[7] = '-'
	time_write_2_digits(&out[8], d.day)
	out[10] = 0


# The month on show, and which weekday the grid's first column is.
struct ui_calendar_state:
	int32 year
	int32 month
	int32 first_weekday    # 0 = weeks start on Sunday, 1 = Monday, ...


void ui_calendar_init(ui_calendar_state* st, int year, int month):
	st.year = year
	st.month = month
	st.first_weekday = 0


# Show the month delta months away from the current one; wraps years.
void ui_calendar_show_month(ui_calendar_state* st, int delta):
	ui_date d
	ui_date_set(&d, st.year, st.month, 1)
	ui_date_add_months(&d, delta)
	st.year = d.year
	st.month = d.month


void ui_calendar_show(ui_calendar_state* st, ui_date* d):
	st.year = d.year
	st.month = d.month


const int ui_calendar_cells = 42


# Cells before the 1st of the shown month, 0..6.
int ui_calendar_lead(ui_calendar_state* st):
	int wd = time_weekday_from_civil(st.year, st.month, 1)
	return (wd - st.first_weekday + 14) % 7


# The date in grid cell 0..41 (row-major), which may fall in the
# previous or next month.
void ui_calendar_cell_date(ui_calendar_state* st, int cell, ui_date* out):
	ui_date_set(out, st.year, st.month, cell - ui_calendar_lead(st) + 1)
	ui_date_normalize(out)


# The grid cell showing d, or -1 when it is not on the grid.
int ui_calendar_cell_of(ui_calendar_state* st, ui_date* d):
	ui_date first
	ui_calendar_cell_date(st, 0, &first)
	int cell = ui_date_days(d) - ui_date_days(&first)
	if ((cell < 0) || (cell >= ui_calendar_cells)): return -1
	return cell


# Geometry: square day cells one widget-height on a side.
float32 ui_calendar_cell_size(ui_context* ctx):
	return cast(float32, ctx.theme.widget_height)


float32 ui_calendar_weekday_row_h(ui_context* ctx):
	return cast(float32, ui_text_height(ctx.theme.text_scale) + 6)


float32 ui_calendar_width(ui_context* ctx):
	return ui_calendar_cell_size(ctx) * 7.0


float32 ui_calendar_height(ui_context* ctx):
	return ui_calendar_cell_size(ctx) * 7.0 + ui_calendar_weekday_row_h(ctx)


# The 6x7 day area inside a calendar placed at r.
ui_rect ui_calendar_grid_rect(ui_context* ctx, ui_rect r):
	float32 top = ui_calendar_cell_size(ctx) + ui_calendar_weekday_row_h(ctx)
	return ui_rect_new(r.x, r.y + top, ui_calendar_cell_size(ctx) * 7.0, ui_calendar_cell_size(ctx) * 6.0)


ui_rect ui_calendar_cell_rect(ui_context* ctx, ui_rect r, int cell):
	ui_rect g = ui_calendar_grid_rect(ctx, r)
	float32 s = ui_calendar_cell_size(ctx)
	return ui_rect_new(g.x + s * cast(float32, cell % 7), g.y + s * cast(float32, cell / 7), s, s)


# The cell under a point, or -1.
int ui_calendar_cell_at(ui_context* ctx, ui_rect r, int x, int y):
	ui_rect g = ui_calendar_grid_rect(ctx, r)
	if (ui_rect_contains(g, cast(float32, x), cast(float32, y)) == 0): return -1
	float32 s = ui_calendar_cell_size(ctx)
	int col = cast(int, (cast(float32, x) - g.x) / s)
	int row = cast(int, (cast(float32, y) - g.y) / s)
	if (col > 6): col = 6
	if (row > 5): row = 5
	return row * 7 + col


const int ui_calendar_ids = 3


# What ui_calendar_grid reports.
enum ui_calendar_event:
	UI_CALENDAR_NONE = 0
	UI_CALENDAR_CLICKED = 1  # a day was clicked
	UI_CALENDAR_MOVED = 2    # a key moved the cursor
	UI_CALENDAR_COMMIT = 3   # return was typed while focused


# The grid under every calendar widget, drawn at r with ids base_id ..
# base_id + 2. cursor is the date the keyboard moves (0 = no keyboard);
# range_a..range_b, when both set, shade the days between them.
# selected (may be 0) draws filled. Reports through the return value:
# UI_CALENDAR_CLICKED with the day in picked; UI_CALENDAR_MOVED when a
# key moved the cursor (picked = the new cursor); UI_CALENDAR_COMMIT on
# return while focused (picked = the cursor). Stores nothing but the
# view month, which it turns to follow a pick or a keyboard move.
int ui_calendar_grid(ui_context* ctx, int base_id, ui_rect r, ui_calendar_state* st, ui_date* selected, ui_date* cursor, ui_date* range_a, ui_date* range_b, ui_date* today, ui_date* picked):
	int prev_id = base_id
	int next_id = base_id + 1
	int grid_id = base_id + 2
	int scale = ctx.theme.text_scale
	float32 s = ui_calendar_cell_size(ctx)
	int result = UI_CALENDAR_NONE

	# Header arrows: a click turns the page.
	ui_rect prev = ui_rect_new(r.x, r.y, s, s)
	ui_rect next = ui_rect_new(r.x + r.w - s, r.y, s, s)
	if (ui_click_behavior(ctx, prev_id, prev)): ui_calendar_show_month(st, -1)
	if (ui_click_behavior(ctx, next_id, next)): ui_calendar_show_month(st, 1)

	# The grid is one id: the click is a release over the same cell the
	# press landed in.
	ui_rect g = ui_calendar_grid_rect(ctx, r)
	int grid_click = ui_click_behavior(ctx, grid_id, g)
	if (ctx.input.mouse_pressed && (ui_scope_blocked(ctx) == 0) && (ctx.disabled == 0)):
		if (ui_rect_contains(g, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
			if (cursor != 0): ctx.focus = grid_id
		else if (ctx.focus == grid_id): ctx.focus = 0
	if (grid_click):
		int cell = ui_calendar_cell_at(ctx, r, ctx.input.mouse_x, ctx.input.mouse_y)
		if ((cell >= 0) && (cell == ui_calendar_cell_at(ctx, r, ctx.input.press_x, ctx.input.press_y))):
			ui_calendar_cell_date(st, cell, picked)
			ui_calendar_show(st, picked)
			result = UI_CALENDAR_CLICKED

	# Keyboard, while focused: days, weeks and months.
	if ((cursor != 0) && (ctx.focus == grid_id) && (result == UI_CALENDAR_NONE)):
		ui_date c
		ui_date_copy(&c, cursor)
		if (ui_date_is_set(&c) == 0): ui_date_set(&c, st.year, st.month, 1)
		int moved = 0
		int i = 0
		while (i < ctx.nav_count):
			int nav = ctx.navs[i]
			if (nav == GFX_NAV_LEFT):
				ui_date_add_days(&c, -1)
				moved = 1
			else if (nav == GFX_NAV_RIGHT):
				ui_date_add_days(&c, 1)
				moved = 1
			else if (nav == GFX_NAV_UP):
				ui_date_add_days(&c, -7)
				moved = 1
			else if (nav == GFX_NAV_DOWN):
				ui_date_add_days(&c, 7)
				moved = 1
			else if (nav == GFX_NAV_PAGE_UP):
				ui_date_add_months(&c, -1)
				moved = 1
			else if (nav == GFX_NAV_PAGE_DOWN):
				ui_date_add_months(&c, 1)
				moved = 1
			i = i + 1
		if (moved):
			ui_date_copy(picked, &c)
			ui_calendar_show(st, &c)
			result = UI_CALENDAR_MOVED
		i = 0
		while (i < ctx.char_count):
			if (ctx.chars[i] == 13):
				ui_date_copy(picked, &c)
				result = UI_CALENDAR_COMMIT
			else if (ctx.chars[i] == 27): ctx.focus = 0
			i = i + 1

	# Header: arrows either side of "Month YYYY".
	float32 chev = 12.0
	ui_rect pc = ui_rect_new(prev.x + (s - chev) * 0.5, prev.y + (s - chev) * 0.5, chev, chev)
	ui_rect nc = ui_rect_new(next.x + (s - chev) * 0.5, next.y + (s - chev) * 0.5, chev, chev)
	if (ctx.hot == prev_id):
		ui_draw_rrect(ctx.rndr, ui_rect_inset(prev, 2.0), s * 0.5, ctx.theme.widget_hot)
	if (ctx.hot == next_id):
		ui_draw_rrect(ctx.rndr, ui_rect_inset(next, 2.0), s * 0.5, ctx.theme.widget_hot)
	ui_render_mask(ctx.rndr, pc, ui_mask_chevron_right, 1, 0, ui_text_color(ctx))
	ui_render_mask(ctx.rndr, nc, ui_mask_chevron_right, 0, 0, ui_text_color(ctx))
	char[32] title
	char* name = time_month_name(st.month)
	int n = 0
	while (name[n] != 0):
		title[n] = name[n]
		n = n + 1
	title[n] = ' '
	time_write_4_digits(&title[n + 1], st.year)
	title[n + 5] = 0
	ui_draw_text_centered(ctx.rndr, ui_rect_new(r.x + s, r.y, r.w - s * 2.0, s), &title[0], scale, ui_text_color(ctx))

	# Weekday row.
	float32 wr_h = ui_calendar_weekday_row_h(ctx)
	for col in range(7):
		ui_rect wc = ui_rect_new(r.x + s * cast(float32, col), r.y + s, s, wr_h)
		char* wname = time_weekday_name((col + st.first_weekday) % 7)
		char[3] wd
		wd[0] = wname[0]
		wd[1] = wname[1]
		wd[2] = 0
		ui_draw_text_centered(ctx.rndr, wc, &wd[0], scale, ctx.theme.text_muted)

	# Days.
	int have_range = 0
	int lo = 0
	int hi = 0
	if (ui_date_is_set(range_a) && ui_date_is_set(range_b)):
		have_range = 1
		lo = ui_date_days(range_a)
		hi = ui_date_days(range_b)
		if (hi < lo):
			int t = lo
			lo = hi
			hi = t
	int sel = -1
	if (ui_date_is_set(selected)): sel = ui_date_days(selected)
	int now = -1
	int have_today = ui_date_is_set(today)
	if (have_today): now = ui_date_days(today)
	int cur = -1
	if ((cursor != 0) && (ctx.focus == grid_id)):
		if (ui_date_is_set(cursor)): cur = ui_date_days(cursor)
	int hover = -1
	if ((ctx.hot == grid_id) && (ctx.disabled == 0)):
		hover = ui_calendar_cell_at(ctx, r, ctx.input.mouse_x, ctx.input.mouse_y)

	ui_date d
	char[4] num
	int cell = 0
	while (cell < ui_calendar_cells):
		ui_calendar_cell_date(st, cell, &d)
		int days = ui_date_days(&d)
		ui_rect cr = ui_calendar_cell_rect(ctx, r, cell)
		ui_rect dot = ui_rect_inset(cr, 2.0)
		int in_month = 0
		if (d.month == st.month): in_month = 1
		ui_color ink = ctx.theme.text_muted
		if (in_month): ink = ui_text_color(ctx)
		if (have_range && (days >= lo) && (days <= hi)):
			# A band through the range, its ends rounded off by the
			# endpoint discs drawn over it.
			ui_render_rect(ctx.rndr, ui_rect_new(cr.x, dot.y, cr.w, dot.h), ctx.theme.widget_active)
		if ((have_range && ((days == lo) || (days == hi))) || (days == sel)):
			ui_draw_rrect(ctx.rndr, dot, dot.h * 0.5, ctx.theme.accent)
			ink = ctx.theme.on_accent
		else if (cell == hover): ui_draw_rrect(ctx.rndr, dot, dot.h * 0.5, ctx.theme.widget_hot)
		if (have_today && (days == now)): ui_draw_ring(ctx.rndr, dot, ctx.theme.accent)
		if (days == cur): ui_draw_ring(ctx.rndr, cr, ctx.theme.focus)
		if (d.day >= 10):
			num[0] = '0' + d.day / 10
			num[1] = '0' + d.day % 10
			num[2] = 0
		else:
			num[0] = '0' + d.day
			num[1] = 0
		ui_draw_text_centered(ctx.rndr, cr, &num[0], scale, ink)
		cell = cell + 1
	return result


# A month calendar placed in the layout. Clicking a day (or moving to
# one with the keyboard while focused) selects it; returns 1 on the
# frame *selected changes. today (may be 0) is ringed.
int ui_calendar(ui_context* ctx, ui_calendar_state* st, ui_date* selected, ui_date* today):
	int base = ctx.next_id
	ctx.next_id = ctx.next_id + ui_calendar_ids
	ui_rect r = ui_layout_next(ctx, ui_calendar_width(ctx), ui_calendar_height(ctx))
	ui_date picked
	ui_date_clear(&picked)
	int what = ui_calendar_grid(ctx, base, r, st, selected, selected, 0, 0, today, &picked)
	if ((what == UI_CALENDAR_CLICKED) || (what == UI_CALENDAR_MOVED)):
		if (ui_date_equal(&picked, selected) == 0):
			ui_date_copy(selected, &picked)
			return 1
	return 0
