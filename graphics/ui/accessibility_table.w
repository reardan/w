/*
graphics.ui.accessibility_table: the table and selection structure every
platform bridge reads from a semantic snapshot (graphics.ui.accessibility),
so AT-SPI and UI Automation (and MSAA) describe the same rows, columns,
headers and selections.

Tables: a TABLE's ROW children hold CELL children. A row with the
UI_ACCESS_HEADER state is the column-header row (the first such row);
without one, the first row is the column-header row when it offers no
action and is not selected while a later row does or is (the shape
graphics/ui/widgets/table.w publishes). Table row indices count data
rows only. A data-row CELL with UI_ACCESS_HEADER is a row header.

Cells may span rows and columns (row_span, col_span; #863). They are
laid out as HTML lays out a table: each cell takes the first column of
its row not covered by a cell spanning down from a row above, and
covers row_span rows by col_span columns from there. A table without
spans keeps the plain rule: a cell's column is its index among its
row's CELL children.

Selection: lists, tab lists and tables are selection containers over
their list item, tab and data row children. Selection is driven by
activation, as a click selects, unless the container is
UI_ACCESS_MULTISELECTABLE or its items offer UI_ACCESS_SELECT.
*/
import graphics.ui.accessibility


int ui_access_row_is_live(ui_access_node* row):
	return (row.actions != 0) || ((row.states & UI_ACCESS_SELECTED) != 0)


int ui_access_is_header_row(ui_access_node* row):
	if ((row == 0) || (row.role != UI_ACCESS_ROW) || (row.parent == 0) || (row.parent.role != UI_ACCESS_TABLE)): return 0
	# An explicit header row wins over the heuristic below.
	ui_access_node* c = row.parent.first_child
	while (c != 0):
		if ((c.role == UI_ACCESS_ROW) && ((c.states & UI_ACCESS_HEADER) != 0)): return c == row
		c = c.next_sibling
	c = row.parent.first_child
	while ((c != 0) && (c.role != UI_ACCESS_ROW)): c = c.next_sibling
	if ((c != row) || ui_access_row_is_live(row)): return 0
	c = row.next_sibling
	while (c != 0):
		if ((c.role == UI_ACCESS_ROW) && ui_access_row_is_live(c)): return 1
		c = c.next_sibling
	return 0


ui_access_node* ui_access_header_row(ui_access_node* table):
	ui_access_node* c = table.first_child
	while (c != 0):
		if (ui_access_is_header_row(c)): return c
		c = c.next_sibling
	return 0


int ui_access_is_data_row(ui_access_node* c):
	return (c != 0) && (c.role == UI_ACCESS_ROW) && (c.parent != 0) && (c.parent.role == UI_ACCESS_TABLE) && !ui_access_is_header_row(c)


# 1 for a cell of the column-header row.
int ui_access_is_header_cell(ui_access_node* n):
	return (n != 0) && (n.role == UI_ACCESS_CELL) && ui_access_is_header_row(n.parent)


int ui_access_table_rows(ui_access_node* table):
	int count = 0
	ui_access_node* c = table.first_child
	while (c != 0):
		if (ui_access_is_data_row(c)): count = count + 1
		c = c.next_sibling
	return count


ui_access_node* ui_access_table_row(ui_access_node* table, int index):
	if (index < 0): return 0
	int k = 0
	ui_access_node* c = table.first_child
	while (c != 0):
		if (ui_access_is_data_row(c)):
			if (k == index): return c
			k = k + 1
		c = c.next_sibling
	return 0


int ui_access_row_cells(ui_access_node* row):
	int count = 0
	ui_access_node* c = row.first_child
	while (c != 0):
		if (c.role == UI_ACCESS_CELL): count = count + 1
		c = c.next_sibling
	return count


ui_access_node* ui_access_row_cell(ui_access_node* row, int col):
	if ((row == 0) || (col < 0)): return 0
	int k = 0
	ui_access_node* c = row.first_child
	while (c != 0):
		if (c.role == UI_ACCESS_CELL):
			if (k == col): return c
			k = k + 1
		c = c.next_sibling
	return 0


int ui_access_span(int v):
	if (v < 1): return 1
	return v


int ui_access_cell_spans_any(ui_access_node* table):
	ui_access_node* r = table.first_child
	while (r != 0):
		if (r.role == UI_ACCESS_ROW):
			ui_access_node* c = r.first_child
			while (c != 0):
				if ((c.role == UI_ACCESS_CELL) && ((c.row_span > 1) || (c.col_span > 1))): return 1
				c = c.next_sibling
		r = r.next_sibling
	return 0


# Walks a table's data cells in layout order: ui_access_grid_begin,
# then ui_access_grid_next until it returns 0. Each step leaves the
# cell, its row node and its slot (row, col, row_span, col_span; row
# spans are clipped to the table's data rows).
struct ui_access_grid:
	ui_access_node* table
	ui_access_node* row_node
	ui_access_node* cell
	int row
	int col
	int row_span
	int col_span
	int rows
	list[int] busy              # per column: the first data row not covered


void ui_access_grid_begin(ui_access_grid* g, ui_access_node* table):
	g.table = table
	g.row_node = 0
	g.cell = 0
	g.row = 0 - 1
	g.rows = ui_access_table_rows(table)
	g.busy = new list[int]


void ui_access_grid_end(ui_access_grid* g):
	list_free[int](g.busy)
	g.busy = 0


int ui_access_grid_next(ui_access_grid* g):
	ui_access_node* c = 0
	if (g.cell != 0): c = g.cell.next_sibling
	while (1):
		while ((c != 0) && (c.role != UI_ACCESS_CELL)): c = c.next_sibling
		if (c != 0): break
		# The next data row.
		ui_access_node* r = g.table.first_child
		if (g.row_node != 0): r = g.row_node.next_sibling
		while ((r != 0) && !ui_access_is_data_row(r)): r = r.next_sibling
		if (r == 0):
			ui_access_grid_end(g)
			return 0
		g.row_node = r
		g.row = g.row + 1
		g.col = 0
		g.col_span = 0
		c = r.first_child
	int at = 0
	if ((g.cell != 0) && (g.cell.parent == g.row_node)): at = g.col + g.col_span
	while ((at < g.busy.length) && (g.busy[at] > g.row)): at = at + 1
	g.cell = c
	g.col = at
	g.col_span = ui_access_span(c.col_span)
	g.row_span = ui_access_span(c.row_span)
	if (g.row + g.row_span > g.rows): g.row_span = g.rows - g.row
	while (g.busy.length < at + g.col_span): g.busy.push(0)
	for k in range(at, at + g.col_span): g.busy[k] = g.row + g.row_span
	return 1


# The header row's cells by columns: the column of header cell n and its
# span (col_span only; the header row lays out on its own).
int ui_access_header_cell_column(ui_access_node* n, int* col, int* span):
	if (!ui_access_is_header_cell(n)): return 0
	int k = 0
	ui_access_node* c = n.parent.first_child
	while ((c != 0) && (c != n)):
		if (c.role == UI_ACCESS_CELL): k = k + ui_access_span(c.col_span)
		c = c.next_sibling
	col[0] = k
	span[0] = ui_access_span(n.col_span)
	return 1


int ui_access_table_columns(ui_access_node* table):
	int most = 0
	ui_access_node* c = table.first_child
	while (c != 0):
		if (c.role == UI_ACCESS_ROW):
			int width = 0
			ui_access_node* k = c.first_child
			while (k != 0):
				if (k.role == UI_ACCESS_CELL): width = width + ui_access_span(k.col_span)
				k = k.next_sibling
			if (width > most): most = width
		c = c.next_sibling
	if (ui_access_cell_spans_any(table)):
		ui_access_grid g
		ui_access_grid_begin(&g, table)
		while (ui_access_grid_next(&g)):
			if (g.col + g.col_span > most): most = g.col + g.col_span
	return most


# A data cell's slot: its first row (among data rows) and column, and
# the rows and columns it spans; 0 when n is not a data cell.
int ui_access_cell_slot(ui_access_node* n, int* row, int* col, int* row_span, int* col_span):
	if ((n == 0) || (n.role != UI_ACCESS_CELL) || !ui_access_is_data_row(n.parent)): return 0
	ui_access_node* table = n.parent.parent
	if (ui_access_cell_spans_any(table)):
		ui_access_grid g
		ui_access_grid_begin(&g, table)
		while (ui_access_grid_next(&g)):
			if (g.cell == n):
				row[0] = g.row
				col[0] = g.col
				row_span[0] = g.row_span
				col_span[0] = g.col_span
				ui_access_grid_end(&g)
				return 1
		return 0
	int r = 0
	ui_access_node* c = table.first_child
	while ((c != 0) && (c != n.parent)):
		if (ui_access_is_data_row(c)): r = r + 1
		c = c.next_sibling
	int k = 0
	c = n.parent.first_child
	while ((c != 0) && (c != n)):
		if (c.role == UI_ACCESS_CELL): k = k + 1
		c = c.next_sibling
	row[0] = r
	col[0] = k
	row_span[0] = 1
	col_span[0] = 1
	return 1


# A data cell's row (among data rows) and column; 0 when n is not one.
int ui_access_cell_position(ui_access_node* n, int* row, int* col):
	int rs = 0
	int cs = 0
	return ui_access_cell_slot(n, row, col, &rs, &cs)


# The data cell covering slot (row, col), or 0.
ui_access_node* ui_access_table_cell_at(ui_access_node* table, int row, int col):
	if ((table == 0) || (row < 0) || (col < 0)): return 0
	if (!ui_access_cell_spans_any(table)): return ui_access_row_cell(ui_access_table_row(table, row), col)
	ui_access_grid g
	ui_access_grid_begin(&g, table)
	while (ui_access_grid_next(&g)):
		if (g.row > row):
			ui_access_grid_end(&g)
			return 0
		if ((row < g.row + g.row_span) && (col >= g.col) && (col < g.col + g.col_span)):
			ui_access_node* found = g.cell
			ui_access_grid_end(&g)
			return found
	return 0


# 1 for a row header: a UI_ACCESS_HEADER cell of a data row.
int ui_access_is_row_header(ui_access_node* n):
	return (n != 0) && (n.role == UI_ACCESS_CELL) && ((n.states & UI_ACCESS_HEADER) != 0) && ui_access_is_data_row(n.parent)


# The column headers of a data cell: the header row's cells whose
# columns overlap the cell's. Returns how many there are and stores the
# index-th (0 when index is out of range) in *out.
int ui_access_column_headers_of(ui_access_node* cell, int index, ui_access_node** out):
	out[0] = 0
	int row = 0
	int col = 0
	int rs = 0
	int cs = 0
	if (!ui_access_cell_slot(cell, &row, &col, &rs, &cs)): return 0
	ui_access_node* header = ui_access_header_row(cell.parent.parent)
	if (header == 0): return 0
	int count = 0
	ui_access_node* c = header.first_child
	while (c != 0):
		int hc = 0
		int hs = 0
		if (ui_access_header_cell_column(c, &hc, &hs) && (hc < col + cs) && (col < hc + hs)):
			if (count == index): out[0] = c
			count = count + 1
		c = c.next_sibling
	return count


# The row headers of a data cell: the row-header cells covering one of
# its rows, before its column (not the cell itself). Returns how many
# there are and stores the index-th in *out.
int ui_access_row_headers_of(ui_access_node* cell, int index, ui_access_node** out):
	out[0] = 0
	int row = 0
	int col = 0
	int rs = 0
	int cs = 0
	if (!ui_access_cell_slot(cell, &row, &col, &rs, &cs)): return 0
	int count = 0
	ui_access_grid g
	ui_access_grid_begin(&g, cell.parent.parent)
	while (ui_access_grid_next(&g)):
		if ((g.cell != cell) && ui_access_is_row_header(g.cell) && (g.row < row + rs) && (row < g.row + g.row_span) && (g.col < col)):
			if (count == index): out[0] = g.cell
			count = count + 1
	return count


# Every row header of a table, in layout order: the count, and the
# index-th in *out.
int ui_access_table_row_headers(ui_access_node* table, int index, ui_access_node** out):
	out[0] = 0
	int count = 0
	ui_access_grid g
	ui_access_grid_begin(&g, table)
	while (ui_access_grid_next(&g)):
		if (ui_access_is_row_header(g.cell)):
			if (count == index): out[0] = g.cell
			count = count + 1
	return count


int ui_access_is_multiselectable(ui_access_node* n):
	return (n != 0) && ((n.states & UI_ACCESS_MULTISELECTABLE) != 0)


int ui_access_is_selection_container(ui_access_node* n):
	return (n != 0) && ((n.role == UI_ACCESS_LIST) || (n.role == UI_ACCESS_TAB_LIST) || (n.role == UI_ACCESS_TABLE))


int ui_access_selectable_child(ui_access_node* c):
	if (c == 0): return 0
	if ((c.role == UI_ACCESS_TAB) || (c.role == UI_ACCESS_LIST_ITEM)): return 1
	return ui_access_is_data_row(c)


int ui_access_selected_count(ui_access_node* n):
	int count = 0
	ui_access_node* c = n.first_child
	while (c != 0):
		if (ui_access_selectable_child(c) && ((c.states & UI_ACCESS_SELECTED) != 0)): count = count + 1
		c = c.next_sibling
	return count


ui_access_node* ui_access_selected_at(ui_access_node* n, int index):
	if (index < 0): return 0
	int k = 0
	ui_access_node* c = n.first_child
	while (c != 0):
		if (ui_access_selectable_child(c) && ((c.states & UI_ACCESS_SELECTED) != 0)):
			if (k == index): return c
			k = k + 1
		c = c.next_sibling
	return 0


int ui_access_selection_same(ui_access_node* a, ui_access_node* b):
	int count = ui_access_selected_count(a)
	if (count != ui_access_selected_count(b)): return 0
	for i in range(count):
		if (ui_access_selected_at(a, i).id != ui_access_selected_at(b, i).id): return 0
	return 1
