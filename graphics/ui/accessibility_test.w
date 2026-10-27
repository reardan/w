# wbuild: name=graphics_ui_accessibility_test x64
import lib.testing
import graphics.ui.accessibility

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
