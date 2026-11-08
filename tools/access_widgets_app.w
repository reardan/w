# wbuild: binary=access_widgets_app arch=x64 tag=tests
# wbuild: target=access_atspi_widgets_test dep=access_widgets_app
# wbuild: step="env APP=bin/access_widgets_app CHECK=tools/access_atspi_widgets_check.py sh tools/mermaid_editor_atspi_test.sh"
# The #913 widget fixture for real AT-SPI clients
# (tools/access_atspi_widgets_check.py, run by access_atspi_widgets_test).
# Unlike tools/access_depth_app.w, which builds its snapshot by hand,
# this one runs the widgets themselves, headless: every frame issues the
# multi-selection list box (graphics.ui.widgets.listbox) and a grid table
# (graphics.ui.widgets.table with a spanning header, a row-header column
# and spanning cells) into a captured snapshot, publishes it when it
# changed and dispatches the client's requests, which the widgets apply
# on the next frame. The list's flags are printed on stdout whenever
# they change ("picked 0100").
import lib.lib
import lib.time
import graphics.ui.accessibility
import graphics.ui.accessibility_atspi
import graphics.ui.testing


struct aw_model:
	ui_listbox_state list
	char[4] picked
	ui_table_state table


void say(char* s):
	write(1, s, strlen(s))


void aw_frame(ui_context* ctx, aw_model* m):
	char*[4] names
	names[0] = c"Apple"
	names[1] = c"Cherry"
	names[2] = c"Kiwi"
	names[3] = c"Pecan"
	char*[3] headers
	headers[0] = c"Kind"
	headers[1] = c"Item"
	headers[2] = c""
	int32[3] spans
	spans[0] = 1
	spans[1] = 2
	spans[2] = 1
	int32[3] widths
	widths[0] = 80
	widths[1] = 80
	widths[2] = 60
	ui_begin(ctx, 600, 400)
	ui_listbox_begin(ctx, ui_rect_new(8.0, 8.0, 160.0, 140.0), &m.list, c"Fruit", &m.picked[0], 4)
	for i in range(4): ui_listbox_item(ctx, &m.list, i, names[i])
	if (ui_listbox_end(ctx, &m.list)):
		say(c"picked ")
		for i in range(4):
			if (m.picked[i]): say(c"1")
			else: say(c"0")
		say(c"\n")
	m.table.row_header_col = 0
	m.table.header_spans = &spans[0]
	ui_table_begin(ctx, ui_rect_new(200.0, 8.0, 240.0, 200.0), &headers[0], &widths[0], 3, &m.table)
	if (ui_table_row(ctx, &m.table, 0)):
		ui_table_cell_span(ctx, &m.table, c"Fruit", 2, 1)
		ui_table_cell(ctx, &m.table, c"Apple")
		ui_table_cell(ctx, &m.table, c"Red")
	if (ui_table_row(ctx, &m.table, 1)):
		ui_table_cell_span(ctx, &m.table, c"Cherry", 1, 2)
	if (ui_table_row(ctx, &m.table, 2)):
		ui_table_cell(ctx, &m.table, c"Nut")
		ui_table_cell(ctx, &m.table, c"Pecan")
		ui_table_cell(ctx, &m.table, c"Brown")
	ui_table_end(ctx, &m.table)
	ui_end(ctx)


ui_access_tree* aw_capture(ui_context* ctx, aw_model* m):
	ui_access_tree* tree = ui_access_tree_new(128, 8192)
	ui_access_capture(ctx, tree)
	aw_frame(ctx, m)
	ui_access_capture(ctx, 0)
	ui_access_set_text(tree, ui_access_root_id, UI_ACCESS_NAME, c"Widgets", 7)
	return tree


int main():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	aw_model m
	ui_listbox_init(&m.list)
	for i in range(4): m.picked[i] = 0
	m.picked[1] = 1
	ui_table_init(&m.table)
	ui_atspi_bridge* b = ui_access_atspi_open(c"W widgets")
	if (b == 0):
		say(c"no accessibility bus\n")
		return 1
	ui_access_tree* published = aw_capture(ctx, &m)
	ui_access_atspi_publish(b, published)
	say(c"ready\n")
	for frame in range(120 * 50):
		if (ui_access_atspi_dispatch(b, published) < 0): break
		ui_access_tree* fresh = aw_capture(ctx, &m)
		if (ui_access_tree_same(fresh, published)): ui_access_tree_free(fresh)
		else:
			ui_access_atspi_publish(b, fresh)
			ui_access_tree_free(published)
			published = fresh
		sleep_ms(20)
	ui_access_atspi_close(b)
	ui_access_tree_free(published)
	ui_render_destroy(&fx.r)
	return 0
