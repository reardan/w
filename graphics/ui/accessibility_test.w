# wbuild: name=graphics_ui_accessibility_test x64
import lib.testing
import graphics.ui.accessibility
import graphics.ui.accessibility_text
import graphics.ui.accessibility_table

void test_accessibility_owned_snapshot_limits():
	ui_access_tree* tree = ui_access_tree_new(3, 8)
	ui_rect bounds = ui_rect_new(0.0, 0.0, 100.0, 40.0)
	ui_access_node* root = ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, bounds)
	asserts(c"root", root != 0)
	ui_access_node* button = ui_access_add(tree, 2, 1, UI_ACCESS_BUTTON, bounds)
	asserts(c"button", button != 0)
	asserts(c"parent", button.parent == root)
	assert_equal(0, cast(int, ui_access_add(tree, 2, 1, UI_ACCESS_LINK, bounds)))
	assert_equal(0, cast(int, ui_access_add(tree, 3, 999, UI_ACCESS_TEXT, bounds)))
	assert_equal(0, cast(int, ui_access_add(tree, 3, 0, UI_ACCESS_GROUP, bounds)))
	asserts(c"page child", ui_access_add(tree, 3, 1, UI_ACCESS_HEADING, bounds) != 0)
	assert_equal(0, cast(int, ui_access_add(tree, 4, 1, UI_ACCESS_TEXT, bounds)))
	char[4] label
	label[0] = 'O'
	label[1] = 'p'
	label[2] = 'e'
	label[3] = 'n'
	assert_equal(1, ui_access_set_text(tree, 2, UI_ACCESS_NAME, label, 4))
	label[0] = 'x'
	assert_strings_equal(c"Open", button.name.data)
	assert_equal(4, button.name.length)
	assert_equal(1, ui_access_set_text(tree, 3, UI_ACCESS_NAME, c"page", 4))
	assert_equal(0, ui_access_set_text(tree, 2, UI_ACCESS_DESCRIPTION, c"x", 1))
	assert_equal(1, ui_access_set_text(tree, 2, UI_ACCESS_NAME, c"Go", 2))
	assert_equal(6, tree.text_bytes)
	assert_equal(0, ui_access_set_text(tree, 2, UI_ACCESS_NAME, c"\xff", 1))
	assert_strings_equal(c"Go", button.name.data)
	assert_equal(1, ui_access_set_text(tree, 2, UI_ACCESS_VALUE, c"\0x", 2))
	assert_equal(2, button.value.length)
	assert_equal('x', button.value.data[1])
	ui_access_tree_free(tree)

int access_test_action(void* context, int id, int action, char* data, int length):
	int* calls = cast(int*, context)
	*calls = *calls + 1
	assert_equal(2, id)
	assert_equal(UI_ACCESS_SET_VALUE, action)
	assert_equal(3, length)
	assert_bytes_equal(c"new", data, 3)
	return 1

void test_accessibility_focus_and_host_actions():
	ui_access_tree* tree = ui_access_tree_new(10, 64)
	ui_rect r = ui_rect_new(0.0, 0.0, 1.0, 1.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_GROUP, r)
	ui_access_node* input = ui_access_add(tree, 2, 1, UI_ACCESS_TEXTBOX, r)
	ui_access_node* hidden = ui_access_add(tree, 3, 1, UI_ACCESS_BUTTON, r)
	ui_access_node* link = ui_access_add(tree, 4, 1, UI_ACCESS_LINK, r)
	input.states = UI_ACCESS_FOCUSABLE
	input.actions = UI_ACCESS_SET_VALUE
	hidden.states = UI_ACCESS_FOCUSABLE | UI_ACCESS_HIDDEN
	link.states = UI_ACCESS_FOCUSABLE
	assert_equal(2, ui_access_focus_next(tree, 0, 0))
	assert_equal(4, ui_access_focus_next(tree, 2, 0))
	assert_equal(2, ui_access_focus_next(tree, 4, 0))
	assert_equal(4, ui_access_focus_next(tree, 2, 1))
	assert_equal(2, ui_access_focus_next(tree, 4, 1))
	int calls = 0
	tree.context = cast(void*, &calls)
	tree.action = access_test_action
	assert_equal(1, ui_access_dispatch(tree, 2, UI_ACCESS_SET_VALUE, c"new", 3))
	input.states = UI_ACCESS_READONLY
	assert_equal(0, ui_access_dispatch(tree, 2, UI_ACCESS_SET_VALUE, c"new", 3))
	input.states = UI_ACCESS_DISABLED
	assert_equal(0, ui_access_dispatch(tree, 2, UI_ACCESS_SET_VALUE, c"new", 3))
	input.states = 0
	assert_equal(0, ui_access_dispatch(tree, 2, UI_ACCESS_ACTIVATE, 0, 0))
	assert_equal(0, ui_access_dispatch(tree, 2, UI_ACCESS_SET_VALUE, c"\xff", 1))
	ui_access_node* root = ui_access_find(tree, 1)
	root.states = UI_ACCESS_HIDDEN
	assert_equal(0, ui_access_dispatch(tree, 2, UI_ACCESS_SET_VALUE, c"new", 3))
	assert_equal(0, ui_access_focus_next(tree, 0, 0))
	assert_equal(1, calls)
	ui_access_tree_free(tree)

int access_focus_action(void* context, int id, int action, char* data, int length):
	int* accepted = cast(int*, context)
	assert_equal(UI_ACCESS_FOCUS, action)
	assert_equal(0, length)
	return id != *accepted

void test_accessibility_focus_acceptance_and_order():
	ui_access_tree* tree = ui_access_tree_new(8, 0)
	ui_rect r = ui_rect_new(0.0, 0.0, 1.0, 1.0)
	ui_access_add(tree, 71, 0, UI_ACCESS_GROUP, r)
	ui_access_node* first = ui_access_add(tree, 900, 71, UI_ACCESS_BUTTON, r)
	ui_access_node* second = ui_access_add(tree, 13, 71, UI_ACCESS_TEXTBOX, r)
	first.states = UI_ACCESS_FOCUSABLE
	second.states = UI_ACCESS_FOCUSABLE
	first.actions = UI_ACCESS_FOCUS
	second.actions = UI_ACCESS_FOCUS
	int rejected = 13
	tree.context = cast(void*, &rejected)
	tree.action = access_focus_action
	assert_equal(900, ui_access_move_focus(tree, 0))
	assert_equal(0, ui_access_move_focus(tree, 0))
	assert_equal(900, tree.focused_id)
	rejected = 0
	assert_equal(13, ui_access_move_focus(tree, 1))
	assert_equal(900, ui_access_move_focus(tree, 1))
	first.states = UI_ACCESS_DISABLED
	assert_equal(13, ui_access_move_focus(tree, 0))
	ui_access_tree_free(tree)

# Live regions (#465): inherited politeness, what a change announces, the
# one-shot announcement, and snapshot comparison/copies carrying both.
void test_live_regions_and_announcements():
	ui_access_tree* tree = ui_access_tree_new(8, 64)
	ui_rect r = ui_rect_new(0.0, 0.0, 10.0, 10.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_node* region = ui_access_add(tree, 2, 1, UI_ACCESS_GROUP, r)
	region.live = UI_ACCESS_LIVE_ASSERTIVE
	ui_access_node* line = ui_access_add(tree, 3, 2, UI_ACCESS_TEXT, r)
	ui_access_set_text(tree, 3, UI_ACCESS_NAME, c"Saved", 5)
	ui_access_node* other = ui_access_add(tree, 4, 1, UI_ACCESS_TEXT, r)
	asserts(c"inherited region", ui_access_live_root(line) == region)
	asserts(c"outside every region", ui_access_live_root(other) == 0)
	asserts(c"new text announced", ui_access_live_change(line, 0) == &line.name)
	assert_equal(0, cast(int, ui_access_live_change(line, line)))
	assert_equal(0, cast(int, ui_access_live_change(region, 0)))
	assert_equal(0, cast(int, ui_access_live_change(other, 0)))

	ui_access_tree* copy = ui_access_tree_clone(tree)
	assert_equal(UI_ACCESS_LIVE_ASSERTIVE, ui_access_find(copy, 2).live)
	assert_equal(1, ui_access_tree_same(tree, copy))
	ui_access_set_text(copy, 3, UI_ACCESS_NAME, c"Failed", 6)
	asserts(c"changed text announced", ui_access_live_change(ui_access_find(copy, 3), line) == &ui_access_find(copy, 3).name)
	ui_access_set_text(copy, 3, UI_ACCESS_NAME, c"Saved", 5)
	ui_access_find(copy, 2).live = UI_ACCESS_LIVE_POLITE
	assert_equal(0, ui_access_tree_same(tree, copy))
	ui_access_tree_free(copy)
	region.states = UI_ACCESS_HIDDEN
	assert_equal(0, cast(int, ui_access_live_change(line, 0)))
	region.states = 0

	assert_equal(0, ui_access_announce(tree, c"", 0, UI_ACCESS_LIVE_POLITE))
	assert_equal(0, ui_access_announce(tree, c"x", 1, UI_ACCESS_LIVE_OFF))
	assert_equal(0, ui_access_announce(tree, c"\xff", 1, UI_ACCESS_LIVE_POLITE))
	assert_equal(0, tree.announcement.length)
	assert_equal(1, ui_access_announce(tree, c"Exported", 8, UI_ACCESS_LIVE_POLITE))
	assert_equal(1, ui_access_announce(tree, c"Export failed", 13, UI_ACCESS_LIVE_ASSERTIVE))
	assert_strings_equal(c"Export failed", tree.announcement.data)
	copy = ui_access_tree_clone(tree)
	assert_strings_equal(c"Export failed", copy.announcement.data)
	assert_equal(UI_ACCESS_LIVE_ASSERTIVE, copy.announcement_live)
	assert_equal(1, ui_access_tree_same(tree, copy))
	ui_access_announcement_clear(copy)
	assert_equal(0, ui_access_tree_same(tree, copy))
	assert_equal(UI_ACCESS_LIVE_OFF, copy.announcement_live)
	ui_access_tree_free(copy)
	ui_access_tree_free(tree)

# An unnamed row is named from its cells; its own name wins.
void test_rows_are_named_from_their_cells():
	ui_access_tree* tree = ui_access_tree_new(8, 64)
	ui_rect r = ui_rect_new(0.0, 0.0, 10.0, 10.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_TABLE, r)
	ui_access_node* row = ui_access_add(tree, 2, 1, UI_ACCESS_ROW, r)
	ui_access_add(tree, 3, 2, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, 3, UI_ACCESS_NAME, c"a.txt", 5)
	ui_access_add(tree, 4, 2, UI_ACCESS_CELL, r)
	ui_access_add(tree, 5, 2, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, 5, UI_ACCESS_NAME, c"3 KB", 4)
	ui_access_text name
	ui_access_effective_name(row, &name)
	assert_strings_equal(c"a.txt 3 KB", name.data)
	assert_equal(10, name.length)
	free(name.data)
	ui_access_tree* copy = ui_access_tree_clone(tree)
	assert_equal(1, ui_access_effective_name_same(row, ui_access_find(copy, 2)))
	ui_access_set_text(copy, 5, UI_ACCESS_NAME, c"4 KB", 4)
	assert_equal(0, ui_access_effective_name_same(row, ui_access_find(copy, 2)))
	ui_access_set_text(tree, 2, UI_ACCESS_NAME, c"First", 5)
	ui_access_effective_name(row, &name)
	assert_strings_equal(c"First", name.data)
	free(name.data)
	ui_access_effective_name(ui_access_find(tree, 4), &name)
	assert_equal(0, name.length)
	assert_equal(0, cast(int, name.data))
	ui_access_tree_free(copy)
	ui_access_tree_free(tree)

int access_selection_action(void* context, int id, int action, char* data, int length):
	int* calls = cast(int*, context)
	*calls = *calls + 1
	assert_equal(UI_ACCESS_SET_SELECTION, action)
	int anchor = 0
	int active = 0
	assert_equal(1, ui_access_selection_parse(data, length, &anchor, &active))
	assert_equal(5, anchor)
	assert_equal(2, active)
	return 1

void test_accessibility_caret_and_selection():
	ui_access_tree* tree = ui_access_tree_new(4, 64)
	ui_rect r = ui_rect_new(0.0, 0.0, 1.0, 1.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_GROUP, r)
	ui_access_node* input = ui_access_add(tree, 2, 1, UI_ACCESS_TEXTBOX, r)
	assert_equal(0 - 1, input.caret)
	assert_equal(0, ui_access_has_selection(input))
	# "a\xc3\xa9b\xf0\x9f\x98\x80c": five characters in nine bytes.
	ui_access_set_text(tree, 2, UI_ACCESS_VALUE, c"a\xc3\xa9b\xf0\x9f\x98\x80c", 9)
	assert_equal(5, ui_access_char_count(input.value.data, input.value.length))
	assert_equal(3, ui_access_char_byte(input.value.data, 9, 2))
	assert_equal(9, ui_access_char_byte(input.value.data, 9, 7))
	assert_equal(4, ui_access_byte_char(input.value.data, 9, 8))
	assert_equal(3, ui_access_byte_char(input.value.data, 9, 5))
	assert_equal(1, ui_access_set_selection(tree, 2, 5, 2))
	assert_equal(2, input.caret)
	assert_equal(2, input.selection_start)
	assert_equal(5, input.selection_end)
	asserts(c"has selection", ui_access_has_selection(input))
	assert_equal(0, ui_access_set_selection(tree, 2, 6, 2))
	assert_equal(0, ui_access_set_selection(tree, 9, 0, 0))
	assert_equal(2, input.caret)

	# Clones and comparisons see the caret and selection.
	ui_access_tree* copy = ui_access_tree_clone(tree)
	assert_equal(1, ui_access_tree_same(tree, copy))
	assert_equal(5, ui_access_find(copy, 2).selection_end)
	ui_access_set_selection(copy, 2, 1, 1)
	assert_equal(0, ui_access_tree_same(tree, copy))
	ui_access_tree_free(copy)

	char[32] payload
	int n = ui_access_selection_format(&payload[0], 0, 120)
	assert_equal(5, n)
	assert_bytes_equal(c"0 120", &payload[0], 5)
	int anchor = 0
	int active = 0
	assert_equal(0, ui_access_selection_parse(c"1", 1, &anchor, &active))
	assert_equal(0, ui_access_selection_parse(c"1 2 3", 5, &anchor, &active))
	assert_equal(0, ui_access_selection_parse(c"1 x", 3, &anchor, &active))
	assert_equal(0, ui_access_selection_parse(c" 1", 2, &anchor, &active))

	int calls = 0
	tree.context = cast(void*, &calls)
	tree.action = access_selection_action
	# Unsupported until the node offers it, then range-checked.
	assert_equal(0, ui_access_dispatch_selection(tree, 2, 5, 2))
	input.actions = UI_ACCESS_SET_SELECTION
	assert_equal(0, ui_access_dispatch(tree, 2, UI_ACCESS_SET_SELECTION, c"5", 1))
	assert_equal(0, ui_access_dispatch_selection(tree, 2, 0 - 1, 2))
	assert_equal(1, ui_access_dispatch_selection(tree, 2, 5, 2))
	# Read-only text can still be selected.
	input.states = UI_ACCESS_READONLY
	assert_equal(1, ui_access_dispatch_selection(tree, 2, 5, 2))
	assert_equal(2, calls)
	ui_access_tree_free(tree)


int depth_calls
char[64] depth_last


int depth_action(void* context, int id, int action, char* data, int length):
	depth_calls = depth_calls + 1
	for i in range(length): depth_last[i] = data[i]
	depth_last[length] = 0
	return 1


# Glyph boxes: "ab\ncd" laid out as two lines of 10-pixel characters.
void test_glyph_geometry_and_points():
	ui_access_tree* tree = ui_access_tree_new(4, 64)
	ui_rect r = ui_rect_new(0.0, 0.0, 100.0, 40.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_node* t = ui_access_add(tree, 2, 1, UI_ACCESS_TEXTBOX, r)
	ui_access_set_text(tree, 2, UI_ACCESS_VALUE, c"ab\ncd", 5)
	ui_rect[5] boxes
	boxes[0] = ui_rect_new(4.0, 2.0, 10.0, 16.0)
	boxes[1] = ui_rect_new(14.0, 2.0, 10.0, 16.0)
	boxes[2] = ui_rect_new(24.0, 2.0, 0.0, 16.0)
	boxes[3] = ui_rect_new(4.0, 20.0, 10.0, 16.0)
	boxes[4] = ui_rect_new(14.0, 20.0, 12.0, 16.0)
	assert_equal(0, ui_access_set_char_boxes(tree, 2, &boxes[0], 4))
	ui_rect box
	assert_equal(0, ui_access_char_box(t, 0, &box))
	assert_equal(1, ui_access_set_char_boxes(tree, 2, &boxes[0], 5))
	assert_equal(1, ui_access_char_box(t, 4, &box))
	assert_equal(14, cast(int, box.x))
	assert_equal(12, cast(int, box.w))
	# The end of the text: a caret box after the last character.
	assert_equal(1, ui_access_char_box(t, 5, &box))
	assert_equal(26, cast(int, box.x))
	assert_equal(0, cast(int, box.w))
	assert_equal(0, ui_access_char_box(t, 6, &box))
	assert_equal(1, ui_access_range_box(t, 1, 4, &box))
	assert_equal(4, cast(int, box.x))
	assert_equal(2, cast(int, box.y))
	assert_equal(20, cast(int, box.w))
	assert_equal(34, cast(int, box.h))
	ui_rect[4] lines
	assert_equal(2, ui_access_range_lines(t, 0, 5, &lines[0], 4))
	assert_equal(20, cast(int, lines[0].w))
	assert_equal(20, cast(int, lines[1].y))
	assert_equal(22, cast(int, lines[1].w))
	assert_equal(1, ui_access_range_lines(t, 3, 4, &lines[0], 4))
	assert_equal(3, ui_access_offset_at_point(t, 5.0, 21.0))
	assert_equal(0 - 1, ui_access_offset_at_point(t, 50.0, 21.0))
	assert_equal(1, ui_access_caret_at_point(t, 12.0, 5.0))
	assert_equal(0, ui_access_caret_at_point(t, 0.0, 0.0))
	# Past a line's end the caret goes before its newline; past the
	# last line, to the end of the text.
	assert_equal(2, ui_access_caret_at_point(t, 90.0, 4.0))
	assert_equal(5, ui_access_caret_at_point(t, 90.0, 39.0))

	# Clones carry the boxes; a moved box is a change.
	ui_access_tree* copy = ui_access_tree_clone(tree)
	assert_equal(1, ui_access_tree_same(tree, copy))
	ui_access_node* moved = ui_access_find(copy, 2)
	moved.char_boxes[1].x = 15.0
	assert_equal(0, ui_access_tree_same(tree, copy))
	ui_access_tree_free(copy)
	ui_access_tree_free(tree)


void test_text_attribute_runs():
	ui_access_tree* tree = ui_access_tree_new(4, 64)
	ui_rect r = ui_rect_new(0.0, 0.0, 100.0, 40.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_node* t = ui_access_add(tree, 2, 1, UI_ACCESS_TEXTBOX, r)
	ui_access_set_text(tree, 2, UI_ACCESS_VALUE, c"plain bold tail", 15)
	int start = 0
	int end = 0
	assert_equal(0, cast(int, ui_access_attrs_at(t, 3, &start, &end)))
	assert_equal(15, end)
	ui_access_text_attrs* base = ui_access_default_attrs(tree, 2)
	assert_equal(0 - 1, base.fg)
	assert_equal(1, ui_access_attrs_set_family(base, c"Liberation Sans", 15))
	base.size = 12
	base.weight = 400
	base.fg = ui_access_rgb(0.0, 0.0, 0.0)
	base.bg = ui_access_rgb(1.0, 1.0, 1.0)
	assert_equal(16777215, base.bg)
	ui_access_text_attrs* bold = ui_access_add_attr_run(tree, 2, 6, 10)
	assert_equal(12, bold.size)
	bold.weight = 700
	assert_equal(0, cast(int, ui_access_add_attr_run(tree, 2, 8, 12)))
	assert_equal(0, cast(int, ui_access_add_attr_run(tree, 2, 12, 16)))
	ui_access_text_attrs* a = ui_access_attrs_at(t, 2, &start, &end)
	assert_equal(400, a.weight)
	assert_equal(0, start)
	assert_equal(6, end)
	a = ui_access_attrs_at(t, 7, &start, &end)
	assert_equal(700, a.weight)
	assert_strings_equal(c"Liberation Sans", a.family.data)
	assert_equal(6, start)
	assert_equal(10, end)
	a = ui_access_attrs_at(t, 12, &start, &end)
	assert_equal(10, start)
	assert_equal(15, end)
	assert_equal(1, ui_access_attrs_uniform(t, 0, 6))
	assert_equal(0, ui_access_attrs_uniform(t, 4, 8))
	assert_equal(1, ui_access_attrs_uniform(t, 7, 9))

	ui_access_tree* copy = ui_access_tree_clone(tree)
	assert_equal(1, ui_access_tree_same(tree, copy))
	ui_access_find(copy, 2).runs[0].attrs.italic = 1
	assert_equal(0, ui_access_tree_same(tree, copy))
	ui_access_tree_free(copy)
	ui_access_tree_free(tree)


void test_multiple_text_selections():
	ui_access_tree* tree = ui_access_tree_new(4, 64)
	ui_rect r = ui_rect_new(0.0, 0.0, 100.0, 40.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_node* t = ui_access_add(tree, 2, 1, UI_ACCESS_TEXTBOX, r)
	ui_access_set_text(tree, 2, UI_ACCESS_VALUE, c"one two three", 13)
	ui_access_set_selection(tree, 2, 0, 3)
	assert_equal(0, ui_access_add_selection(tree, 2, 5, 5))
	assert_equal(0, ui_access_add_selection(tree, 2, 8, 14))
	assert_equal(1, ui_access_add_selection(tree, 2, 8, 13))
	assert_equal(2, ui_access_selection_total(t))
	int start = 0
	int end = 0
	assert_equal(1, ui_access_selection_range(t, 1, &start, &end))
	assert_equal(8, start)
	assert_equal(13, end)
	assert_equal(0, ui_access_selection_range(t, 2, &start, &end))
	ui_access_tree* copy = ui_access_tree_clone(tree)
	assert_equal(1, ui_access_tree_same(tree, copy))
	assert_equal(2, ui_access_selection_total(ui_access_find(copy, 2)))
	ui_access_tree_free(copy)

	int[6] pairs
	pairs[0] = 3
	pairs[1] = 0
	pairs[2] = 8
	pairs[3] = 13
	char[64] payload
	int n = ui_access_selections_format(&payload[0], &pairs[0], 2)
	assert_bytes_equal(c"3 0 8 13", &payload[0], n)
	int[4] back
	assert_equal(2, ui_access_selections_parse(&payload[0], n, &back[0], 2))
	assert_equal(13, back[3])
	assert_equal(0, ui_access_selections_parse(c"1 2 3", 5, 0, 0))
	assert_equal(0, ui_access_selections_parse(c"", 0, 0, 0))

	depth_calls = 0
	tree.action = depth_action
	assert_equal(0, ui_access_dispatch(tree, 2, UI_ACCESS_SET_SELECTIONS, &payload[0], n))
	t.actions = UI_ACCESS_SET_SELECTIONS
	assert_equal(0, ui_access_dispatch(tree, 2, UI_ACCESS_SET_SELECTIONS, c"1 2 3", 5))
	assert_equal(1, ui_access_dispatch(tree, 2, UI_ACCESS_SET_SELECTIONS, &payload[0], n))
	assert_strings_equal(c"3 0 8 13", &depth_last[0])
	ui_access_tree_free(tree)


void test_multi_select_requests():
	ui_access_tree* tree = ui_access_tree_new(8, 64)
	ui_rect r = ui_rect_new(0.0, 0.0, 100.0, 40.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_node* list = ui_access_add(tree, 2, 1, UI_ACCESS_LIST, r)
	ui_access_node* item = ui_access_add(tree, 3, 2, UI_ACCESS_LIST_ITEM, r)
	item.actions = UI_ACCESS_SELECT
	depth_calls = 0
	tree.action = depth_action
	assert_equal(UI_ACCESS_SELECT_REMOVE, ui_access_select_mode(c"remove", 6))
	assert_equal(0, ui_access_select_mode(c"all", 3))
	assert_equal(0, ui_access_dispatch(tree, 3, UI_ACCESS_SELECT, c"bad", 3))
	# A single-selection list only takes "only".
	assert_equal(0, ui_access_dispatch_select(tree, 3, UI_ACCESS_SELECT_ADD))
	assert_equal(1, ui_access_dispatch_select(tree, 3, UI_ACCESS_SELECT_ONLY))
	assert_strings_equal(c"only", &depth_last[0])
	list.states = UI_ACCESS_MULTISELECTABLE
	asserts(c"multi", ui_access_is_multiselectable(list))
	assert_equal(1, ui_access_dispatch_select(tree, 3, UI_ACCESS_SELECT_REMOVE))
	assert_strings_equal(c"remove", &depth_last[0])
	assert_equal(2, depth_calls)
	ui_access_tree_free(tree)


ui_access_node* span_cell(ui_access_tree* tree, int id, int row, char* name, int rows, int cols):
	ui_access_node* c = ui_access_add(tree, id, row, UI_ACCESS_CELL, ui_rect_new(0.0, 0.0, 10.0, 10.0))
	ui_access_set_text(tree, id, UI_ACCESS_NAME, name, strlen(name))
	c.row_span = rows
	c.col_span = cols
	return c


# A header row (explicit) over three columns, then
#   row 0: [Fruit (row header, 2 rows)] [Apple] [Red]
#   row 1:                               [Cherry (2 columns)]
#   row 2: [Veg (row header)] [Kale] [Green]
void test_table_spans_and_row_headers():
	ui_access_tree* tree = ui_access_tree_new(32, 256)
	ui_rect r = ui_rect_new(0.0, 0.0, 100.0, 100.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_node* table = ui_access_add(tree, 2, 1, UI_ACCESS_TABLE, r)
	ui_access_node* head = ui_access_add(tree, 10, 2, UI_ACCESS_ROW, r)
	head.states = UI_ACCESS_HEADER
	span_cell(tree, 11, 10, c"Kind", 1, 1)
	span_cell(tree, 12, 10, c"Item", 1, 2)
	ui_access_add(tree, 20, 2, UI_ACCESS_ROW, r)
	ui_access_node* fruit = span_cell(tree, 21, 20, c"Fruit", 2, 1)
	fruit.states = UI_ACCESS_HEADER
	span_cell(tree, 22, 20, c"Apple", 1, 1)
	span_cell(tree, 23, 20, c"Red", 1, 1)
	ui_access_add(tree, 30, 2, UI_ACCESS_ROW, r)
	ui_access_node* cherry = span_cell(tree, 31, 30, c"Cherry", 1, 2)
	ui_access_add(tree, 40, 2, UI_ACCESS_ROW, r)
	ui_access_node* veg = span_cell(tree, 41, 40, c"Veg", 1, 1)
	veg.states = UI_ACCESS_HEADER
	span_cell(tree, 42, 40, c"Kale", 1, 1)
	ui_access_node* green = span_cell(tree, 43, 40, c"Green", 5, 1)

	asserts(c"explicit header row", ui_access_is_header_row(head))
	assert_equal(3, ui_access_table_rows(table))
	assert_equal(3, ui_access_table_columns(table))
	int row = 0
	int col = 0
	int rs = 0
	int cs = 0
	assert_equal(1, ui_access_cell_slot(cherry, &row, &col, &rs, &cs))
	assert_equal(1, row)
	assert_equal(1, col)
	assert_equal(1, rs)
	assert_equal(2, cs)
	assert_equal(1, ui_access_cell_slot(fruit, &row, &col, &rs, &cs))
	assert_equal(2, rs)
	# Row spans are clipped to the table.
	assert_equal(1, ui_access_cell_slot(green, &row, &col, &rs, &cs))
	assert_equal(2, row)
	assert_equal(2, col)
	assert_equal(1, rs)
	assert_equal(21, ui_access_table_cell_at(table, 1, 0).id)
	assert_equal(31, ui_access_table_cell_at(table, 1, 2).id)
	assert_equal(23, ui_access_table_cell_at(table, 0, 2).id)
	assert_equal(0, cast(int, ui_access_table_cell_at(table, 3, 0)))
	assert_equal(0, cast(int, ui_access_table_cell_at(table, 0, 3)))

	ui_access_node* found = 0
	asserts(c"row header", ui_access_is_row_header(fruit))
	asserts(c"not a row header", !ui_access_is_row_header(cherry))
	assert_equal(1, ui_access_row_headers_of(cherry, 0, &found))
	assert_equal(21, found.id)
	assert_equal(0, ui_access_row_headers_of(fruit, 0, &found))
	assert_equal(2, ui_access_table_row_headers(table, 1, &found))
	assert_equal(41, found.id)
	# Cherry spans columns 1-2, both under "Item"; Fruit is under "Kind".
	assert_equal(1, ui_access_column_headers_of(cherry, 0, &found))
	assert_equal(12, found.id)
	assert_equal(1, ui_access_column_headers_of(fruit, 0, &found))
	assert_equal(11, found.id)
	int hc = 0
	int hs = 0
	assert_equal(1, ui_access_header_cell_column(ui_access_find(tree, 12), &hc, &hs))
	assert_equal(1, hc)
	assert_equal(2, hs)

	# Without spans the plain rule applies: column = cell index.
	ui_access_tree* plain = ui_access_tree_new(16, 64)
	ui_access_add(plain, 1, 0, UI_ACCESS_TABLE, r)
	ui_access_node* only = ui_access_add(plain, 2, 1, UI_ACCESS_ROW, r)
	only.actions = UI_ACCESS_ACTIVATE
	ui_access_add(plain, 3, 2, UI_ACCESS_CELL, r)
	ui_access_node* second = ui_access_add(plain, 4, 2, UI_ACCESS_CELL, r)
	assert_equal(1, ui_access_cell_position(second, &row, &col))
	assert_equal(1, col)
	assert_equal(0, ui_access_table_row_headers(ui_access_find(plain, 1), 0, &found))
	ui_access_tree_free(plain)

	ui_access_tree* copy = ui_access_tree_clone(tree)
	assert_equal(1, ui_access_tree_same(tree, copy))
	ui_access_find(copy, 31).col_span = 1
	assert_equal(0, ui_access_tree_same(tree, copy))
	ui_access_tree_free(copy)
	ui_access_tree_free(tree)
