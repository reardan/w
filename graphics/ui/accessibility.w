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
# A list, tab list or table whose items can be selected together
# (#863): bridges then offer adding and removing items, select all and
# clear, through UI_ACCESS_SELECT.
const int UI_ACCESS_MULTISELECTABLE = 128
# A header cell (#863): in a table's data row it is that row's header;
# on a ROW it marks the column-header row explicitly (see
# graphics.ui.accessibility_table).
const int UI_ACCESS_HEADER = 256
const int UI_ACCESS_ACTIVATE = 1
const int UI_ACCESS_FOCUS = 2
const int UI_ACCESS_SET_VALUE = 4
const int UI_ACCESS_TOGGLE = 8
# Move the caret / select text in a textbox. The payload is the ASCII
# "anchor active" pair of character offsets built by
# ui_access_dispatch_selection (see there).
const int UI_ACCESS_SET_SELECTION = 16
# Select or deselect an item of a selection container (#863). The
# payload is ASCII "add", "remove" or "only" (ui_access_select_mode);
# a container without UI_ACCESS_MULTISELECTABLE only ever gets "only".
const int UI_ACCESS_SELECT = 32
# Replace a text node's selections (#863): the payload is the primary
# "anchor active" pair followed by "start end" pairs of the further
# selections, all space separated (ui_access_selections_format).
const int UI_ACCESS_SET_SELECTIONS = 64
const int UI_ACCESS_SELECT_ADD = 1
const int UI_ACCESS_SELECT_REMOVE = 2
const int UI_ACCESS_SELECT_ONLY = 3
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


# Text attributes (#863) of a run of a text node's value: what screen
# readers report as font, size, weight and colours. Unknown values are
# 0 (size, weight), -1 (colours) or an empty family.
struct ui_access_text_attrs:
	ui_access_text family
	int size                    # points
	int weight                  # CSS weight, 100..900 (400 normal, 700 bold)
	int italic
	int underline
	int fg                      # 0xRRGGBB
	int bg


# Characters [start, end) of the value with attrs instead of the
# node's default attributes.
struct ui_access_text_run:
	int start
	int end
	ui_access_text_attrs attrs

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
	# Text caret and selection (#465), in characters (code points) of
	# value: caret is -1 when the node shows none; the selection is
	# [selection_start, selection_end), empty when they are equal.
	# Set them with ui_access_set_selection.
	int caret
	int selection_start
	int selection_end
	# Further selections (#863), pairs of [start, end) character
	# offsets after the primary one above (ui_access_add_selection).
	int* selections
	int selection_count
	# Glyph geometry (#863): one box per character of value, in the
	# snapshot's coordinates (ui_access_set_char_boxes); 0 when the
	# node publishes none and bridges fall back to its bounds.
	ui_rect* char_boxes
	int char_box_count
	# Text attributes (#863): the default for the whole value and runs
	# that differ from it, in order (ui_access_default_attrs,
	# ui_access_add_attr_run).
	ui_access_text_attrs* attrs
	ui_access_text_run* runs
	int run_count
	# Table cell spans (#863): rows and columns the cell covers; 0
	# counts as 1.
	int row_span
	int col_span
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


# The mode of a UI_ACCESS_SELECT payload: UI_ACCESS_SELECT_ADD,
# _REMOVE or _ONLY, 0 when it is none of "add", "remove", "only".
int ui_access_select_mode(char* data, int length):
	if ((length == 3) && (data[0] == 'a') && (data[1] == 'd') && (data[2] == 'd')): return UI_ACCESS_SELECT_ADD
	if ((length == 4) && (data[0] == 'o') && (data[1] == 'n') && (data[2] == 'l') && (data[3] == 'y')): return UI_ACCESS_SELECT_ONLY
	if (length == 6):
		char* word = c"remove"
		for i in range(6):
			if (data[i] != word[i]): return 0
		return UI_ACCESS_SELECT_REMOVE
	return 0


char* ui_access_select_word(int mode):
	if (mode == UI_ACCESS_SELECT_ADD): return c"add"
	if (mode == UI_ACCESS_SELECT_REMOVE): return c"remove"
	return c"only"


# Parse a SET_SELECTIONS payload: an even number (2 or more) of decimal
# numbers separated by single spaces. Returns the number of pairs (0
# when malformed) and stores up to cap pairs' numbers into out.
int ui_access_selections_parse(char* data, int length, int* out, int cap):
	int values = 0
	int current = 0
	int digits = 0
	for i in range(length + 1):
		if ((i == length) || (data[i] == ' ')):
			if (digits == 0): return 0
			if ((out != 0) && (values < cap * 2)): out[values] = current
			values = values + 1
			current = 0
			digits = 0
		else:
			if ((data[i] < '0') || (data[i] > '9') || (digits >= 9)): return 0
			current = current * 10 + (data[i] - '0')
			digits = digits + 1
	if ((values < 2) || ((values % 2) != 0)): return 0
	return values / 2


# Encode count pairs of numbers into a SET_SELECTIONS payload (out has
# room for 24 bytes per pair); returns its length.
int ui_access_selections_format(char* out, int* pairs, int count):
	int n = 0
	for k in range(count):
		if (k > 0):
			out[n] = ' '
			n = n + 1
		n = n + ui_access_selection_format(&out[n], pairs[k * 2], pairs[k * 2 + 1])
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
	if ((action != UI_ACCESS_ACTIVATE) && (action != UI_ACCESS_FOCUS) && (action != UI_ACCESS_SET_VALUE) && (action != UI_ACCESS_TOGGLE) && (action != UI_ACCESS_SET_SELECTION) && (action != UI_ACCESS_SELECT) && (action != UI_ACCESS_SET_SELECTIONS)): return 0
	if ((node.actions & action) == 0): return 0
	if (ui_access_inert(node)): return 0
	if ((action == UI_ACCESS_SET_VALUE) && ((node.states & UI_ACCESS_READONLY) != 0)): return 0
	if ((length < 0) || (length > tree.max_text_bytes) || ((data == 0) && (length > 0))): return 0
	if (!utf8_validate_bytes(data, length)): return 0
	# Selection offsets are not checked against the node's value: a
	# request can follow an edit queued just before it, so they count
	# characters of a text the snapshot has not seen yet. The widget
	# clamps them to its text when it applies them.
	if (action == UI_ACCESS_SET_SELECTION):
		int anchor = 0
		int active = 0
		if (!ui_access_selection_parse(data, length, &anchor, &active)): return 0
	if (action == UI_ACCESS_SET_SELECTIONS):
		if (ui_access_selections_parse(data, length, 0, 0) == 0): return 0
	if (action == UI_ACCESS_SELECT):
		int mode = ui_access_select_mode(data, length)
		if (mode == 0): return 0
		# Only a multi-selection container's items add or remove.
		int multiple = (node.parent != 0) && ((node.parent.states & UI_ACCESS_MULTISELECTABLE) != 0)
		if ((mode != UI_ACCESS_SELECT_ONLY) && !multiple): return 0
	return tree.action(tree.context, id, action, data, length)


# Request a caret move (anchor == active) or a selection of characters
# between anchor and active, with the caret at active, through
# ui_access_dispatch.
int ui_access_dispatch_selection(ui_access_tree* tree, int id, int anchor, int active):
	if ((anchor < 0) || (active < 0)): return 0
	char[32] payload
	int n = ui_access_selection_format(&payload[0], anchor, active)
	return ui_access_dispatch(tree, id, UI_ACCESS_SET_SELECTION, &payload[0], n)

# Ask the host to select (add), deselect (remove) or exclusively select
# (only) item id through ui_access_dispatch.
int ui_access_dispatch_select(ui_access_tree* tree, int id, int mode):
	char* word = ui_access_select_word(mode)
	return ui_access_dispatch(tree, id, UI_ACCESS_SELECT, word, strlen(word))


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


# Add a further selected range [start, end) of characters to a text
# node that already has its primary selection (ui_access_set_selection).
# Empty or out-of-range ranges leave the node unchanged and return 0.
int ui_access_add_selection(ui_access_tree* tree, int id, int start, int end):
	ui_access_node* node = ui_access_find(tree, id)
	if (node == 0): return 0
	int count = ui_access_char_count(node.value.data, node.value.length)
	if ((start < 0) || (end <= start) || (end > count) || (node.selection_count >= 64)): return 0
	int* grown = cast(int*, malloc((node.selection_count + 1) * 2 * __word_size__))
	for i in range(node.selection_count * 2): grown[i] = node.selections[i]
	grown[node.selection_count * 2] = start
	grown[node.selection_count * 2 + 1] = end
	free(cast(char*, node.selections))
	node.selections = grown
	node.selection_count = node.selection_count + 1
	return 1


# Selected ranges of a text node: the primary one when it is not empty,
# then the further ones.
int ui_access_selection_total(ui_access_node* node):
	if (node == 0): return 0
	return ui_access_has_selection(node) + node.selection_count


# Selected range k (ui_access_selection_total) into start and end; 0
# when there is none.
int ui_access_selection_range(ui_access_node* node, int k, int* start, int* end):
	if ((node == 0) || (k < 0) || (k >= ui_access_selection_total(node))): return 0
	if (ui_access_has_selection(node)):
		if (k == 0):
			start[0] = node.selection_start
			end[0] = node.selection_end
			return 1
		k = k - 1
	start[0] = node.selections[k * 2]
	end[0] = node.selections[k * 2 + 1]
	return 1


# Glyph geometry: boxes[0..count) are the boxes of the value's count
# characters, in the snapshot's coordinates (set the value first; count
# must match it). A newline's box is where the caret sits at the end of
# its line. Returns 0 and leaves the node unchanged otherwise.
int ui_access_set_char_boxes(ui_access_tree* tree, int id, ui_rect* boxes, int count):
	ui_access_node* node = ui_access_find(tree, id)
	if ((node == 0) || (count < 0) || ((boxes == 0) && (count > 0))): return 0
	if (count != ui_access_char_count(node.value.data, node.value.length)): return 0
	ui_rect* owned = cast(ui_rect*, malloc((count + 1) * sizeof(ui_rect)))
	for i in range(count): owned[i] = boxes[i]
	free(cast(char*, node.char_boxes))
	node.char_boxes = owned
	node.char_box_count = count
	return 1


void ui_access_attrs_init(ui_access_text_attrs* a):
	a.family.data = 0
	a.family.length = 0
	a.size = 0
	a.weight = 0
	a.italic = 0
	a.underline = 0
	a.fg = 0 - 1
	a.bg = 0 - 1


# Set the font family name (UTF-8, at most 256 bytes); 0 when invalid.
int ui_access_attrs_set_family(ui_access_text_attrs* a, char* data, int length):
	if ((a == 0) || (length < 0) || (length > 256) || ((data == 0) && (length > 0))): return 0
	if (!utf8_validate_bytes(data, length)): return 0
	char* owned = cast(char*, malloc(length + 1))
	for i in range(length): owned[i] = data[i]
	owned[length] = 0
	free(a.family.data)
	a.family.data = owned
	a.family.length = length
	return 1


void ui_access_attrs_copy(ui_access_text_attrs* to, ui_access_text_attrs* from):
	free(to.family.data)
	to[0] = from[0]
	to.family.data = 0
	to.family.length = 0
	ui_access_attrs_set_family(to, from.family.data, from.family.length)


int ui_access_attrs_same(ui_access_text_attrs* a, ui_access_text_attrs* b):
	if ((a.size != b.size) || (a.weight != b.weight) || (a.italic != b.italic) || (a.underline != b.underline) || (a.fg != b.fg) || (a.bg != b.bg)): return 0
	return ui_access_text_same(&a.family, &b.family)


# The default text attributes of node id, created (all unknown) on
# first use for the caller to fill; 0 when there is no such node.
ui_access_text_attrs* ui_access_default_attrs(ui_access_tree* tree, int id):
	ui_access_node* node = ui_access_find(tree, id)
	if (node == 0): return 0
	if (node.attrs == 0):
		node.attrs = new ui_access_text_attrs()
		ui_access_attrs_init(node.attrs)
	return node.attrs


# Add a run of characters [start, end) with their own attributes,
# starting as a copy of the defaults, for the caller to change. Runs are
# added in order and do not overlap; anything else returns 0.
ui_access_text_attrs* ui_access_add_attr_run(ui_access_tree* tree, int id, int start, int end):
	ui_access_node* node = ui_access_find(tree, id)
	if ((node == 0) || (start < 0) || (end <= start)): return 0
	if (end > ui_access_char_count(node.value.data, node.value.length)): return 0
	if ((node.run_count > 0) && (node.runs[node.run_count - 1].end > start)): return 0
	ui_access_text_run* grown = cast(ui_access_text_run*, malloc((node.run_count + 1) * sizeof(ui_access_text_run)))
	for i in range(node.run_count): grown[i] = node.runs[i]
	free(cast(char*, node.runs))
	node.runs = grown
	ui_access_text_run* run = &node.runs[node.run_count]
	node.run_count = node.run_count + 1
	run.start = start
	run.end = end
	ui_access_attrs_init(&run.attrs)
	if (node.attrs != 0): ui_access_attrs_copy(&run.attrs, node.attrs)
	return &run.attrs


# Copy src's #863 text data (boxes, attributes, further selections) and
# table spans onto dst in tree.
void ui_access_copy_depth(ui_access_tree* tree, ui_access_node* dst, ui_access_node* src):
	dst.row_span = src.row_span
	dst.col_span = src.col_span
	for k in range(src.selection_count): ui_access_add_selection(tree, dst.id, src.selections[k * 2], src.selections[k * 2 + 1])
	if (src.char_boxes != 0): ui_access_set_char_boxes(tree, dst.id, src.char_boxes, src.char_box_count)
	if (src.attrs != 0): ui_access_attrs_copy(ui_access_default_attrs(tree, dst.id), src.attrs)
	for k in range(src.run_count):
		ui_access_text_run* run = &src.runs[k]
		ui_access_text_attrs* a = ui_access_add_attr_run(tree, dst.id, run.start, run.end)
		if (a != 0): ui_access_attrs_copy(a, &run.attrs)


# 1 when two nodes carry the same #863 text data and spans.
int ui_access_depth_same(ui_access_node* x, ui_access_node* y):
	if ((x.row_span != y.row_span) || (x.col_span != y.col_span)): return 0
	if ((x.selection_count != y.selection_count) || (x.char_box_count != y.char_box_count) || (x.run_count != y.run_count)): return 0
	if ((x.char_boxes == 0) != (y.char_boxes == 0)): return 0
	if ((x.attrs == 0) != (y.attrs == 0)): return 0
	for i in range(x.selection_count * 2):
		if (x.selections[i] != y.selections[i]): return 0
	for i in range(x.char_box_count):
		ui_rect a = x.char_boxes[i]
		ui_rect b = y.char_boxes[i]
		if ((a.x != b.x) || (a.y != b.y) || (a.w != b.w) || (a.h != b.h)): return 0
	if ((x.attrs != 0) && !ui_access_attrs_same(x.attrs, y.attrs)): return 0
	for i in range(x.run_count):
		if ((x.runs[i].start != y.runs[i].start) || (x.runs[i].end != y.runs[i].end) || !ui_access_attrs_same(&x.runs[i].attrs, &y.runs[i].attrs)): return 0
	return 1


void ui_access_free_depth(ui_access_node* n):
	free(cast(char*, n.selections))
	free(cast(char*, n.char_boxes))
	if (n.attrs != 0): free(n.attrs.family.data)
	free(cast(char*, n.attrs))
	for i in range(n.run_count): free(n.runs[i].attrs.family.data)
	free(cast(char*, n.runs))


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
		if ((x.caret != y.caret) || (x.selection_start != y.selection_start) || (x.selection_end != y.selection_end)): return 0
		int xp = 0
		int yp = 0
		if (x.parent != 0): xp = x.parent.id
		if (y.parent != 0): yp = y.parent.id
		if (xp != yp): return 0
		if ((x.bounds.x != y.bounds.x) || (x.bounds.y != y.bounds.y) || (x.bounds.w != y.bounds.w) || (x.bounds.h != y.bounds.h)): return 0
		if (!ui_access_text_same(&x.name, &y.name) || !ui_access_text_same(&x.value, &y.value) || !ui_access_text_same(&x.description, &y.description)): return 0
		if (!ui_access_depth_same(x, y)): return 0
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
			c.caret = n.caret
			c.selection_start = n.selection_start
			c.selection_end = n.selection_end
			ui_access_set_text(copy, id, UI_ACCESS_NAME, n.name.data, n.name.length)
			ui_access_set_text(copy, id, UI_ACCESS_VALUE, n.value.data, n.value.length)
			ui_access_set_text(copy, id, UI_ACCESS_DESCRIPTION, n.description.data, n.description.length)
			ui_access_copy_depth(copy, c, n)
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
		ui_access_free_depth(n)
		free(n)
		n = next
	map_free[int, ui_access_node*](tree.nodes)
	free(tree.announcement.data)
	free(tree)
