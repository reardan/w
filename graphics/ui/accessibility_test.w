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
