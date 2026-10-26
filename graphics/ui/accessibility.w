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
const int UI_ACCESS_NAME = 1
const int UI_ACCESS_VALUE = 2
const int UI_ACCESS_DESCRIPTION = 3
# Live-region politeness (ui_access_node.live, ui_access_announce): how
# urgently assistive technology reports changes. Polite waits for the
# current speech; assertive interrupts it.
const int UI_ACCESS_LIVE_OFF = 0
const int UI_ACCESS_LIVE_POLITE = 1
const int UI_ACCESS_LIVE_ASSERTIVE = 2

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
	# Live regions and notifications (#465): a node with live set is a
	# live region; text added or changed in its subtree is announced at
	# that politeness without moving focus (status lines, toasts).
	int live
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
	# A one-shot announcement (ui_access_announce), consumed by the next
	# publication; announcement_live is its politeness.
	ui_access_text announcement
	int announcement_live

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

# Apply a Tab/Shift-Tab proposal through the host, updating snapshot focus
# only when accepted. The caller draws a focus ring at the resulting bounds.
int ui_access_move_focus(ui_access_tree* tree, int reverse):
	if (tree == 0): return 0
	int id = ui_access_focus_next(tree, tree.focused_id, reverse)
	if (id == 0): return 0
	if (!ui_access_dispatch(tree, id, UI_ACCESS_FOCUS, 0, 0)): return 0
	tree.focused_id = id
	return id

# Queue a one-shot announcement on the snapshot: the next publication
# speaks text at politeness live (UI_ACCESS_LIVE_POLITE or _ASSERTIVE)
# through each platform's notification channel, then clears it. A later
# call before publication replaces it. Returns 0 (and leaves the tree
# unchanged) for invalid UTF-8, an empty text or one past the text budget.
int ui_access_announce(ui_access_tree* tree, char* data, int length, int live):
	if ((tree == 0) || (length <= 0) || (data == 0) || (length > tree.max_text_bytes)): return 0
	if ((live != UI_ACCESS_LIVE_POLITE) && (live != UI_ACCESS_LIVE_ASSERTIVE)): return 0
	if (!utf8_validate_bytes(data, length)): return 0
	char* owned = cast(char*, __w_alloc(__w_size_add(length, 1)))
	for i in range(length): owned[i] = data[i]
	owned[length] = 0
	free(tree.announcement.data)
	tree.announcement.data = owned
	tree.announcement.length = length
	tree.announcement_live = live
	return 1


# Drop a pending announcement; bridges call this once they published it.
void ui_access_announcement_clear(ui_access_tree* tree):
	if (tree == 0): return
	free(tree.announcement.data)
	tree.announcement.data = 0
	tree.announcement.length = 0
	tree.announcement_live = UI_ACCESS_LIVE_OFF


# The live region n belongs to: n itself or its nearest ancestor with a
# live setting; 0 outside every live region.
ui_access_node* ui_access_live_root(ui_access_node* n):
	while (n != 0):
		if (n.live != UI_ACCESS_LIVE_OFF): return n
		n = n.parent
	return 0


# The name assistive technology reads for n: its own name, or for an
# unnamed ROW its cells' names joined by spaces (as ARIA computes a row's
# name from its content; screen readers announce a focused row by name).
# out.data is a fresh allocation the caller frees (0 for an empty name).
void ui_access_effective_name(ui_access_node* n, ui_access_text* out):
	out.data = 0
	out.length = 0
	ui_access_text* own = &n.name
	int length = own.length
	if ((n.role == UI_ACCESS_ROW) && (length == 0)):
		ui_access_node* c = n.first_child
		while (c != 0):
			if (c.name.length > 0): length = length + c.name.length + 1
			c = c.next_sibling
	if (length == 0): return
	char* joined = cast(char*, __w_alloc(__w_size_add(length, 1)))
	int at = 0
	if (own.length > 0):
		for i in range(own.length): joined[i] = own.data[i]
		at = own.length
	else:
		ui_access_node* c = n.first_child
		while (c != 0):
			if (c.name.length > 0):
				if (at > 0):
					joined[at] = ' '
					at = at + 1
				for i in range(c.name.length): joined[at + i] = c.name.data[i]
				at = at + c.name.length
			c = c.next_sibling
	joined[at] = 0
	out.data = joined
	out.length = at


int ui_access_text_same(ui_access_text* a, ui_access_text* b):
	if (a.length != b.length): return 0
	for i in range(a.length):
		if (a.data[i] != b.data[i]): return 0
	return 1

# 1 when a and b have the same effective name (ui_access_effective_name),
# so a row whose cells changed reports a name change.
int ui_access_effective_name_same(ui_access_node* a, ui_access_node* b):
	ui_access_text x
	ui_access_text y
	ui_access_effective_name(a, &x)
	ui_access_effective_name(b, &y)
	int same = ui_access_text_same(&x, &y)
	free(x.data)
	free(y.data)
	return same


int ui_access_hidden(ui_access_node* n):
	while (n != 0):
		if ((n.states & UI_ACCESS_HIDDEN) != 0): return 1
		n = n.parent
	return 0


# What a publication announces for node n of a live region, given its
# previous version was (0 when n is new to the snapshot): its name when
# n is new or its name changed, else its value when that changed
# (textboxes excepted: their edits are echoed as text changes). 0 when
# there is nothing to announce: n is outside every live region, hidden,
# or its new text is empty.
ui_access_text* ui_access_live_change(ui_access_node* n, ui_access_node* was):
	if ((ui_access_live_root(n) == 0) || ui_access_hidden(n)): return 0
	if ((was == 0) || !ui_access_text_same(&n.name, &was.name)):
		if (n.name.length > 0): return &n.name
		if (was == 0): return 0
	if ((was != 0) && (n.role != UI_ACCESS_TEXTBOX) && (n.value.length > 0) && !ui_access_text_same(&n.value, &was.value)): return &n.value
	return 0


# 1 when two snapshots would publish identically: same nodes in the same
# order with equal fields, text, bounds and focus. Lets a per-frame
# capture republish only on semantic changes.
int ui_access_tree_same(ui_access_tree* a, ui_access_tree* b):
	if ((a == 0) || (b == 0)): return a == b
	if ((a.count != b.count) || (a.focused_id != b.focused_id)): return 0
	if ((a.announcement_live != b.announcement_live) || !ui_access_text_same(&a.announcement, &b.announcement)): return 0
	ui_access_node* x = a.allocations
	ui_access_node* y = b.allocations
	while ((x != 0) && (y != 0)):
		if ((x.id != y.id) || (x.role != y.role) || (x.states != y.states) || (x.actions != y.actions) || (x.heading_level != y.heading_level) || (x.live != y.live)): return 0
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
			c.live = n.live
			ui_access_set_text(copy, id, UI_ACCESS_NAME, n.name.data, n.name.length)
			ui_access_set_text(copy, id, UI_ACCESS_VALUE, n.value.data, n.value.length)
			ui_access_set_text(copy, id, UI_ACCESS_DESCRIPTION, n.description.data, n.description.length)
	copy.focused_id = tree.focused_id
	ui_access_announce(copy, tree.announcement.data, tree.announcement.length, tree.announcement_live)
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
	free(tree.announcement.data)
	free(tree)
