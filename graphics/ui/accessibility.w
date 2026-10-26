# Owned semantic snapshots for native controls and page content (#637/#465).
# Opt-in native adapters are separate imports; see accessibility.md.
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
const int UI_ACCESS_RADIO = 15
const int UI_ACCESS_SWITCH = 16
const int UI_ACCESS_COMBOBOX = 17
const int UI_ACCESS_TAB_LIST = 18
const int UI_ACCESS_TAB = 19
const int UI_ACCESS_PROGRESS = 20
const int UI_ACCESS_DIALOG = 21
const int UI_ACCESS_ROLE_LAST = 21
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
# Move the caret / select text in a textbox. The payload is the ASCII
# "anchor active" pair of character offsets built by
# ui_access_dispatch_selection (see there).
const int UI_ACCESS_SET_SELECTION = 16
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
	# Text caret and selection (#465), in characters (code points) of
	# value: caret is -1 when the node shows none; the selection is
	# [selection_start, selection_end), empty when they are equal.
	# Set them with ui_access_set_selection.
	int caret
	int selection_start
	int selection_end
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
	if ((tree == 0) || (id <= 0) || (role < UI_ACCESS_DOCUMENT) || (role > UI_ACCESS_ROLE_LAST)): return 0
	if ((tree.count >= tree.max_nodes) || (ui_access_find(tree, id) != 0)): return 0
	ui_access_node* parent = ui_access_find(tree, parent_id)
	if (parent_id == 0):
		if (tree.root != 0): return 0
	else if (parent == 0): return 0
	ui_access_node* node = new ui_access_node()
	node.id = id
	node.role = role
	node.caret = 0 - 1
	node.selection_start = 0 - 1
	node.selection_end = 0 - 1
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

# Characters (code points) in UTF-8 data[0..length).
int ui_access_char_count(char* data, int length):
	int count = 0
	for i in range(length):
		if ((data[i] & 192) != 128): count = count + 1
	return count


# Byte offset of character k in UTF-8 data[0..length), clamped to its
# ends.
int ui_access_char_byte(char* data, int length, int k):
	if (k <= 0): return 0
	int count = 0
	for i in range(length):
		if ((data[i] & 192) != 128):
			if (count == k): return i
			count = count + 1
	return length


# Character offset of byte offset at (a byte inside a character counts
# as that character's start).
int ui_access_byte_char(char* data, int length, int at):
	if (at > length): at = length
	int count = 0
	for i in range(at):
		if ((data[i] & 192) != 128): count = count + 1
	if ((at < length) && (at > 0) && ((data[at] & 192) == 128)): count = count - 1
	return count


# Record a text node's caret and selection, in characters of its value
# (set the value first). anchor is where the selection started and
# active the end the caret is at, so active < anchor is a backward
# selection; anchor == active is a bare caret. Out-of-range offsets
# leave the node unchanged and return 0.
int ui_access_set_selection(ui_access_tree* tree, int id, int anchor, int active):
	ui_access_node* node = ui_access_find(tree, id)
	if (node == 0): return 0
	int count = ui_access_char_count(node.value.data, node.value.length)
	if ((anchor < 0) || (active < 0) || (anchor > count) || (active > count)): return 0
	node.caret = active
	node.selection_start = anchor
	node.selection_end = active
	if (active < anchor):
		node.selection_start = active
		node.selection_end = anchor
	return 1


# 1 when the node has a non-empty text selection.
int ui_access_has_selection(ui_access_node* node):
	return (node != 0) && (node.selection_start >= 0) && (node.selection_end > node.selection_start)


# Parse a SET_SELECTION payload: two decimal numbers separated by one
# space. 0 when it is malformed.
int ui_access_selection_parse(char* data, int length, int* anchor, int* active):
	int values = 0
	int current = 0
	int digits = 0
	for i in range(length + 1):
		if ((i == length) || (data[i] == ' ')):
			if ((digits == 0) || (values >= 2)): return 0
			if (values == 0): anchor[0] = current
			else: active[0] = current
			values = values + 1
			current = 0
			digits = 0
		else:
			if ((data[i] < '0') || (data[i] > '9') || (digits >= 9)): return 0
			current = current * 10 + (data[i] - '0')
			digits = digits + 1
	return values == 2


# Encode a SET_SELECTION payload into out (at least 24 bytes); returns
# its length.
int ui_access_selection_format(char* out, int anchor, int active):
	int n = 0
	for half in range(2):
		int v = anchor
		if (half == 1):
			out[n] = ' '
			n = n + 1
			v = active
		char[12] digits
		int k = 0
		if (v < 0): v = 0
		while ((v > 0) || (k == 0)):
			digits[k] = '0' + (v % 10)
			v = v / 10
			k = k + 1
		while (k > 0):
			k = k - 1
			out[n] = digits[k]
			n = n + 1
	return n


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
	if ((action != UI_ACCESS_ACTIVATE) && (action != UI_ACCESS_FOCUS) && (action != UI_ACCESS_SET_VALUE) && (action != UI_ACCESS_TOGGLE) && (action != UI_ACCESS_SET_SELECTION)): return 0
	if ((node.actions & action) == 0): return 0
	if (ui_access_inert(node)): return 0
	if ((action == UI_ACCESS_SET_VALUE) && ((node.states & UI_ACCESS_READONLY) != 0)): return 0
	if ((length < 0) || (length > tree.max_text_bytes) || ((data == 0) && (length > 0))): return 0
	if (!utf8_validate_bytes(data, length)): return 0
	if (action == UI_ACCESS_SET_SELECTION):
		# Offsets must fall inside the text the requester saw.
		int anchor = 0
		int active = 0
		if (!ui_access_selection_parse(data, length, &anchor, &active)): return 0
		int count = ui_access_char_count(node.value.data, node.value.length)
		if ((anchor > count) || (active > count)): return 0
	return tree.action(tree.context, id, action, data, length)


# Request a caret move (anchor == active) or a selection of characters
# between anchor and active, with the caret at active, through
# ui_access_dispatch.
int ui_access_dispatch_selection(ui_access_tree* tree, int id, int anchor, int active):
	if ((anchor < 0) || (active < 0)): return 0
	char[32] payload
	int n = ui_access_selection_format(&payload[0], anchor, active)
	return ui_access_dispatch(tree, id, UI_ACCESS_SET_SELECTION, &payload[0], n)

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

# Apply a Tab/Shift-Tab proposal through the host, updating snapshot focus
# only when accepted. The caller draws a focus ring at the resulting bounds.
int ui_access_move_focus(ui_access_tree* tree, int reverse):
	if (tree == 0): return 0
	int id = ui_access_focus_next(tree, tree.focused_id, reverse)
	if (id == 0): return 0
	if (!ui_access_dispatch(tree, id, UI_ACCESS_FOCUS, 0, 0)): return 0
	tree.focused_id = id
	return id

int ui_access_text_same(ui_access_text* a, ui_access_text* b):
	if (a.length != b.length): return 0
	for i in range(a.length):
		if (a.data[i] != b.data[i]): return 0
	return 1

# 1 when two snapshots would publish identically: same nodes in the same
# order with equal fields, text, bounds and focus. Lets a per-frame
# capture republish only on semantic changes.
int ui_access_tree_same(ui_access_tree* a, ui_access_tree* b):
	if ((a == 0) || (b == 0)): return a == b
	if ((a.count != b.count) || (a.focused_id != b.focused_id)): return 0
	ui_access_node* x = a.allocations
	ui_access_node* y = b.allocations
	while ((x != 0) && (y != 0)):
		if ((x.id != y.id) || (x.role != y.role) || (x.states != y.states) || (x.actions != y.actions) || (x.heading_level != y.heading_level)): return 0
		if ((x.caret != y.caret) || (x.selection_start != y.selection_start) || (x.selection_end != y.selection_end)): return 0
		int xp = 0
		int yp = 0
		if (x.parent != 0): xp = x.parent.id
		if (y.parent != 0): yp = y.parent.id
		if (xp != yp): return 0
		if ((x.bounds.x != y.bounds.x) || (x.bounds.y != y.bounds.y) || (x.bounds.w != y.bounds.w) || (x.bounds.h != y.bounds.h)): return 0
		if (!ui_access_text_same(&x.name, &y.name) || !ui_access_text_same(&x.value, &y.value) || !ui_access_text_same(&x.description, &y.description)): return 0
		x = x.allocation_next
		y = y.allocation_next
	return (x == 0) && (y == 0)

# An owned copy of a snapshot (no action callback): what a bridge keeps
# to answer queries after the application has replaced its own tree.
ui_access_tree* ui_access_tree_clone(ui_access_tree* tree):
	if (tree == 0): return 0
	ui_access_tree* copy = ui_access_tree_new(tree.max_nodes, tree.max_text_bytes)
	for int id in tree.nodes:
		ui_access_node* n = tree.nodes[id]
		int parent_id = 0
		if (n.parent != 0): parent_id = n.parent.id
		ui_access_node* c = ui_access_add(copy, id, parent_id, n.role, n.bounds)
		if (c != 0):
			c.states = n.states
			c.actions = n.actions
			c.heading_level = n.heading_level
			c.caret = n.caret
			c.selection_start = n.selection_start
			c.selection_end = n.selection_end
			ui_access_set_text(copy, id, UI_ACCESS_NAME, n.name.data, n.name.length)
			ui_access_set_text(copy, id, UI_ACCESS_VALUE, n.value.data, n.value.length)
			ui_access_set_text(copy, id, UI_ACCESS_DESCRIPTION, n.description.data, n.description.length)
	copy.focused_id = tree.focused_id
	return copy

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
