# Owned semantic snapshots for native controls and page content (#637/#465).
# No platform bridge is installed by this module; see browser_ui.md.
import lib.lib
import lib.container
import lib.utf8
import graphics.ui.rect

const int UI_ACCESS_DOCUMENT = 1
const int UI_ACCESS_GROUP = 2
const int UI_ACCESS_TEXT = 3
const int UI_ACCESS_HEADING = 4
const int UI_ACCESS_LINK = 5
const int UI_ACCESS_BUTTON = 6
const int UI_ACCESS_CHECKBOX = 7
const int UI_ACCESS_TEXTBOX = 8
const int UI_ACCESS_IMAGE = 9
const int UI_ACCESS_LIST = 10
const int UI_ACCESS_LIST_ITEM = 11
const int UI_ACCESS_TABLE = 12
const int UI_ACCESS_ROW = 13
const int UI_ACCESS_CELL = 14
const int UI_ACCESS_DISABLED = 1
const int UI_ACCESS_CHECKED = 2
const int UI_ACCESS_SELECTED = 4
const int UI_ACCESS_EXPANDED = 8
const int UI_ACCESS_READONLY = 16
const int UI_ACCESS_HIDDEN = 32
const int UI_ACCESS_FOCUSABLE = 64
const int UI_ACCESS_ACTIVATE = 1
const int UI_ACCESS_FOCUS = 2
const int UI_ACCESS_SET_VALUE = 4
const int UI_ACCESS_TOGGLE = 8
const int UI_ACCESS_NAME = 1
const int UI_ACCESS_VALUE = 2
const int UI_ACCESS_DESCRIPTION = 3

type ui_access_action = fn(void*, int, int, char*, int) -> int

struct ui_access_text:
	char* data
	int length

struct ui_access_node:
	int id
	int role
	int states
	int actions
	int heading_level
	ui_rect bounds
	ui_access_text name
	ui_access_text value
	ui_access_text description
	ui_access_node* parent
	ui_access_node* first_child
	ui_access_node* last_child
	ui_access_node* next_sibling
	ui_access_node* allocation_next

struct ui_access_tree:
	map[int, ui_access_node*] nodes
	ui_access_node* root
	ui_access_node* allocations
	int count
	int max_nodes
	int text_bytes
	int max_text_bytes
	int focused_id
	ui_access_action* action
	void* context

ui_access_tree* ui_access_tree_new(int max_nodes, int max_text_bytes):
	if ((max_nodes < 1) || (max_text_bytes < 0)): return 0
	ui_access_tree* tree = new ui_access_tree()
	tree.nodes = new map[int, ui_access_node*]
	tree.max_nodes = max_nodes
	tree.max_text_bytes = max_text_bytes
	return tree

ui_access_node* ui_access_find(ui_access_tree* tree, int id):
	if (tree == 0): return 0
	if (id in tree.nodes): return tree.nodes[id]
	return 0

# Parents precede children; exactly one root (parent_id = 0).
# Invalid input and exhausted budgets leave the snapshot unchanged.
ui_access_node* ui_access_add(ui_access_tree* tree, int id, int parent_id, int role, ui_rect bounds):
	if ((tree == 0) || (id <= 0) || (role < UI_ACCESS_DOCUMENT) || (role > UI_ACCESS_CELL)): return 0
	if ((tree.count >= tree.max_nodes) || (ui_access_find(tree, id) != 0)): return 0
	ui_access_node* parent = ui_access_find(tree, parent_id)
	if (parent_id == 0):
		if (tree.root != 0): return 0
	else if (parent == 0): return 0
	ui_access_node* node = new ui_access_node()
	node.id = id
	node.role = role
	node.parent = parent
	node.bounds = bounds
	if (parent == 0): tree.root = node
	else:
		if (parent.last_child == 0): parent.first_child = node
		else: parent.last_child.next_sibling = node
		parent.last_child = node
	node.allocation_next = tree.allocations
	tree.allocations = node
	tree.nodes[id] = node
	tree.count = tree.count + 1
	return node

int ui_access_set_text(ui_access_tree* tree, int id, int field, char* data, int length):
	ui_access_node* node = ui_access_find(tree, id)
	if ((node == 0) || (length < 0) || ((data == 0) && (length > 0))): return 0
	ui_access_text* target = 0
	if (field == UI_ACCESS_NAME): target = &node.name
	if (field == UI_ACCESS_VALUE): target = &node.value
	if (field == UI_ACCESS_DESCRIPTION): target = &node.description
	if (target == 0): return 0
	int available = tree.max_text_bytes - (tree.text_bytes - target.length)
	if (length > available): return 0
	if (!utf8_validate_bytes(data, length)): return 0
	char* owned = cast(char*, __w_alloc(__w_size_add(length, 1)))
	for i in range(length): owned[i] = data[i]
	owned[length] = 0
	tree.text_bytes = tree.text_bytes - target.length + length
	free(target.data)
	target.data = owned
	target.length = length
	return 1

int ui_access_inert(ui_access_node* node):
	while (node != 0):
		if ((node.states & (UI_ACCESS_DISABLED | UI_ACCESS_HIDDEN)) != 0): return 1
		node = node.parent
	return 0

# Returns the host callback's success value; unsupported/hidden/disabled
# actions fail before host code runs. Values are explicit-length UTF-8.
int ui_access_dispatch(ui_access_tree* tree, int id, int action, char* data, int length):
	ui_access_node* node = ui_access_find(tree, id)
	if ((node == 0) || (cast(int, tree.action) == 0)): return 0
	if ((action != UI_ACCESS_ACTIVATE) && (action != UI_ACCESS_FOCUS) && (action != UI_ACCESS_SET_VALUE) && (action != UI_ACCESS_TOGGLE)): return 0
	if ((node.actions & action) == 0): return 0
	if (ui_access_inert(node)): return 0
	if ((action == UI_ACCESS_SET_VALUE) && ((node.states & UI_ACCESS_READONLY) != 0)): return 0
	if ((length < 0) || (length > tree.max_text_bytes) || ((data == 0) && (length > 0))): return 0
	if (!utf8_validate_bytes(data, length)): return 0
	return tree.action(tree.context, id, action, data, length)

# next is forward when reverse=0; otherwise previous. Insertion order
# is caller supplied focus order, with wraparound, skipping inert nodes.
int ui_access_focus_next(ui_access_tree* tree, int current_id, int reverse):
	if (tree == 0): return 0
	int first = 0
	int last = 0
	int previous = 0
	int found = 0
	int result = 0
	for int id in tree.nodes:
		ui_access_node* n = tree.nodes[id]
		if (((n.states & UI_ACCESS_FOCUSABLE) != 0) && !ui_access_inert(n)):
			if (first == 0): first = id
			last = id
			if (reverse && (id == current_id)): result = previous
			if (!reverse && found && (result == 0)): result = id
			if (id == current_id): found = 1
			previous = id
	if (result != 0): return result
	if (reverse): return last
	return first

void ui_access_tree_free(ui_access_tree* tree):
	if (tree == 0): return
	ui_access_node* n = tree.allocations
	while (n != 0):
		ui_access_node* next = n.allocation_next
		free(n.name.data)
		free(n.value.data)
		free(n.description.data)
		free(n)
		n = next
	map_free[int, ui_access_node*](tree.nodes)
	free(tree)
