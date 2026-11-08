/*
graphics.ui.widgets.table: a scrollable row/column list with a sticky
header (docs/projects/ui_widgets.md §5).

	ui_table_begin(ctx, area, headers, widths, 3, &st)
	int row = 0
	while (row < row_count):
		if (ui_table_row(ctx, &st, row)):
			ui_table_cell(ctx, &st, name_of(row))
			ui_table_cell(ctx, &st, size_of(row))
		row = row + 1
	int picked = ui_table_end(ctx, &st)

ui_table_row returns 0 for rows outside the viewport so the caller
skips their cells. That is the point: a ten-thousand-row table costs
the vertices of the dozen rows on screen, and the caller never
computes what it does not draw. The clip would have hidden them
anyway, but it would not have saved the work.

The header is drawn outside the body's clip, so it stays put while the
rows scroll under it.

Grids (#913): set st.row_header_col to make that column's cells row
headers, st.header_spans to let a header cover several columns, and
issue a cell with ui_table_cell_span to cover several rows and columns:

	st.row_header_col = 0
	ui_table_begin(ctx, area, headers, widths, 3, &st)
	if (ui_table_row(ctx, &st, 0)):
		ui_table_cell_span(ctx, &st, c"Fruit", 2, 1)   # two rows
		ui_table_cell(ctx, &st, c"Apple")
		ui_table_cell(ctx, &st, c"Red")
	if (ui_table_row(ctx, &st, 1)):
		ui_table_cell_span(ctx, &st, c"Cherry", 1, 2)  # two columns

Cells are placed as HTML places them: each takes the next column of
its row that no cell from a row above still covers. A row a span from
a row above reaches is issued even when it is scrolled just out of
view, so the spanning cell's top row (the one that issues it) is always
there to draw it.

Semantics: a TABLE whose header row is a ROW with UI_ACCESS_HEADER, data
rows that select on activation, and CELLs carrying row_span/col_span;
row-header cells carry UI_ACCESS_HEADER (graphics.ui.accessibility_table
turns that into AT-SPI and UI Automation row/column headers and spans).
While the table holds focus, the snapshot's focused node is the
selected row.
*/
import lib.lib
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.scroll


struct ui_table_state:
	ui_scroll_state scroll
	int32 selected         # selected row, -1 for none
	int32 row_height       # 0 = the theme's widget height
	# Set by ui_table_begin, read by row/cell/end.
	int32* col_widths
	int32 col_count
	float32 body_x
	float32 body_y         # content-space origin of row 0
	float32 body_w
	# The row being issued: its rect and how many cells it has taken.
	ui_rect row_rect
	int32 cell_index
	int32 changed          # 1 when this frame's selection differs
	# Keyboard and semantics: the table is one focus stop whose Up/Down
	# move the selection; rows seen last frame bound the cursor.
	int32 table_id
	int32 row_count
	int32 rows_seen
	int32 access_saved_parent
	int32 access_row       # semantic node of the row being issued
	# Grid structure: the row-header column (-1 for none), optional
	# per-column header spans, and per column the rows (counting the
	# one being issued) a cell spanning down from an issued row covers;
	# only the first 32 columns can be covered.
	int32 row_header_col
	int32* header_spans
	int32[32] covered
	int32 last_row
	int32 max_row_span     # the tallest span seen, for the issue window


void ui_table_init(ui_table_state* st):
	ui_scroll_init(&st.scroll)
	st.selected = 0 - 1
	st.row_height = 0
	st.col_widths = 0
	st.col_count = 0
	st.body_x = 0.0
	st.body_y = 0.0
	st.body_w = 0.0
	st.cell_index = 0
	st.changed = 0
	st.table_id = 0
	st.row_count = 0
	st.rows_seen = 0
	st.access_saved_parent = 0
	st.access_row = 0
	st.row_header_col = 0 - 1
	st.header_spans = 0
	for i in range(32): st.covered[i] = 0
	st.last_row = 0 - 2
	st.max_row_span = 1


int ui_table_row_height(ui_context* ctx, ui_table_state* st):
	if (st.row_height > 0): return st.row_height
	return ctx.theme.widget_height


# Left edge of column i, relative to the table's left edge.
float32 ui_table_col_x(ui_table_state* st, int col):
	float32 x = 0.0
	int i = 0
	while ((i < col) && (i < st.col_count)):
		x = x + cast(float32, st.col_widths[i])
		i = i + 1
	return x


# Columns header i covers (1 without header_spans).
int ui_table_header_span(ui_table_state* st, int i):
	int span = 1
	if (st.header_spans != 0): span = st.header_spans[i]
	if (span < 1): span = 1
	if (i + span > st.col_count): span = st.col_count - i
	return span


# 1 when column col of the row being issued is covered from above.
int ui_table_covered(ui_table_state* st, int col):
	return (col >= 0) && (col < 32) && (st.covered[col] > 0)


# Fill a row's background, leaving out the columns a cell from a row
# above covers, so the fill does not paint over that cell.
void ui_table_fill(ui_context* ctx, ui_table_state* st, ui_rect row, ui_color c):
	int col = 0
	while (col < st.col_count):
		if (ui_table_covered(st, col)):
			col = col + 1
			continue
		int end = col
		while ((end < st.col_count) && (ui_table_covered(st, end) == 0)): end = end + 1
		float32 x0 = ui_table_col_x(st, col)
		float32 x1 = ui_table_col_x(st, end)
		if (end == st.col_count): x1 = row.w
		ui_render_rect(ctx.rndr, ui_rect_new(row.x + x0, row.y, x1 - x0, row.h), c)
		col = end


# Draw the sticky header and enter the scrollable body.
void ui_table_begin(ui_context* ctx, ui_rect area, char** headers, int32* col_widths, int col_count, ui_table_state* st):
	st.col_widths = col_widths
	st.col_count = col_count
	st.changed = 0
	st.cell_index = 0
	int scale = ctx.theme.text_scale
	float32 row_h = cast(float32, ui_table_row_height(ctx, st))
	float32 pad = cast(float32, ctx.theme.pad)
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	st.table_id = id
	st.row_count = st.rows_seen
	st.rows_seen = 0
	st.access_row = 0
	st.last_row = 0 - 2
	st.access_saved_parent = ctx.access_parent
	if (ui_access_widget(ctx, id, UI_ACCESS_TABLE, area, 0) != 0): ctx.access_parent = id
	if (ui_focus_stop(ctx, id, area, 0) && (ctx.disabled == 0) && (ui_scope_blocked(ctx) == 0) && (st.row_count > 0)):
		int pick = st.selected
		for k in range(ctx.nav_count):
			int nav = ctx.navs[k]
			if (nav == GFX_NAV_DOWN):
				if (pick + 1 < st.row_count): pick = pick + 1
			else if (nav == GFX_NAV_UP):
				if (pick > 0): pick = pick - 1
				else: pick = 0
			else if (nav == GFX_NAV_HOME): pick = 0
			else if (nav == GFX_NAV_END): pick = st.row_count - 1
		if (pick != st.selected):
			st.selected = pick
			st.changed = 1
			ui_scroll_reveal(&st.scroll, row_h * cast(float32, pick), row_h)

	# Header: outside the body's clip, so it does not scroll.
	ui_rect header = ui_rect_new(area.x, area.y, area.w, row_h)
	ui_draw_rrect(ctx.rndr, header, cast(float32, ctx.theme.radius_small), ctx.theme.widget)
	int header_row = 0
	if (ctx.access_parent == id):
		header_row = ui_access_aux_id(ctx)
		ui_access_node* hn = ui_access_widget(ctx, header_row, UI_ACCESS_ROW, header, c"")
		if (hn == 0): header_row = 0
		else: hn.states = hn.states | UI_ACCESS_HEADER
	int i = 0
	while (i < col_count):
		int span = ui_table_header_span(st, i)
		float32 cx = header.x + ui_table_col_x(st, i)
		float32 cw = ui_table_col_x(st, i + span) - ui_table_col_x(st, i)
		ui_clip_push(ctx.rndr, ui_rect_new(cx, header.y, cw, row_h))
		ui_draw_text(ctx.rndr, cx + pad, header.y + (row_h - cast(float32, ui_text_height(scale))) * 0.5, headers[i], scale, ctx.theme.text_muted)
		ui_clip_pop(ctx.rndr)
		if (header_row != 0):
			ctx.access_parent = header_row
			ui_access_node* cell = ui_access_widget(ctx, ui_access_aux_id(ctx), UI_ACCESS_CELL, ui_rect_new(cx, header.y, cw, row_h), headers[i])
			if ((cell != 0) && (span > 1)): cell.col_span = span
			ctx.access_parent = id
		i = i + span
	ui_render_rect(ctx.rndr, ui_rect_new(area.x, area.y + row_h, area.w, 1.0), ctx.theme.border)

	ui_rect body = ui_rect_new(area.x, area.y + row_h + 1.0, area.w, area.h - row_h - 1.0)
	ui_scroll_begin(ctx, body, &st.scroll)
	# Content space: row 0 sits at the shifted region's origin.
	ui_layout* lo = ui_layout_top(ctx)
	st.body_x = lo.bounds.x
	st.body_y = lo.bounds.y
	st.body_w = body.w


# Start a row. Returns 0 when the row is outside the viewport, so the
# caller can skip issuing its cells; returns 1 after drawing the row's
# background and handling a click on it. Rows are issued in increasing
# order.
int ui_table_row(ui_context* ctx, ui_table_state* st, int row_index):
	float32 row_h = cast(float32, ui_table_row_height(ctx, st))
	ui_rect row = ui_rect_new(st.body_x, st.body_y + row_h * cast(float32, row_index), st.body_w, row_h)
	# Claimed whether or not it is drawn: the scroll region has to know
	# how tall the whole table is, not just its visible part.
	ui_region_claim(ctx, row)
	st.row_rect = row
	st.cell_index = 0
	st.access_row = 0
	if (row_index + 1 > st.rows_seen): st.rows_seen = row_index + 1

	# Visibility in content space, against the viewport the last frame
	# measured. A row whose spanning cell could reach the viewport
	# counts as visible.
	float32 top = row_h * cast(float32, row_index)
	if (top + row_h * cast(float32, st.max_row_span) <= st.scroll.offset_y): return 0
	if (top >= st.scroll.offset_y + st.scroll.view_h): return 0
	# Row spans carry down only from the row just issued.
	for c in range(32):
		if (row_index != st.last_row + 1): st.covered[c] = 0
		else if (st.covered[c] > 0): st.covered[c] = st.covered[c] - 1
	st.last_row = row_index

	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	int row_node = ui_access_aux_id(ctx)
	int clicked = ui_click_behavior(ctx, id, row)
	if ((ctx.disabled == 0) && (ui_scope_blocked(ctx) == 0) && ui_access_take_activation(ctx, row_node)):
		clicked = 1
	if (clicked):
		if (st.selected != row_index):
			st.selected = row_index
			st.changed = 1
	ui_access_node* n = ui_access_widget(ctx, row_node, UI_ACCESS_ROW, row, c"")
	if (n != 0):
		st.access_row = row_node
		n.actions = UI_ACCESS_ACTIVATE
		if (st.selected == row_index):
			n.states = n.states | UI_ACCESS_SELECTED
			if (ctx.focus == st.table_id):
				ctx.access_focus_owner = st.table_id
				ctx.access_focus_child = row_node
	if (st.selected == row_index):
		ui_table_fill(ctx, st, row, ctx.theme.widget_active)
		ui_selection_marker(ctx, row)
	else if (ctx.hot == id): ui_table_fill(ctx, st, row, ctx.theme.widget_hot)
	else if ((row_index & 1) == 1):
		# Zebra striping: every other row gets the tonal fill.
		ui_table_fill(ctx, st, row, ctx.theme.widget)
	return 1


# One cell of the current row covering row_span rows and col_span
# columns from the next free column. Cells past the declared column
# count are ignored rather than drawing off the edge; spans are clipped
# to the table's columns.
void ui_table_cell_span(ui_context* ctx, ui_table_state* st, char* text, int row_span, int col_span):
	int col = st.cell_index
	while ((col < st.col_count) && ui_table_covered(st, col)): col = col + 1
	if (col >= st.col_count):
		st.cell_index = col
		return
	if (row_span < 1): row_span = 1
	if (col_span < 1): col_span = 1
	if (col + col_span > st.col_count): col_span = st.col_count - col
	st.cell_index = col + col_span
	if (row_span > st.max_row_span): st.max_row_span = row_span
	if (row_span > 1):
		for c in range(col, col + col_span):
			# Counted from this row: the next row start takes one off.
			if ((c < 32) && (st.covered[c] < row_span)): st.covered[c] = row_span
	float32 cx = st.row_rect.x + ui_table_col_x(st, col)
	float32 cw = ui_table_col_x(st, col + col_span) - ui_table_col_x(st, col)
	float32 ch = st.row_rect.h * cast(float32, row_span)
	ui_rect cell = ui_rect_new(cx, st.row_rect.y, cw, ch)
	int scale = ctx.theme.text_scale
	int is_header = col == st.row_header_col
	if (st.access_row != 0):
		int saved = ctx.access_parent
		ctx.access_parent = st.access_row
		ui_access_node* n = ui_access_widget(ctx, ui_access_aux_id(ctx), UI_ACCESS_CELL, cell, text)
		if (n != 0):
			if (row_span > 1): n.row_span = row_span
			if (col_span > 1): n.col_span = col_span
			if (is_header): n.states = n.states | UI_ACCESS_HEADER
		ctx.access_parent = saved
	# A row header is set off by a rule on its trailing edge.
	if (is_header): ui_render_rect(ctx.rndr, ui_rect_new(cx + cw - 1.0, cell.y, 1.0, ch), ctx.theme.border)
	# Clipped to its columns, so a long value cannot spill into the next
	# one.
	ui_clip_push(ctx.rndr, cell)
	ui_draw_text(ctx.rndr, cx + cast(float32, ctx.theme.pad), cell.y + (ch - cast(float32, ui_text_height(scale))) * 0.5, text, scale, ui_text_color(ctx))
	ui_clip_pop(ctx.rndr)


# One cell of the current row, in the next free column.
void ui_table_cell(ui_context* ctx, ui_table_state* st, char* text):
	ui_table_cell_span(ctx, st, text, 1, 1)


# Leave the body. Returns the selected row on the frame the selection
# changed, -1 otherwise.
int ui_table_end(ui_context* ctx, ui_table_state* st):
	ui_scroll_end(ctx, &st.scroll)
	ctx.access_parent = st.access_saved_parent
	if (st.changed): return st.selected
	return 0 - 1
