# wbuild: binary=access_depth_app arch=x64 tag=tests
# wbuild: target=access_atspi_depth_test dep=access_depth_app
# wbuild: step="env APP=bin/access_depth_app CHECK=tools/access_atspi_depth_check.py sh tools/mermaid_editor_atspi_test.sh"
# The #863 accessibility depth fixture for real AT-SPI clients
# (tools/access_atspi_depth_check.py, run by access_atspi_depth_test):
# publishes a snapshot with a two-line editor (glyph boxes, text
# attributes, two selections), a multi-selection list and a table with
# an explicit header row, a row header spanning two rows and a cell
# spanning two columns, and (#911/#912) a slider labelled by a label
# and a four-line log that shows two lines and scrolls on SCROLL_TO,
# then applies the client's requests to its model and republishes, as
# an application would. Every request and, once a
# second, the number of calls answered over the peer-to-peer bus are
# printed on stdout ("request <id> <action> <payload>", "p2p <n>").
import lib.lib
import lib.time
import graphics.ui.accessibility
import graphics.ui.accessibility_atspi


struct depth_model:
	int[3] selected
	int[16] ranges              # editor selections: primary anchor, caret, then start/end pairs
	int range_count
	int changed
	float32 volume
	int top_line                # the log's first visible line


depth_model model


void say(char* s):
	write(1, s, strlen(s))


# A SET_VALUE payload ("7.5", "-2") as a number.
float32 depth_number(char* data, int length):
	float32 v = 0.0
	float32 scale = 0.0
	int negative = 0
	for i in range(length):
		if ((i == 0) && (data[i] == '-')): negative = 1
		else if (data[i] == '.'): scale = 1.0
		else if ((data[i] >= '0') && (data[i] <= '9')):
			if (scale > 0.0):
				scale = scale / 10.0
				v = v + scale * cast(float32, data[i] - '0')
			else: v = v * 10.0 + cast(float32, data[i] - '0')
	if negative: return 0.0 - v
	return v


int depth_action(void* context, int id, int action, char* data, int length):
	say(c"request ")
	char* n = itoa(id)
	say(n)
	free(n)
	say(c" ")
	n = itoa(action)
	say(n)
	free(n)
	say(c" ")
	write(1, data, length)
	say(c"\n")
	if ((action == UI_ACCESS_SELECT) && (id >= 4) && (id <= 6)):
		int mode = ui_access_select_mode(data, length)
		if (mode == UI_ACCESS_SELECT_ONLY):
			for k in range(3): model.selected[k] = 0
		model.selected[id - 4] = mode != UI_ACCESS_SELECT_REMOVE
		model.changed = 1
	if ((action == UI_ACCESS_SET_SELECTIONS) && (id == 2)):
		int pairs = ui_access_selections_parse(data, length, &model.ranges[0], 8)
		if (pairs > 8): pairs = 8
		model.range_count = pairs
		model.changed = 1
	if ((action == UI_ACCESS_SET_SELECTION) && (id == 2)):
		ui_access_selection_parse(data, length, &model.ranges[0], &model.ranges[1])
		model.range_count = 1
		model.changed = 1
	if ((action == UI_ACCESS_SET_VALUE) && (id == 41)):
		model.volume = depth_number(data, length)
		model.changed = 1
	if ((action == UI_ACCESS_SCROLL_TO) && (id == 42)):
		int start = 0
		int end = 0
		int align = 0
		if ui_access_scroll_parse(data, length, &start, &end, &align):
			int first = start / 3
			int last = first
			if (end > start): last = (end - 1) / 3
			# Two lines show: the top alignment puts the first line at
			# the top, the bottom one the last at the bottom, anywhere
			# moves the least.
			int top = model.top_line
			if (align == UI_ACCESS_SCROLL_TOP): top = first
			else if (align == UI_ACCESS_SCROLL_BOTTOM): top = last - 1
			else if (first < top): top = first
			else if (last > top + 1): top = last - 1
			if (top < 0): top = 0
			if (top > 2): top = 2
			model.top_line = top
			model.changed = 1
	return 1


ui_access_tree* depth_tree():
	ui_access_tree* tree = ui_access_tree_new(32, 512)
	ui_rect r = ui_rect_new(0.0, 0.0, 300.0, 300.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_set_text(tree, 1, UI_ACCESS_NAME, c"Depth", 5)
	ui_access_node* editor = ui_access_add(tree, 2, 1, UI_ACCESS_TEXTBOX, ui_rect_new(10.0, 10.0, 200.0, 40.0))
	editor.states = UI_ACCESS_FOCUSABLE
	editor.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_SET_SELECTION | UI_ACCESS_SET_SELECTIONS
	ui_access_set_text(tree, 2, UI_ACCESS_NAME, c"Notes", 5)
	ui_access_set_text(tree, 2, UI_ACCESS_VALUE, c"ab\ncd", 5)
	ui_rect[5] boxes
	boxes[0] = ui_rect_new(14.0, 12.0, 10.0, 16.0)
	boxes[1] = ui_rect_new(24.0, 12.0, 10.0, 16.0)
	boxes[2] = ui_rect_new(34.0, 12.0, 0.0, 16.0)
	boxes[3] = ui_rect_new(14.0, 30.0, 10.0, 16.0)
	boxes[4] = ui_rect_new(24.0, 30.0, 12.0, 16.0)
	ui_access_set_char_boxes(tree, 2, &boxes[0], 5)
	ui_access_text_attrs* base = ui_access_default_attrs(tree, 2)
	ui_access_attrs_set_family(base, c"Liberation Sans", 15)
	base.size = 12
	base.weight = 400
	base.fg = 0x102030
	base.bg = 0xffffff
	ui_access_text_attrs* bold = ui_access_add_attr_run(tree, 2, 3, 5)
	bold.weight = 700
	ui_access_set_selection(tree, 2, model.ranges[0], model.ranges[1])
	for k in range(1, model.range_count): ui_access_add_selection(tree, 2, model.ranges[k * 2], model.ranges[k * 2 + 1])
	ui_access_node* list = ui_access_add(tree, 3, 1, UI_ACCESS_LIST, ui_rect_new(10.0, 60.0, 100.0, 60.0))
	list.states = UI_ACCESS_MULTISELECTABLE
	ui_access_set_text(tree, 3, UI_ACCESS_NAME, c"Fruit", 5)
	for k in range(3):
		ui_access_node* item = ui_access_add(tree, 4 + k, 3, UI_ACCESS_LIST_ITEM, ui_rect_new(10.0, 60.0 + cast(float32, k) * 20.0, 100.0, 20.0))
		item.actions = UI_ACCESS_SELECT | UI_ACCESS_ACTIVATE
		if model.selected[k]: item.states = UI_ACCESS_SELECTED
	ui_access_set_text(tree, 4, UI_ACCESS_NAME, c"Apple", 5)
	ui_access_set_text(tree, 5, UI_ACCESS_NAME, c"Cherry", 6)
	ui_access_set_text(tree, 6, UI_ACCESS_NAME, c"Kiwi", 4)
	ui_access_add(tree, 10, 1, UI_ACCESS_TABLE, ui_rect_new(10.0, 130.0, 200.0, 80.0))
	ui_access_node* head = ui_access_add(tree, 11, 10, UI_ACCESS_ROW, r)
	head.states = UI_ACCESS_HEADER
	ui_access_add(tree, 12, 11, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, 12, UI_ACCESS_NAME, c"Kind", 4)
	ui_access_node* item_head = ui_access_add(tree, 13, 11, UI_ACCESS_CELL, r)
	item_head.col_span = 2
	ui_access_set_text(tree, 13, UI_ACCESS_NAME, c"Item", 4)
	ui_access_add(tree, 20, 10, UI_ACCESS_ROW, r)
	ui_access_node* fruit = ui_access_add(tree, 21, 20, UI_ACCESS_CELL, r)
	fruit.states = UI_ACCESS_HEADER
	fruit.row_span = 2
	ui_access_set_text(tree, 21, UI_ACCESS_NAME, c"Fruit", 5)
	ui_access_add(tree, 22, 20, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, 22, UI_ACCESS_NAME, c"Apple", 5)
	ui_access_add(tree, 23, 20, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, 23, UI_ACCESS_NAME, c"Red", 3)
	ui_access_add(tree, 30, 10, UI_ACCESS_ROW, r)
	ui_access_node* cherry = ui_access_add(tree, 31, 30, UI_ACCESS_CELL, r)
	cherry.col_span = 2
	ui_access_set_text(tree, 31, UI_ACCESS_NAME, c"Cherry", 6)
	ui_access_add(tree, 40, 1, UI_ACCESS_TEXT, ui_rect_new(220.0, 10.0, 60.0, 20.0))
	ui_access_set_text(tree, 40, UI_ACCESS_NAME, c"Volume", 6)
	ui_access_node* slider = ui_access_add(tree, 41, 1, UI_ACCESS_SLIDER, ui_rect_new(220.0, 30.0, 70.0, 20.0))
	slider.states = UI_ACCESS_FOCUSABLE
	slider.actions = UI_ACCESS_SET_VALUE
	char[40] number
	int digits = ui_access_number_format(&number[0], model.volume)
	ui_access_set_text(tree, 41, UI_ACCESS_VALUE, &number[0], digits)
	ui_access_set_range(tree, 41, model.volume, 0.0, 10.0, 0.5)
	ui_access_add_relation(tree, 41, UI_ACCESS_REL_LABELLED_BY, 40)
	ui_access_node* log = ui_access_add(tree, 42, 1, UI_ACCESS_TEXTBOX, ui_rect_new(10.0, 220.0, 100.0, 40.0))
	log.states = UI_ACCESS_FOCUSABLE | UI_ACCESS_READONLY
	log.actions = UI_ACCESS_SCROLL_TO
	ui_access_set_text(tree, 42, UI_ACCESS_NAME, c"Log", 3)
	ui_access_set_text(tree, 42, UI_ACCESS_VALUE, c"ab\ncd\nef\ngh", 11)
	ui_rect[11] lines
	for k in range(11):
		float32 w = 10.0
		if ((k % 3) == 2): w = 0.0
		lines[k] = ui_rect_new(10.0 + cast(float32, k % 3) * 10.0, 220.0 + cast(float32, k / 3 - model.top_line) * 20.0, w, 20.0)
	ui_access_set_char_boxes(tree, 42, &lines[0], 11)
	tree.focused_id = 2
	tree.action = depth_action
	tree.context = 0
	return tree


int main():
	model.selected[1] = 1
	model.ranges[0] = 0
	model.ranges[1] = 1
	model.ranges[2] = 3
	model.ranges[3] = 5
	model.range_count = 2
	model.volume = 4.0
	model.top_line = 1
	ui_atspi_bridge* b = ui_access_atspi_open(c"W depth")
	if (b == 0):
		say(c"no accessibility bus\n")
		return 1
	ui_access_atspi_set_origin(b, 100, 200)
	ui_access_tree* tree = depth_tree()
	ui_access_atspi_publish(b, tree)
	say(c"ready ")
	say(ui_access_atspi_p2p_address(b))
	say(c"\n")
	int last = 0 - 1
	for frame in range(120 * 50):
		if (ui_access_atspi_dispatch(b, tree) < 0): break
		if model.changed:
			model.changed = 0
			ui_access_tree* fresh = depth_tree()
			ui_access_atspi_publish(b, fresh)
			ui_access_tree_free(tree)
			tree = fresh
		if (((frame % 50) == 0) && (ui_access_atspi_p2p_calls(b) != last)):
			last = ui_access_atspi_p2p_calls(b)
			say(c"p2p ")
			char* n = itoa(last)
			say(n)
			free(n)
			say(c"\n")
		sleep_ms(20)
	ui_access_atspi_close(b)
	ui_access_tree_free(tree)
	return 0
