/*
graphics.ui.accessibility_table: the table and selection structure every
platform bridge reads from a semantic snapshot (graphics.ui.accessibility),
so AT-SPI and UI Automation (and MSAA) describe the same rows, columns,
headers and selections.

Tables: a TABLE's ROW children hold CELL children. The first row is the
column-header row when it offers no action and is not selected while a
later row does or is (the shape graphics/ui/widgets/table.w publishes);
table row indices count data rows only, column indices count a row's
CELL children.

Selection: lists, tab lists and tables are selection containers over
their list item, tab and data row children. Selection is single and
driven by activation, as a click selects.
*/
import graphics.ui.accessibility


int ui_access_row_is_live(ui_access_node* row):
	return (row.actions != 0) || ((row.states & UI_ACCESS_SELECTED) != 0)


int ui_access_is_header_row(ui_access_node* row):
	if ((row == 0) || (row.role != UI_ACCESS_ROW) || (row.parent == 0) || (row.parent.role != UI_ACCESS_TABLE)): return 0
	ui_access_node* c = row.parent.first_child
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


int ui_access_table_columns(ui_access_node* table):
	int most = 0
	ui_access_node* c = table.first_child
	while (c != 0):
		if ((c.role == UI_ACCESS_ROW) && (ui_access_row_cells(c) > most)): most = ui_access_row_cells(c)
		c = c.next_sibling
	return most


# A data cell's row (among data rows) and column; 0 when n is not one.
int ui_access_cell_position(ui_access_node* n, int* row, int* col):
	if ((n == 0) || (n.role != UI_ACCESS_CELL) || !ui_access_is_data_row(n.parent)): return 0
	ui_access_node* table = n.parent.parent
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
	return 1


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
