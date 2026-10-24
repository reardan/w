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
	for i in range(col_count):
		float32 cx = header.x + ui_table_col_x(st, i)
		float32 cw = cast(float32, col_widths[i])
		ui_clip_push(ctx.rndr, ui_rect_new(cx, header.y, cw, row_h))
		ui_draw_text(ctx.rndr, cx + pad, header.y + (row_h - cast(float32, ui_text_height(scale))) * 0.5, headers[i], scale, ctx.theme.text_muted)
		ui_clip_pop(ctx.rndr)
	if (ctx.access_parent == id):
		int header_row = ui_access_aux_id(ctx)
		if (ui_access_widget(ctx, header_row, UI_ACCESS_ROW, header, c"") != 0):
			ctx.access_parent = header_row
			for i in range(col_count):
				ui_access_widget(ctx, ui_access_aux_id(ctx), UI_ACCESS_CELL, ui_rect_new(header.x + ui_table_col_x(st, i), header.y, cast(float32, col_widths[i]), row_h), headers[i])
			ctx.access_parent = id
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
# background and handling a click on it.
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
	# measured.
	float32 top = row_h * cast(float32, row_index)
	if (top + row_h <= st.scroll.offset_y): return 0
	if (top >= st.scroll.offset_y + st.scroll.view_h): return 0

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
		if (st.selected == row_index): n.states = n.states | UI_ACCESS_SELECTED
	if (st.selected == row_index): ui_render_rect(ctx.rndr, row, ctx.theme.widget_active)
	else if (ctx.hot == id): ui_render_rect(ctx.rndr, row, ctx.theme.widget_hot)
	else if ((row_index & 1) == 1):
		# Zebra striping: every other row gets the tonal fill.
		ui_render_rect(ctx.rndr, row, ctx.theme.widget)
	return 1


# One cell of the current row, in the next column. Cells past the
# declared column count are ignored rather than drawing off the edge.
void ui_table_cell(ui_context* ctx, ui_table_state* st, char* text):
	int col = st.cell_index
	st.cell_index = st.cell_index + 1
	if (col >= st.col_count): return
	float32 cx = st.row_rect.x + ui_table_col_x(st, col)
	float32 cw = cast(float32, st.col_widths[col])
	int scale = ctx.theme.text_scale
	if (st.access_row != 0):
		int saved = ctx.access_parent
		ctx.access_parent = st.access_row
		ui_access_widget(ctx, ui_access_aux_id(ctx), UI_ACCESS_CELL, ui_rect_new(cx, st.row_rect.y, cw, st.row_rect.h), text)
		ctx.access_parent = saved
	# Clipped to its column, so a long value cannot spill into the next
	# one.
	ui_clip_push(ctx.rndr, ui_rect_new(cx, st.row_rect.y, cw, st.row_rect.h))
	ui_draw_text(ctx.rndr, cx + cast(float32, ctx.theme.pad), st.row_rect.y + (st.row_rect.h - cast(float32, ui_text_height(scale))) * 0.5, text, scale, ui_text_color(ctx))
	ui_clip_pop(ctx.rndr)


# Leave the body. Returns the selected row on the frame the selection
# changed, -1 otherwise.
int ui_table_end(ui_context* ctx, ui_table_state* st):
	ui_scroll_end(ctx, &st.scroll)
	ctx.access_parent = st.access_saved_parent
	if (st.changed): return st.selected
	return 0 - 1
