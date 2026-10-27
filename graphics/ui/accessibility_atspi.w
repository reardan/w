/*
graphics.ui.accessibility_atspi: publishes semantic snapshots
(graphics.ui.accessibility) to Linux assistive technology over AT-SPI 2 —
the D-Bus protocol Orca and other screen readers use — with the
pure-W D-Bus client in lib/dbus.w. No libatspi, ATK or GLib.

	ui_atspi_bridge* bridge = ui_access_atspi_open(c"My App")
	... each frame, after ui_end (see docs/projects/accessibility.md):
	ui_access_atspi_dispatch(bridge, published)   # answer queries, apply actions
	if (snapshot changed): ui_access_atspi_publish(bridge, fresh)
	...
	ui_access_atspi_close(bridge)

The bridge connects to the accessibility bus ($AT_SPI_BUS_ADDRESS, else
the address the session bus's org.a11y.Bus service reports), embeds the
application root in the AT-SPI registry's desktop, and exports one
object per snapshot node under /org/a11y/atspi/accessible/<id>, below an
application root at /org/a11y/atspi/accessible/root. Publication copies
the snapshot, so queries are answered from the published state however
the application manages its own trees. Publishing again emits the
changes as AT-SPI events (focus, checked/expanded/selected states,
names, children added and removed) so caching clients stay current, and
live-region changes and the snapshot's announcement as
Object:Announcement events, which Orca speaks wherever focus is.

Actions arrive as Action.DoAction, Component.GrabFocus and
EditableText calls. They are queued (at most 64, values within the
snapshot's text budget) and applied by ui_access_atspi_dispatch through
ui_access_dispatch, which revalidates them against the application's
current tree, exactly as the Cocoa and web bridges do.

Interfaces: Accessible, Application (root), Component, Action, Text
(with the caret and one selection) and EditableText (textboxes) and
Value (progress bars). Geometry is the
snapshot's logical window coordinates; screen coordinates add the origin
set by ui_access_atspi_set_origin.
*/
import lib.lib
import lib.env
import lib.dbus
import graphics.ui.accessibility
import graphics.ui.accessibility_table


const int ui_atspi_max_requests = 64

# AT-SPI 2 role and state numbers (atspi-constants.h).
const int ATSPI_ROLE_CHECK_BOX = 7
const int ATSPI_ROLE_COMBO_BOX = 11
const int ATSPI_ROLE_DIALOG = 16
const int ATSPI_ROLE_FRAME = 23
const int ATSPI_ROLE_IMAGE = 27
const int ATSPI_ROLE_LABEL = 29
const int ATSPI_ROLE_LIST = 31
const int ATSPI_ROLE_LIST_ITEM = 32
const int ATSPI_ROLE_PAGE_TAB = 37
const int ATSPI_ROLE_PAGE_TAB_LIST = 38
const int ATSPI_ROLE_PANEL = 39
const int ATSPI_ROLE_PROGRESS_BAR = 42
const int ATSPI_ROLE_PUSH_BUTTON = 43
const int ATSPI_ROLE_RADIO_BUTTON = 44
const int ATSPI_ROLE_TABLE = 55
const int ATSPI_ROLE_TABLE_CELL = 56
const int ATSPI_ROLE_TABLE_COLUMN_HEADER = 57
const int ATSPI_ROLE_TOGGLE_BUTTON = 62
const int ATSPI_ROLE_APPLICATION = 75
const int ATSPI_ROLE_ENTRY = 79
const int ATSPI_ROLE_DOCUMENT_FRAME = 82
const int ATSPI_ROLE_HEADING = 83
const int ATSPI_ROLE_LINK = 88
const int ATSPI_ROLE_TABLE_ROW = 90

const int ATSPI_STATE_ACTIVE = 1
const int ATSPI_STATE_CHECKED = 4
const int ATSPI_STATE_COLLAPSED = 5
const int ATSPI_STATE_DEFUNCT = 6
const int ATSPI_STATE_EDITABLE = 7
const int ATSPI_STATE_ENABLED = 8
const int ATSPI_STATE_EXPANDABLE = 9
const int ATSPI_STATE_EXPANDED = 10
const int ATSPI_STATE_FOCUSABLE = 11
const int ATSPI_STATE_FOCUSED = 12
const int ATSPI_STATE_MODAL = 16
const int ATSPI_STATE_PRESSED = 20
const int ATSPI_STATE_SELECTABLE = 22
const int ATSPI_STATE_SELECTED = 23
const int ATSPI_STATE_SENSITIVE = 24
const int ATSPI_STATE_SHOWING = 25
const int ATSPI_STATE_SINGLE_LINE = 26
const int ATSPI_STATE_VISIBLE = 30
const int ATSPI_STATE_SELECTABLE_TEXT = 38
const int ATSPI_STATE_CHECKABLE = 41
const int ATSPI_STATE_HAS_POPUP = 42
const int ATSPI_STATE_READ_ONLY = 43


struct ui_atspi_request:
	int id
	int action
	char* value
	int length


struct ui_atspi_bridge:
	dbus_conn* bus
	ui_access_tree* published   # owned copy of the last publication
	char* app_name
	char* desktop_name          # the registry's desktop, once embedded
	char* desktop_path
	int embed_serial
	int app_id
	int origin_x
	int origin_y
	ui_atspi_request[64] queue
	int queued
	dbus_buf scratch


char* ui_atspi_root_path():
	return c"/org/a11y/atspi/accessible/root"


char* ui_atspi_null_path():
	return c"/org/a11y/atspi/null"


# "/org/a11y/atspi/accessible/<id>" into out (64 bytes).
char* ui_atspi_node_path(char* out, int id):
	char* prefix = c"/org/a11y/atspi/accessible/"
	int n = strlen(prefix)
	for i in range(n): out[i] = prefix[i]
	char[24] digits
	int nd = 0
	if (id <= 0):
		digits[0] = '0'
		nd = 1
	while (id > 0):
		digits[nd] = '0' + id % 10
		id = id / 10
		nd = nd + 1
	for i in range(nd): out[n + i] = digits[nd - 1 - i]
	out[n + nd] = 0
	return out


# The node id a path names: >0 for a node, 0 for the application root,
# -1 for anything else.
int ui_atspi_path_id(char* path):
	char* prefix = c"/org/a11y/atspi/accessible/"
	int n = strlen(prefix)
	for i in range(n):
		if (path[i] != prefix[i]): return 0 - 1
	if (strcmp(&path[n], c"root") == 0): return 0
	int id = 0
	int i = n
	if (path[i] == 0): return 0 - 1
	# Up to 2^31 - 1 on every word size: widget snapshots number their
	# document root ui_access_root_id (2^30).
	while (path[i] != 0):
		if ((path[i] < '0') || (path[i] > '9')): return 0 - 1
		if (id > (2147483647 - (path[i] - '0')) / 10): return 0 - 1
		id = id * 10 + (path[i] - '0')
		i = i + 1
	if (id <= 0): return 0 - 1
	return id

/* Tables and selection: graphics.ui.accessibility_table, shared with the
UI Automation bridge so both describe the same rows, headers and
selections. Selection child indices count every child, as
GetChildAtIndex does. */

int ui_atspi_is_header_row(ui_access_node* row):
	return ui_access_is_header_row(row)


ui_access_node* ui_atspi_header_row(ui_access_node* table):
	return ui_access_header_row(table)


int ui_atspi_is_data_row(ui_access_node* c):
	return ui_access_is_data_row(c)


int ui_atspi_table_rows(ui_access_node* table):
	return ui_access_table_rows(table)


ui_access_node* ui_atspi_table_row(ui_access_node* table, int index):
	return ui_access_table_row(table, index)


ui_access_node* ui_atspi_row_cell(ui_access_node* row, int col):
	return ui_access_row_cell(row, col)


int ui_atspi_table_columns(ui_access_node* table):
	return ui_access_table_columns(table)


int ui_atspi_cell_position(ui_access_node* n, int* row, int* col):
	return ui_access_cell_position(n, row, col)


int ui_atspi_has_table(ui_access_node* n):
	return (n != 0) && (n.role == UI_ACCESS_TABLE)


int ui_atspi_has_table_cell(ui_access_node* n):
	int r = 0
	int c = 0
	return ui_access_cell_position(n, &r, &c)


int ui_atspi_has_selection(ui_access_node* n):
	return ui_access_is_selection_container(n)


int ui_atspi_selectable_child(ui_access_node* c):
	return ui_access_selectable_child(c)


int ui_atspi_selected_count(ui_access_node* n):
	return ui_access_selected_count(n)


ui_access_node* ui_atspi_selected_at(ui_access_node* n, int index):
	return ui_access_selected_at(n, index)


int ui_atspi_selection_same(ui_access_node* a, ui_access_node* b):
	return ui_access_selection_same(a, b)


int ui_atspi_role(ui_access_node* n):
	int r = n.role
	if (r == UI_ACCESS_DOCUMENT):
		if (n.parent == 0): return ATSPI_ROLE_FRAME
		return ATSPI_ROLE_DOCUMENT_FRAME
	if (r == UI_ACCESS_GROUP): return ATSPI_ROLE_PANEL
	if (r == UI_ACCESS_TEXT): return ATSPI_ROLE_LABEL
	if (r == UI_ACCESS_HEADING): return ATSPI_ROLE_HEADING
	if (r == UI_ACCESS_LINK): return ATSPI_ROLE_LINK
	if (r == UI_ACCESS_BUTTON): return ATSPI_ROLE_PUSH_BUTTON
	if (r == UI_ACCESS_CHECKBOX): return ATSPI_ROLE_CHECK_BOX
	if (r == UI_ACCESS_TEXTBOX): return ATSPI_ROLE_ENTRY
	if (r == UI_ACCESS_IMAGE): return ATSPI_ROLE_IMAGE
	if (r == UI_ACCESS_LIST): return ATSPI_ROLE_LIST
	if (r == UI_ACCESS_LIST_ITEM): return ATSPI_ROLE_LIST_ITEM
	if (r == UI_ACCESS_TABLE): return ATSPI_ROLE_TABLE
	if (r == UI_ACCESS_ROW): return ATSPI_ROLE_TABLE_ROW
	if (r == UI_ACCESS_CELL):
		if (ui_atspi_is_header_row(n.parent)): return ATSPI_ROLE_TABLE_COLUMN_HEADER
		return ATSPI_ROLE_TABLE_CELL
	if (r == UI_ACCESS_RADIO): return ATSPI_ROLE_RADIO_BUTTON
	# AT-SPI 2.52 has no switch role; a toggle button with CHECKED and
	# PRESSED is what toolkits publish for one.
	if (r == UI_ACCESS_SWITCH): return ATSPI_ROLE_TOGGLE_BUTTON
	if (r == UI_ACCESS_COMBOBOX): return ATSPI_ROLE_COMBO_BOX
	if (r == UI_ACCESS_TAB_LIST): return ATSPI_ROLE_PAGE_TAB_LIST
	if (r == UI_ACCESS_TAB): return ATSPI_ROLE_PAGE_TAB
	if (r == UI_ACCESS_PROGRESS): return ATSPI_ROLE_PROGRESS_BAR
	if (r == UI_ACCESS_DIALOG): return ATSPI_ROLE_DIALOG
	return ATSPI_ROLE_PANEL


char* ui_atspi_role_name(int role):
	if (role == ATSPI_ROLE_FRAME): return c"frame"
	if (role == ATSPI_ROLE_DOCUMENT_FRAME): return c"document frame"
	if (role == ATSPI_ROLE_LABEL): return c"label"
	if (role == ATSPI_ROLE_HEADING): return c"heading"
	if (role == ATSPI_ROLE_LINK): return c"link"
	if (role == ATSPI_ROLE_PUSH_BUTTON): return c"push button"
	if (role == ATSPI_ROLE_CHECK_BOX): return c"check box"
	if (role == ATSPI_ROLE_ENTRY): return c"entry"
	if (role == ATSPI_ROLE_IMAGE): return c"image"
	if (role == ATSPI_ROLE_LIST): return c"list"
	if (role == ATSPI_ROLE_LIST_ITEM): return c"list item"
	if (role == ATSPI_ROLE_TABLE): return c"table"
	if (role == ATSPI_ROLE_TABLE_ROW): return c"table row"
	if (role == ATSPI_ROLE_TABLE_CELL): return c"table cell"
	if (role == ATSPI_ROLE_TABLE_COLUMN_HEADER): return c"table column header"
	if (role == ATSPI_ROLE_RADIO_BUTTON): return c"radio button"
	if (role == ATSPI_ROLE_TOGGLE_BUTTON): return c"toggle button"
	if (role == ATSPI_ROLE_COMBO_BOX): return c"combo box"
	if (role == ATSPI_ROLE_PAGE_TAB_LIST): return c"page tab list"
	if (role == ATSPI_ROLE_PAGE_TAB): return c"page tab"
	if (role == ATSPI_ROLE_PROGRESS_BAR): return c"progress bar"
	if (role == ATSPI_ROLE_DIALOG): return c"dialog"
	if (role == ATSPI_ROLE_APPLICATION): return c"application"
	return c"panel"


# The AT-SPI state bits of a node (two 32-bit words), focused_id being
# its snapshot's focus.
void ui_atspi_states_for(ui_access_node* n, int focused_id, int* lo, int* hi):
	int s = 0
	int t = 0
	int inert = ui_access_inert(n)
	int hidden = 0
	ui_access_node* p = n
	while (p != 0):
		if ((p.states & UI_ACCESS_HIDDEN) != 0): hidden = 1
		p = p.parent
	if (inert == 0): s = s | (1 << ATSPI_STATE_ENABLED) | (1 << ATSPI_STATE_SENSITIVE)
	if (hidden == 0): s = s | (1 << ATSPI_STATE_VISIBLE) | (1 << ATSPI_STATE_SHOWING)
	if (((n.states & UI_ACCESS_FOCUSABLE) != 0) && (inert == 0)): s = s | (1 << ATSPI_STATE_FOCUSABLE)
	if ((focused_id == n.id) && (inert == 0)): s = s | (1 << ATSPI_STATE_FOCUSED)
	int role = n.role
	if ((role == UI_ACCESS_CHECKBOX) || (role == UI_ACCESS_RADIO) || (role == UI_ACCESS_SWITCH)):
		t = t | (1 << (ATSPI_STATE_CHECKABLE - 32))
		if ((n.states & UI_ACCESS_CHECKED) != 0):
			s = s | (1 << ATSPI_STATE_CHECKED)
			if (role == UI_ACCESS_SWITCH): s = s | (1 << ATSPI_STATE_PRESSED)
	if (ui_atspi_selectable_child(n)): s = s | (1 << ATSPI_STATE_SELECTABLE)
	if ((n.states & UI_ACCESS_SELECTED) != 0): s = s | (1 << ATSPI_STATE_SELECTED)
	if (role == UI_ACCESS_COMBOBOX):
		s = s | (1 << ATSPI_STATE_EXPANDABLE)
		t = t | (1 << (ATSPI_STATE_HAS_POPUP - 32))
		if ((n.states & UI_ACCESS_EXPANDED) == 0): s = s | (1 << ATSPI_STATE_COLLAPSED)
	if ((n.states & UI_ACCESS_EXPANDED) != 0): s = s | (1 << ATSPI_STATE_EXPANDABLE) | (1 << ATSPI_STATE_EXPANDED)
	if (role == UI_ACCESS_TEXTBOX):
		if (((n.states & UI_ACCESS_READONLY) == 0) && ((n.actions & UI_ACCESS_SET_VALUE) != 0)): s = s | (1 << ATSPI_STATE_EDITABLE)
		else: t = t | (1 << (ATSPI_STATE_READ_ONLY - 32))
		if ((n.actions & UI_ACCESS_SET_SELECTION) != 0): t = t | (1 << (ATSPI_STATE_SELECTABLE_TEXT - 32))
	if (role == UI_ACCESS_DIALOG): s = s | (1 << ATSPI_STATE_MODAL)
	if ((n.parent == 0) && (role == UI_ACCESS_DOCUMENT)): s = s | (1 << ATSPI_STATE_ACTIVE)
	lo[0] = s
	hi[0] = t


void ui_atspi_states(ui_atspi_bridge* b, ui_access_node* n, int* lo, int* hi):
	ui_atspi_states_for(n, b.published.focused_id, lo, hi)


# The nick AT-SPI events use for state number k (0 for ones never sent).
char* ui_atspi_state_nick(int k):
	if (k == ATSPI_STATE_ACTIVE): return c"active"
	if (k == ATSPI_STATE_CHECKED): return c"checked"
	if (k == ATSPI_STATE_COLLAPSED): return c"collapsed"
	if (k == ATSPI_STATE_EDITABLE): return c"editable"
	if (k == ATSPI_STATE_ENABLED): return c"enabled"
	if (k == ATSPI_STATE_EXPANDABLE): return c"expandable"
	if (k == ATSPI_STATE_EXPANDED): return c"expanded"
	if (k == ATSPI_STATE_FOCUSABLE): return c"focusable"
	if (k == ATSPI_STATE_MODAL): return c"modal"
	if (k == ATSPI_STATE_PRESSED): return c"pressed"
	if (k == ATSPI_STATE_SELECTABLE): return c"selectable"
	if (k == ATSPI_STATE_SELECTED): return c"selected"
	if (k == ATSPI_STATE_SENSITIVE): return c"sensitive"
	if (k == ATSPI_STATE_SHOWING): return c"showing"
	if (k == ATSPI_STATE_VISIBLE): return c"visible"
	if (k == ATSPI_STATE_CHECKABLE): return c"checkable"
	if (k == ATSPI_STATE_SELECTABLE_TEXT): return c"selectable-text"
	if (k == ATSPI_STATE_HAS_POPUP): return c"has-popup"
	if (k == ATSPI_STATE_READ_ONLY): return c"read-only"
	return 0


/* Text offsets: AT-SPI counts characters (code points). The snapshot's
text is validated UTF-8, so continuation bytes are the only ones not
starting a character. */

int ui_atspi_char_count(ui_access_text* t):
	int count = 0
	for i in range(t.length):
		if ((t.data[i] & 192) != 128): count = count + 1
	return count


# Byte offset of character k (clamped to the text's ends).
int ui_atspi_char_byte(ui_access_text* t, int k):
	if (k <= 0): return 0
	int count = 0
	for i in range(t.length):
		if ((t.data[i] & 192) != 128):
			if (count == k): return i
			count = count + 1
	return t.length


/* Writers for the shapes AT-SPI replies are made of. */

void ui_atspi_put_ref(ui_atspi_bridge* b, dbus_buf* out, int id):
	char[64] path
	dbus_put_struct(out)
	if (id < 0):
		dbus_put_string(out, c"")
		dbus_put_path(out, ui_atspi_null_path())
		return
	dbus_put_string(out, b.bus.unique_name)
	if (id == 0): dbus_put_path(out, ui_atspi_root_path())
	else: dbus_put_path(out, ui_atspi_node_path(&path[0], id))


# The parent reference: the desktop for the application root, the
# application root for the snapshot root.
void ui_atspi_put_parent(ui_atspi_bridge* b, dbus_buf* out, ui_access_node* n):
	if (n == 0):
		if (b.desktop_name != 0):
			dbus_put_struct(out)
			dbus_put_string(out, b.desktop_name)
			dbus_put_path(out, b.desktop_path)
		else: ui_atspi_put_ref(b, out, 0 - 1)
		return
	if (n.parent == 0): ui_atspi_put_ref(b, out, 0)
	else: ui_atspi_put_ref(b, out, n.parent.id)


int ui_atspi_child_count(ui_atspi_bridge* b, ui_access_node* n):
	if (n == 0):
		if ((b.published != 0) && (b.published.root != 0)): return 1
		return 0
	int count = 0
	ui_access_node* c = n.first_child
	while (c != 0):
		count = count + 1
		c = c.next_sibling
	return count


ui_access_node* ui_atspi_child_at(ui_atspi_bridge* b, ui_access_node* n, int index):
	if (n == 0):
		if ((index == 0) && (b.published != 0)): return b.published.root
		return 0
	ui_access_node* c = n.first_child
	int i = 0
	while ((c != 0) && (i < index)):
		c = c.next_sibling
		i = i + 1
	if (index < 0): return 0
	return c


int ui_atspi_index_in_parent(ui_access_node* n):
	if (n == 0): return 0 - 1
	if (n.parent == 0): return 0
	int i = 0
	ui_access_node* c = n.parent.first_child
	while ((c != 0) && (c != n)):
		c = c.next_sibling
		i = i + 1
	return i


int ui_atspi_has_action(ui_access_node* n):
	return (n != 0) && ((n.actions & (UI_ACCESS_ACTIVATE | UI_ACCESS_TOGGLE)) != 0)


int ui_atspi_has_text(ui_access_node* n):
	return (n != 0) && (n.role == UI_ACCESS_TEXTBOX)


int ui_atspi_has_editable(ui_access_node* n):
	return ui_atspi_has_text(n) && ((n.actions & UI_ACCESS_SET_VALUE) != 0) && ((n.states & UI_ACCESS_READONLY) == 0)


# The caret's character offset; a text without one reports 0.
int ui_atspi_caret(ui_access_node* n):
	if (n.caret < 0): return 0
	return n.caret


int ui_atspi_has_value(ui_access_node* n):
	return (n != 0) && (n.role == UI_ACCESS_PROGRESS)


# Action i of a node: ACTIVATE first, then TOGGLE, or 0.
int ui_atspi_action_at(ui_access_node* n, int i):
	int k = 0
	if ((n.actions & UI_ACCESS_ACTIVATE) != 0):
		if (i == k): return UI_ACCESS_ACTIVATE
		k = k + 1
	if ((n.actions & UI_ACCESS_TOGGLE) != 0):
		if (i == k): return UI_ACCESS_TOGGLE
	return 0


int ui_atspi_action_count(ui_access_node* n):
	int k = 0
	if ((n.actions & UI_ACCESS_ACTIVATE) != 0): k = k + 1
	if ((n.actions & UI_ACCESS_TOGGLE) != 0): k = k + 1
	return k


char* ui_atspi_action_name(int action):
	if (action == UI_ACCESS_TOGGLE): return c"toggle"
	return c"click"


# The progress value as a number: the leading digits of its text.
int ui_atspi_value_number(ui_access_node* n):
	int v = 0
	int i = 0
	while ((i < n.value.length) && (n.value.data[i] >= '0') && (n.value.data[i] <= '9') && (v < 100000000)):
		v = v * 10 + (n.value.data[i] - '0')
		i = i + 1
	return v


void ui_atspi_put_text(dbus_buf* out, ui_access_text* t):
	dbus_put_string_n(out, t.data, t.length)


# A row without a name of its own is named from its cells, as ARIA
# rows are: screen readers announce a focused row by its name and do
# not read a row's cells themselves (ui_access_effective_name).
void ui_atspi_put_name(dbus_buf* out, ui_access_node* n):
	ui_access_text name
	ui_access_effective_name(n, &name)
	ui_atspi_put_text(out, &name)
	free(name.data)


char* ui_atspi_live_name(int live):
	if (live == UI_ACCESS_LIVE_ASSERTIVE): return c"assertive"
	return c"polite"


void ui_atspi_put_attribute(dbus_buf* out, char* key, char* value):
	dbus_put_struct(out)
	dbus_put_string(out, key)
	dbus_put_string(out, value)


/* Queued actions, applied by ui_access_atspi_dispatch. */

int ui_atspi_allowed(ui_access_node* n, int action):
	if ((n == 0) || ui_access_inert(n) || ((n.actions & action) == 0)): return 0
	if ((action == UI_ACCESS_SET_VALUE) && ((n.states & UI_ACCESS_READONLY) != 0)): return 0
	return 1


int ui_atspi_enqueue(ui_atspi_bridge* b, ui_access_node* n, int action, char* value, int length):
	if (!ui_atspi_allowed(n, action) || (b.queued >= ui_atspi_max_requests)): return 0
	if ((length < 0) || (length > b.published.max_text_bytes)): return 0
	ui_atspi_request* r = &b.queue[b.queued]
	r.id = n.id
	r.action = action
	r.length = length
	r.value = cast(char*, malloc(length + 1))
	for i in range(length): r.value[i] = value[i]
	r.value[length] = 0
	b.queued = b.queued + 1
	return 1


void ui_atspi_clear_queue(ui_atspi_bridge* b):
	for i in range(b.queued): free(b.queue[i].value)
	b.queued = 0


/* Properties. */

int ui_atspi_iface_is(char* iface, char* name):
	return strcmp(iface, name) == 0


# Write property prop of interface iface as a variant; 0 when the
# object has no such property.
int ui_atspi_put_property(ui_atspi_bridge* b, dbus_buf* out, ui_access_node* n, char* iface, char* prop):
	if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Accessible")):
		if (strcmp(prop, c"Name") == 0):
			dbus_put_sig(out, c"s")
			if (n == 0): dbus_put_string(out, b.app_name)
			else: ui_atspi_put_name(out, n)
			return 1
		if (strcmp(prop, c"Description") == 0):
			dbus_put_sig(out, c"s")
			if (n == 0): dbus_put_string(out, c"")
			else: ui_atspi_put_text(out, &n.description)
			return 1
		if (strcmp(prop, c"Parent") == 0):
			dbus_put_sig(out, c"(so)")
			ui_atspi_put_parent(b, out, n)
			return 1
		if (strcmp(prop, c"ChildCount") == 0):
			dbus_put_sig(out, c"i")
			dbus_put_i32(out, ui_atspi_child_count(b, n))
			return 1
		if ((strcmp(prop, c"Locale") == 0) || (strcmp(prop, c"HelpText") == 0)):
			dbus_put_sig(out, c"s")
			dbus_put_string(out, c"")
			return 1
		if (strcmp(prop, c"AccessibleId") == 0):
			char[64] path
			dbus_put_sig(out, c"s")
			if (n == 0): dbus_put_string(out, c"root")
			else: dbus_put_string(out, ui_atspi_node_path(&path[0], n.id))
			return 1
		return 0
	if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Application") && (n == 0)):
		if (strcmp(prop, c"ToolkitName") == 0):
			dbus_put_sig(out, c"s")
			dbus_put_string(out, c"W")
			return 1
		if (strcmp(prop, c"Version") == 0):
			dbus_put_sig(out, c"s")
			dbus_put_string(out, c"1.0")
			return 1
		if (strcmp(prop, c"AtspiVersion") == 0):
			dbus_put_sig(out, c"s")
			dbus_put_string(out, c"2.1")
			return 1
		if (strcmp(prop, c"Id") == 0):
			dbus_put_sig(out, c"i")
			dbus_put_i32(out, b.app_id)
			return 1
		return 0
	if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Action") && ui_atspi_has_action(n)):
		if (strcmp(prop, c"NActions") == 0):
			dbus_put_sig(out, c"i")
			dbus_put_i32(out, ui_atspi_action_count(n))
			return 1
		return 0
	if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Text") && ui_atspi_has_text(n)):
		if (strcmp(prop, c"CharacterCount") == 0):
			dbus_put_sig(out, c"i")
			dbus_put_i32(out, ui_atspi_char_count(&n.value))
			return 1
		if (strcmp(prop, c"CaretOffset") == 0):
			dbus_put_sig(out, c"i")
			dbus_put_i32(out, ui_atspi_caret(n))
			return 1
		return 0
	if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Value") && ui_atspi_has_value(n)):
		if (strcmp(prop, c"Text") == 0):
			dbus_put_sig(out, c"s")
			ui_atspi_put_text(out, &n.value)
			return 1
		int v = 0 - 1
		if (strcmp(prop, c"MinimumValue") == 0): v = 0
		if (strcmp(prop, c"MaximumValue") == 0): v = 100
		if (strcmp(prop, c"MinimumIncrement") == 0): v = 1
		if (strcmp(prop, c"CurrentValue") == 0): v = ui_atspi_value_number(n)
		if (v < 0): return 0
		dbus_put_sig(out, c"d")
		dbus_put_double_int(out, v)
		return 1
	if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Table") && ui_atspi_has_table(n)):
		int count = 0 - 1
		if (strcmp(prop, c"NRows") == 0): count = ui_atspi_table_rows(n)
		if (strcmp(prop, c"NColumns") == 0): count = ui_atspi_table_columns(n)
		if (strcmp(prop, c"NSelectedRows") == 0): count = ui_atspi_selected_count(n)
		if (strcmp(prop, c"NSelectedColumns") == 0): count = 0
		if (count >= 0):
			dbus_put_sig(out, c"i")
			dbus_put_i32(out, count)
			return 1
		if ((strcmp(prop, c"Caption") == 0) || (strcmp(prop, c"Summary") == 0)):
			dbus_put_sig(out, c"(so)")
			ui_atspi_put_ref(b, out, 0 - 1)
			return 1
		return 0
	if (ui_atspi_iface_is(iface, c"org.a11y.atspi.TableCell") && ui_atspi_has_table_cell(n)):
		int row = 0
		int col = 0
		ui_atspi_cell_position(n, &row, &col)
		if ((strcmp(prop, c"ColumnSpan") == 0) || (strcmp(prop, c"RowSpan") == 0)):
			dbus_put_sig(out, c"i")
			dbus_put_i32(out, 1)
			return 1
		if (strcmp(prop, c"Position") == 0):
			dbus_put_sig(out, c"(ii)")
			dbus_put_struct(out)
			dbus_put_i32(out, row)
			dbus_put_i32(out, col)
			return 1
		if (strcmp(prop, c"Table") == 0):
			dbus_put_sig(out, c"(so)")
			ui_atspi_put_ref(b, out, n.parent.parent.id)
			return 1
		return 0
	if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Selection") && ui_atspi_has_selection(n)):
		if (strcmp(prop, c"NSelectedChildren") == 0):
			dbus_put_sig(out, c"i")
			dbus_put_i32(out, ui_atspi_selected_count(n))
			return 1
		return 0
	return 0


void ui_atspi_put_all(ui_atspi_bridge* b, dbus_buf* out, ui_access_node* n, char* iface, char** props, int count):
	int mark = dbus_array_begin(out, 8)
	for i in range(count):
		dbus_put_struct(out)
		int at = out.length
		dbus_put_string(out, props[i])
		if (!ui_atspi_put_property(b, out, n, iface, props[i])): out.length = at
	dbus_array_end(out, mark, 8)


void ui_atspi_put_interfaces(dbus_buf* out, ui_access_node* n):
	int mark = dbus_array_begin(out, 4)
	dbus_put_string(out, c"org.a11y.atspi.Accessible")
	if (n == 0): dbus_put_string(out, c"org.a11y.atspi.Application")
	else: dbus_put_string(out, c"org.a11y.atspi.Component")
	if (ui_atspi_has_action(n)): dbus_put_string(out, c"org.a11y.atspi.Action")
	if (ui_atspi_has_text(n)): dbus_put_string(out, c"org.a11y.atspi.Text")
	if (ui_atspi_has_editable(n)): dbus_put_string(out, c"org.a11y.atspi.EditableText")
	if (ui_atspi_has_value(n)): dbus_put_string(out, c"org.a11y.atspi.Value")
	if (ui_atspi_has_table(n)): dbus_put_string(out, c"org.a11y.atspi.Table")
	if (ui_atspi_has_table_cell(n)): dbus_put_string(out, c"org.a11y.atspi.TableCell")
	if (ui_atspi_has_selection(n)): dbus_put_string(out, c"org.a11y.atspi.Selection")
	dbus_array_end(out, mark, 4)


/* Geometry: logical window coordinates in the snapshot. coord_type 0 is
the screen (the window origin added), 1 the window, 2 the parent. */

void ui_atspi_extents(ui_atspi_bridge* b, ui_access_node* n, int coord, int* x, int* y, int* w, int* h):
	x[0] = cast(int, n.bounds.x)
	y[0] = cast(int, n.bounds.y)
	w[0] = cast(int, n.bounds.w)
	h[0] = cast(int, n.bounds.h)
	if (coord == 0):
		x[0] = x[0] + b.origin_x
		y[0] = y[0] + b.origin_y
	else if ((coord == 2) && (n.parent != 0)):
		x[0] = x[0] - cast(int, n.parent.bounds.x)
		y[0] = y[0] - cast(int, n.parent.bounds.y)


int ui_atspi_contains(ui_atspi_bridge* b, ui_access_node* n, int px, int py, int coord):
	int x = 0
	int y = 0
	int w = 0
	int h = 0
	ui_atspi_extents(b, n, coord, &x, &y, &w, &h)
	return (px >= x) && (py >= y) && (px < x + w) && (py < y + h)


# The deepest visible descendant of n containing the point, or 0.
ui_access_node* ui_atspi_hit(ui_atspi_bridge* b, ui_access_node* n, int px, int py, int coord):
	ui_access_node* c = n.first_child
	ui_access_node* found = 0
	while (c != 0):
		if (((c.states & UI_ACCESS_HIDDEN) == 0) && ui_atspi_contains(b, c, px, py, coord)):
			ui_access_node* deeper = ui_atspi_hit(b, c, px, py, coord)
			if (deeper != 0): found = deeper
			else: found = c
		c = c.next_sibling
	return found


/* Method calls. */

int ui_atspi_member(dbus_message* m, char* name):
	return strcmp(m.member, name) == 0


# 1 when the call's interface is iface (or absent, as D-Bus allows).
int ui_atspi_on(dbus_message* m, char* iface):
	return (m.interface[0] == 0) || (strcmp(m.interface, iface) == 0)


int ui_atspi_reply_bool(ui_atspi_bridge* b, dbus_message* m, int v):
	dbus_put_bool(dbus_body(b.bus), v)
	return dbus_reply(b.bus, m, c"b")


int ui_atspi_reply_i32(ui_atspi_bridge* b, dbus_message* m, int v):
	dbus_put_i32(dbus_body(b.bus), v)
	return dbus_reply(b.bus, m, c"i")


int ui_atspi_reply_string(ui_atspi_bridge* b, dbus_message* m, char* s):
	dbus_put_string(dbus_body(b.bus), s)
	return dbus_reply(b.bus, m, c"s")


int ui_atspi_unknown(ui_atspi_bridge* b, dbus_message* m):
	return dbus_error_reply(b.bus, m, c"org.freedesktop.DBus.Error.UnknownMethod", c"not supported by the W accessibility bridge")


int ui_atspi_call_properties(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	dbus_reader r
	dbus_message_reader(m, &r)
	char* iface = dbus_read_string(&r, 0)
	if (ui_atspi_member(m, c"Get")):
		char* prop = dbus_read_string(&r, 0)
		if (r.failed): return ui_atspi_unknown(b, m)
		dbus_buf* out = dbus_body(b.bus)
		if (!ui_atspi_put_property(b, out, n, iface, prop)):
			return dbus_error_reply(b.bus, m, c"org.freedesktop.DBus.Error.UnknownProperty", prop)
		return dbus_reply(b.bus, m, c"v")
	if (ui_atspi_member(m, c"GetAll")):
		if (r.failed): return ui_atspi_unknown(b, m)
		dbus_buf* out = dbus_body(b.bus)
		char*[8] props
		int count = 0
		if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Accessible")):
			props[0] = c"Name"
			props[1] = c"Description"
			props[2] = c"Parent"
			props[3] = c"ChildCount"
			props[4] = c"Locale"
			props[5] = c"AccessibleId"
			count = 6
		else if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Application")):
			props[0] = c"ToolkitName"
			props[1] = c"Version"
			props[2] = c"AtspiVersion"
			props[3] = c"Id"
			count = 4
		else if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Action")):
			props[0] = c"NActions"
			count = 1
		else if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Text")):
			props[0] = c"CharacterCount"
			props[1] = c"CaretOffset"
			count = 2
		else if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Value")):
			props[0] = c"MinimumValue"
			props[1] = c"MaximumValue"
			props[2] = c"MinimumIncrement"
			props[3] = c"CurrentValue"
			props[4] = c"Text"
			count = 5
		else if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Table")):
			props[0] = c"NRows"
			props[1] = c"NColumns"
			props[2] = c"Caption"
			props[3] = c"Summary"
			props[4] = c"NSelectedRows"
			props[5] = c"NSelectedColumns"
			count = 6
		else if (ui_atspi_iface_is(iface, c"org.a11y.atspi.TableCell")):
			props[0] = c"ColumnSpan"
			props[1] = c"Position"
			props[2] = c"RowSpan"
			props[3] = c"Table"
			count = 4
		else if (ui_atspi_iface_is(iface, c"org.a11y.atspi.Selection")):
			props[0] = c"NSelectedChildren"
			count = 1
		ui_atspi_put_all(b, out, n, iface, &props[0], count)
		return dbus_reply(b.bus, m, c"a{sv}")
	if (ui_atspi_member(m, c"Set")):
		# The registry numbers each application it embeds.
		char* prop = dbus_read_string(&r, 0)
		char* sig = dbus_read_sig(&r)
		if ((n == 0) && (r.failed == 0) && ui_atspi_iface_is(iface, c"org.a11y.atspi.Application") && (strcmp(prop, c"Id") == 0) && (strcmp(sig, c"i") == 0)):
			b.app_id = dbus_read_i32(&r)
			dbus_body(b.bus)
			return dbus_reply(b.bus, m, c"")
		return dbus_error_reply(b.bus, m, c"org.freedesktop.DBus.Error.PropertyReadOnly", c"read-only")
	return ui_atspi_unknown(b, m)


int ui_atspi_accessible_member(dbus_message* m):
	char*[10] names
	names[0] = c"GetChildAtIndex"
	names[1] = c"GetChildren"
	names[2] = c"GetIndexInParent"
	names[3] = c"GetRelationSet"
	names[4] = c"GetRole"
	names[5] = c"GetRoleName"
	names[6] = c"GetLocalizedRoleName"
	names[7] = c"GetState"
	names[8] = c"GetApplication"
	names[9] = c"GetInterfaces"
	for i in range(10):
		if ui_atspi_member(m, names[i]): return 1
	return 0


int ui_atspi_call_accessible(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	dbus_reader r
	dbus_message_reader(m, &r)
	dbus_buf* out = dbus_body(b.bus)
	if (ui_atspi_member(m, c"GetChildAtIndex")):
		ui_access_node* c = ui_atspi_child_at(b, n, dbus_read_i32(&r))
		if (c == 0): ui_atspi_put_ref(b, out, 0 - 1)
		else: ui_atspi_put_ref(b, out, c.id)
		return dbus_reply(b.bus, m, c"(so)")
	if (ui_atspi_member(m, c"GetChildren")):
		int mark = dbus_array_begin(out, 8)
		int count = ui_atspi_child_count(b, n)
		for i in range(count): ui_atspi_put_ref(b, out, ui_atspi_child_at(b, n, i).id)
		dbus_array_end(out, mark, 8)
		return dbus_reply(b.bus, m, c"a(so)")
	if (ui_atspi_member(m, c"GetIndexInParent")):
		return ui_atspi_reply_i32(b, m, ui_atspi_index_in_parent(n))
	if (ui_atspi_member(m, c"GetRelationSet")):
		int mark = dbus_array_begin(out, 8)
		dbus_array_end(out, mark, 8)
		return dbus_reply(b.bus, m, c"a(ua(so))")
	if (ui_atspi_member(m, c"GetRole")):
		int role = ATSPI_ROLE_APPLICATION
		if (n != 0): role = ui_atspi_role(n)
		dbus_put_u32(out, role)
		return dbus_reply(b.bus, m, c"u")
	if (ui_atspi_member(m, c"GetRoleName") || ui_atspi_member(m, c"GetLocalizedRoleName")):
		int role = ATSPI_ROLE_APPLICATION
		if (n != 0): role = ui_atspi_role(n)
		return ui_atspi_reply_string(b, m, ui_atspi_role_name(role))
	if (ui_atspi_member(m, c"GetState")):
		int lo = 0
		int hi = 0
		if (n != 0): ui_atspi_states(b, n, &lo, &hi)
		int mark = dbus_array_begin(out, 4)
		dbus_put_u32(out, lo)
		dbus_put_u32(out, hi)
		dbus_array_end(out, mark, 4)
		return dbus_reply(b.bus, m, c"au")
	if (ui_atspi_member(m, c"GetAttributes")):
		int mark = dbus_array_begin(out, 8)
		if ((n != 0) && (n.role == UI_ACCESS_HEADING)):
			char[2] level
			level[0] = '0' + n.heading_level
			level[1] = 0
			ui_atspi_put_attribute(out, c"level", &level[0])
		# Live regions, with the attribute names Gecko and Chromium use.
		if ((n != 0) && (n.live != UI_ACCESS_LIVE_OFF)): ui_atspi_put_attribute(out, c"live", ui_atspi_live_name(n.live))
		if ((n != 0) && (ui_access_live_root(n) != 0)): ui_atspi_put_attribute(out, c"container-live", ui_atspi_live_name(ui_access_live_root(n).live))
		dbus_put_struct(out)
		dbus_put_string(out, c"toolkit")
		dbus_put_string(out, c"W")
		dbus_array_end(out, mark, 8)
		return dbus_reply(b.bus, m, c"a{ss}")
	if (ui_atspi_member(m, c"GetApplication")):
		ui_atspi_put_ref(b, out, 0)
		return dbus_reply(b.bus, m, c"(so)")
	if (ui_atspi_member(m, c"GetInterfaces")):
		ui_atspi_put_interfaces(out, n)
		return dbus_reply(b.bus, m, c"as")
	return ui_atspi_unknown(b, m)


int ui_atspi_call_application(ui_atspi_bridge* b, dbus_message* m):
	if (ui_atspi_member(m, c"GetLocale")): return ui_atspi_reply_string(b, m, c"")
	# No peer-to-peer server: clients keep using the bus.
	if (ui_atspi_member(m, c"GetApplicationBusAddress")): return ui_atspi_reply_string(b, m, c"")
	return ui_atspi_unknown(b, m)


int ui_atspi_call_component(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	dbus_reader r
	dbus_message_reader(m, &r)
	dbus_buf* out = dbus_body(b.bus)
	if (ui_atspi_member(m, c"GetExtents") || ui_atspi_member(m, c"GetPosition") || ui_atspi_member(m, c"GetSize")):
		int coord = 1
		if (ui_atspi_member(m, c"GetSize") == 0): coord = dbus_read_u32(&r)
		int x = 0
		int y = 0
		int w = 0
		int h = 0
		ui_atspi_extents(b, n, coord, &x, &y, &w, &h)
		if (ui_atspi_member(m, c"GetExtents")):
			dbus_put_struct(out)
			dbus_put_i32(out, x)
			dbus_put_i32(out, y)
			dbus_put_i32(out, w)
			dbus_put_i32(out, h)
			return dbus_reply(b.bus, m, c"(iiii)")
		if (ui_atspi_member(m, c"GetPosition")):
			dbus_put_i32(out, x)
			dbus_put_i32(out, y)
			return dbus_reply(b.bus, m, c"ii")
		dbus_put_i32(out, w)
		dbus_put_i32(out, h)
		return dbus_reply(b.bus, m, c"ii")
	if (ui_atspi_member(m, c"Contains")):
		int px = dbus_read_i32(&r)
		int py = dbus_read_i32(&r)
		int coord = dbus_read_u32(&r)
		return ui_atspi_reply_bool(b, m, ui_atspi_contains(b, n, px, py, coord))
	if (ui_atspi_member(m, c"GetAccessibleAtPoint")):
		int px = dbus_read_i32(&r)
		int py = dbus_read_i32(&r)
		int coord = dbus_read_u32(&r)
		ui_access_node* hit = ui_atspi_hit(b, n, px, py, coord)
		if (hit == 0): ui_atspi_put_ref(b, out, 0 - 1)
		else: ui_atspi_put_ref(b, out, hit.id)
		return dbus_reply(b.bus, m, c"(so)")
	if (ui_atspi_member(m, c"GetLayer")):
		# WINDOW for the top-level frame, WIDGET for everything in it.
		if (n.parent == 0): dbus_put_u32(out, 7)
		else: dbus_put_u32(out, 3)
		return dbus_reply(b.bus, m, c"u")
	if (ui_atspi_member(m, c"GetMDIZOrder")):
		dbus_put_u16(out, 0)
		return dbus_reply(b.bus, m, c"n")
	if (ui_atspi_member(m, c"GetAlpha")):
		dbus_put_double_int(out, 1)
		return dbus_reply(b.bus, m, c"d")
	if (ui_atspi_member(m, c"GrabFocus")):
		return ui_atspi_reply_bool(b, m, ui_atspi_enqueue(b, n, UI_ACCESS_FOCUS, c"", 0))
	if (ui_atspi_member(m, c"SetExtents") || ui_atspi_member(m, c"SetPosition") || ui_atspi_member(m, c"SetSize") || ui_atspi_member(m, c"ScrollTo") || ui_atspi_member(m, c"ScrollToPoint")):
		return ui_atspi_reply_bool(b, m, 0)
	return ui_atspi_unknown(b, m)


int ui_atspi_call_action(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	dbus_reader r
	dbus_message_reader(m, &r)
	dbus_buf* out = dbus_body(b.bus)
	if (ui_atspi_member(m, c"GetActions")):
		int mark = dbus_array_begin(out, 8)
		for i in range(ui_atspi_action_count(n)):
			dbus_put_struct(out)
			dbus_put_string(out, ui_atspi_action_name(ui_atspi_action_at(n, i)))
			dbus_put_string(out, c"")
			dbus_put_string(out, c"")
		dbus_array_end(out, mark, 8)
		return dbus_reply(b.bus, m, c"a(sss)")
	int index = dbus_read_i32(&r)
	int action = 0
	if (r.failed == 0): action = ui_atspi_action_at(n, index)
	if (ui_atspi_member(m, c"GetName") || ui_atspi_member(m, c"GetLocalizedName")):
		if (action == 0): return ui_atspi_reply_string(b, m, c"")
		return ui_atspi_reply_string(b, m, ui_atspi_action_name(action))
	if (ui_atspi_member(m, c"GetDescription") || ui_atspi_member(m, c"GetKeyBinding")):
		return ui_atspi_reply_string(b, m, c"")
	if (ui_atspi_member(m, c"DoAction")):
		if (action == 0): return ui_atspi_reply_bool(b, m, 0)
		return ui_atspi_reply_bool(b, m, ui_atspi_enqueue(b, n, action, c"", 0))
	return ui_atspi_unknown(b, m)


# A substring of a node's value by character offsets; end < 0 means the
# end of the text.
void ui_atspi_put_range(dbus_buf* out, ui_access_text* t, int start, int end):
	int count = ui_atspi_char_count(t)
	if ((end < 0) || (end > count)): end = count
	if (start < 0): start = 0
	if (start > end): start = end
	int from = ui_atspi_char_byte(t, start)
	int to = ui_atspi_char_byte(t, end)
	dbus_put_string_n(out, &t.data[from], to - from)


# An empty a{ss}.
void ui_atspi_put_attributes(dbus_buf* out):
	int mark = dbus_array_begin(out, 8)
	dbus_array_end(out, mark, 8)


# Queue a caret move (start == end) or a selection from start to end
# (the caret at end), in characters of the published text.
int ui_atspi_select_text(ui_atspi_bridge* b, ui_access_node* n, int start, int end):
	int count = ui_atspi_char_count(&n.value)
	if ((start < 0) || (end < 0) || (start > count) || (end > count)): return 0
	char[32] payload
	int length = ui_access_selection_format(&payload[0], start, end)
	return ui_atspi_enqueue(b, n, UI_ACCESS_SET_SELECTION, &payload[0], length)


int ui_atspi_call_text(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	dbus_reader r
	dbus_message_reader(m, &r)
	dbus_buf* out = dbus_body(b.bus)
	ui_access_text* t = &n.value
	int count = ui_atspi_char_count(t)
	if (ui_atspi_member(m, c"GetText")):
		int start = dbus_read_i32(&r)
		int end = dbus_read_i32(&r)
		ui_atspi_put_range(out, t, start, end)
		return dbus_reply(b.bus, m, c"s")
	if (ui_atspi_member(m, c"GetCharacterAtOffset")):
		int k = dbus_read_i32(&r)
		int c = 0
		if ((k >= 0) && (k < count)):
			int at = ui_atspi_char_byte(t, k)
			if (utf8_scan(t.data + at, t.length - at, &c) == 0): c = 65533
		return ui_atspi_reply_i32(b, m, c)
	if (ui_atspi_member(m, c"GetStringAtOffset") || ui_atspi_member(m, c"GetTextAtOffset") || ui_atspi_member(m, c"GetTextBeforeOffset") || ui_atspi_member(m, c"GetTextAfterOffset")):
		# Character granularity returns one character; every coarser
		# one returns the whole field, which is a single line.
		int k = dbus_read_i32(&r)
		int granularity = dbus_read_u32(&r)
		int start = 0
		int end = count
		if (ui_atspi_member(m, c"GetStringAtOffset") && (granularity == 0) && (k >= 0) && (k < count)):
			start = k
			end = k + 1
		if (ui_atspi_member(m, c"GetTextBeforeOffset") || ui_atspi_member(m, c"GetTextAfterOffset")):
			start = 0
			end = 0
		ui_atspi_put_range(out, t, start, end)
		dbus_put_i32(out, start)
		dbus_put_i32(out, end)
		return dbus_reply(b.bus, m, c"sii")
	# One selection at most: the snapshot's [selection_start,
	# selection_end) when it is not empty.
	int selected = ui_access_has_selection(n)
	if (ui_atspi_member(m, c"GetNSelections")): return ui_atspi_reply_i32(b, m, selected)
	if (ui_atspi_member(m, c"GetSelection")):
		int k = dbus_read_i32(&r)
		int start = 0
		int end = 0
		if ((k == 0) && selected && (r.failed == 0)):
			start = n.selection_start
			end = n.selection_end
		dbus_put_i32(out, start)
		dbus_put_i32(out, end)
		return dbus_reply(b.bus, m, c"ii")
	if (ui_atspi_member(m, c"SetCaretOffset")):
		int k = dbus_read_i32(&r)
		if (r.failed): return ui_atspi_reply_bool(b, m, 0)
		return ui_atspi_reply_bool(b, m, ui_atspi_select_text(b, n, k, k))
	if (ui_atspi_member(m, c"AddSelection")):
		# A second selection is not supported; an empty one says nothing.
		int start = dbus_read_i32(&r)
		int end = dbus_read_i32(&r)
		if (r.failed || selected || (start == end)): return ui_atspi_reply_bool(b, m, 0)
		return ui_atspi_reply_bool(b, m, ui_atspi_select_text(b, n, start, end))
	if (ui_atspi_member(m, c"SetSelection")):
		int k = dbus_read_i32(&r)
		int start = dbus_read_i32(&r)
		int end = dbus_read_i32(&r)
		if (r.failed || (k != 0)): return ui_atspi_reply_bool(b, m, 0)
		return ui_atspi_reply_bool(b, m, ui_atspi_select_text(b, n, start, end))
	if (ui_atspi_member(m, c"RemoveSelection")):
		# Removing the selection leaves the caret where it was.
		int k = dbus_read_i32(&r)
		if (r.failed || (k != 0) || !selected): return ui_atspi_reply_bool(b, m, 0)
		int caret = ui_atspi_caret(n)
		return ui_atspi_reply_bool(b, m, ui_atspi_select_text(b, n, caret, caret))
	# Text attributes: the bridge knows no fonts or colours, so every
	# set is empty and the whole text is one run.
	if (ui_atspi_member(m, c"GetDefaultAttributes")):
		ui_atspi_put_attributes(out)
		return dbus_reply(b.bus, m, c"a{ss}")
	if (ui_atspi_member(m, c"GetDefaultAttributeSet")):
		int mark = dbus_array_begin(out, 4)
		dbus_array_end(out, mark, 4)
		return dbus_reply(b.bus, m, c"as")
	if (ui_atspi_member(m, c"GetAttributes") || ui_atspi_member(m, c"GetAttributeRun")):
		ui_atspi_put_attributes(out)
		dbus_put_i32(out, 0)
		dbus_put_i32(out, count)
		return dbus_reply(b.bus, m, c"a{ss}ii")
	if (ui_atspi_member(m, c"GetAttributeValue")):
		return ui_atspi_reply_string(b, m, c"")
	if (ui_atspi_member(m, c"GetCharacterExtents") || ui_atspi_member(m, c"GetRangeExtents")):
		int x = 0
		int y = 0
		int w = 0
		int h = 0
		ui_atspi_extents(b, n, 0, &x, &y, &w, &h)
		dbus_put_i32(out, x)
		dbus_put_i32(out, y)
		dbus_put_i32(out, w)
		dbus_put_i32(out, h)
		return dbus_reply(b.bus, m, c"iiii")
	return ui_atspi_unknown(b, m)


# The node's text with bytes [from, to) replaced by insert[0..n).
int ui_atspi_edit(ui_atspi_bridge* b, ui_access_node* n, int from, int to, char* insert, int insert_length):
	ui_access_text* t = &n.value
	int length = t.length - (to - from) + insert_length
	char* text = cast(char*, malloc(length + 1))
	int k = 0
	for i in range(from):
		text[k] = t.data[i]
		k = k + 1
	for i in range(insert_length):
		text[k] = insert[i]
		k = k + 1
	for i in range(to, t.length):
		text[k] = t.data[i]
		k = k + 1
	int ok = ui_atspi_enqueue(b, n, UI_ACCESS_SET_VALUE, text, length)
	free(text)
	return ok


int ui_atspi_call_editable(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	dbus_reader r
	dbus_message_reader(m, &r)
	ui_access_text* t = &n.value
	if (ui_atspi_member(m, c"SetTextContents")):
		int length = 0
		char* s = dbus_read_string(&r, &length)
		if (r.failed || !utf8_validate_bytes(s, length)): return ui_atspi_reply_bool(b, m, 0)
		return ui_atspi_reply_bool(b, m, ui_atspi_edit(b, n, 0, t.length, s, length))
	if (ui_atspi_member(m, c"InsertText")):
		int k = dbus_read_i32(&r)
		int length = 0
		char* s = dbus_read_string(&r, &length)
		# The length counts characters, like every AT-SPI offset.
		int count = dbus_read_i32(&r)
		if (r.failed || !utf8_validate_bytes(s, length)): return ui_atspi_reply_bool(b, m, 0)
		ui_access_text inserted
		inserted.data = s
		inserted.length = length
		int bytes = length
		if ((count >= 0) && (count < ui_atspi_char_count(&inserted))): bytes = ui_atspi_char_byte(&inserted, count)
		int at = ui_atspi_char_byte(t, k)
		return ui_atspi_reply_bool(b, m, ui_atspi_edit(b, n, at, at, s, bytes))
	if (ui_atspi_member(m, c"DeleteText")):
		int start = dbus_read_i32(&r)
		int end = dbus_read_i32(&r)
		if (r.failed || (end < start)): return ui_atspi_reply_bool(b, m, 0)
		return ui_atspi_reply_bool(b, m, ui_atspi_edit(b, n, ui_atspi_char_byte(t, start), ui_atspi_char_byte(t, end), c"", 0))
	if (ui_atspi_member(m, c"CopyText") || ui_atspi_member(m, c"CutText") || ui_atspi_member(m, c"PasteText")):
		if (ui_atspi_member(m, c"CopyText")):
			dbus_body(b.bus)
			return dbus_reply(b.bus, m, c"")
		return ui_atspi_reply_bool(b, m, 0)
	return ui_atspi_unknown(b, m)


int ui_atspi_call_value(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	if (ui_atspi_member(m, c"SetCurrentValue")): return ui_atspi_reply_bool(b, m, 0)
	return ui_atspi_unknown(b, m)


int ui_atspi_reply_ref(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	if (n == 0): ui_atspi_put_ref(b, dbus_body(b.bus), 0 - 1)
	else: ui_atspi_put_ref(b, dbus_body(b.bus), n.id)
	return dbus_reply(b.bus, m, c"(so)")


# Select a child by queueing its activation (what a click does).
int ui_atspi_select(ui_atspi_bridge* b, ui_access_node* c):
	if (!ui_atspi_selectable_child(c)): return 0
	if ((c.states & UI_ACCESS_SELECTED) != 0): return 1
	return ui_atspi_enqueue(b, c, UI_ACCESS_ACTIVATE, c"", 0)


int ui_atspi_call_table(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	dbus_reader r
	dbus_message_reader(m, &r)
	int columns = ui_atspi_table_columns(n)
	int cells = ui_atspi_table_rows(n) * columns
	if (ui_atspi_member(m, c"GetAccessibleAt")):
		int row = dbus_read_i32(&r)
		int col = dbus_read_i32(&r)
		return ui_atspi_reply_ref(b, m, ui_atspi_row_cell(ui_atspi_table_row(n, row), col))
	if (ui_atspi_member(m, c"GetIndexAt")):
		int row = dbus_read_i32(&r)
		int col = dbus_read_i32(&r)
		int index = 0 - 1
		if (ui_atspi_row_cell(ui_atspi_table_row(n, row), col) != 0): index = row * columns + col
		return ui_atspi_reply_i32(b, m, index)
	if (ui_atspi_member(m, c"GetRowAtIndex") || ui_atspi_member(m, c"GetColumnAtIndex")):
		int index = dbus_read_i32(&r)
		int v = 0 - 1
		if ((index >= 0) && (index < cells)):
			if (ui_atspi_member(m, c"GetRowAtIndex")): v = index / columns
			else: v = index % columns
		return ui_atspi_reply_i32(b, m, v)
	if (ui_atspi_member(m, c"GetRowColumnExtentsAtIndex")):
		int index = dbus_read_i32(&r)
		int ok = (index >= 0) && (index < cells)
		int row = 0
		int col = 0
		int selected = 0
		if ok:
			row = index / columns
			col = index % columns
			selected = (ui_atspi_table_row(n, row).states & UI_ACCESS_SELECTED) != 0
		dbus_buf* out = dbus_body(b.bus)
		dbus_put_bool(out, ok)
		dbus_put_i32(out, row)
		dbus_put_i32(out, col)
		dbus_put_i32(out, ok)
		dbus_put_i32(out, ok)
		dbus_put_bool(out, selected)
		return dbus_reply(b.bus, m, c"biiiib")
	if (ui_atspi_member(m, c"GetRowDescription")):
		return ui_atspi_reply_string(b, m, c"")
	if (ui_atspi_member(m, c"GetColumnDescription")):
		ui_access_node* header = ui_atspi_row_cell(ui_atspi_header_row(n), dbus_read_i32(&r))
		if (header == 0): return ui_atspi_reply_string(b, m, c"")
		ui_atspi_put_text(dbus_body(b.bus), &header.name)
		return dbus_reply(b.bus, m, c"s")
	if (ui_atspi_member(m, c"GetRowExtentAt") || ui_atspi_member(m, c"GetColumnExtentAt")):
		int row = dbus_read_i32(&r)
		int col = dbus_read_i32(&r)
		return ui_atspi_reply_i32(b, m, ui_atspi_row_cell(ui_atspi_table_row(n, row), col) != 0)
	if (ui_atspi_member(m, c"GetRowHeader")):
		return ui_atspi_reply_ref(b, m, 0)
	if (ui_atspi_member(m, c"GetColumnHeader")):
		return ui_atspi_reply_ref(b, m, ui_atspi_row_cell(ui_atspi_header_row(n), dbus_read_i32(&r)))
	if (ui_atspi_member(m, c"GetSelectedRows") || ui_atspi_member(m, c"GetSelectedColumns")):
		dbus_buf* out = dbus_body(b.bus)
		int mark = dbus_array_begin(out, 4)
		if (ui_atspi_member(m, c"GetSelectedRows")):
			for i in range(ui_atspi_table_rows(n)):
				if ((ui_atspi_table_row(n, i).states & UI_ACCESS_SELECTED) != 0): dbus_put_i32(out, i)
		dbus_array_end(out, mark, 4)
		return dbus_reply(b.bus, m, c"ai")
	if (ui_atspi_member(m, c"IsRowSelected") || ui_atspi_member(m, c"IsSelected")):
		ui_access_node* row = ui_atspi_table_row(n, dbus_read_i32(&r))
		if (ui_atspi_member(m, c"IsSelected") && (ui_atspi_row_cell(row, dbus_read_i32(&r)) == 0)): row = 0
		return ui_atspi_reply_bool(b, m, (row != 0) && ((row.states & UI_ACCESS_SELECTED) != 0))
	if (ui_atspi_member(m, c"IsColumnSelected")):
		return ui_atspi_reply_bool(b, m, 0)
	if (ui_atspi_member(m, c"AddRowSelection")):
		ui_access_node* row = ui_atspi_table_row(n, dbus_read_i32(&r))
		return ui_atspi_reply_bool(b, m, (row != 0) && ui_atspi_select(b, row))
	if (ui_atspi_member(m, c"AddColumnSelection") || ui_atspi_member(m, c"RemoveRowSelection") || ui_atspi_member(m, c"RemoveColumnSelection")):
		return ui_atspi_reply_bool(b, m, 0)
	return ui_atspi_unknown(b, m)


int ui_atspi_call_table_cell(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	int row = 0
	int col = 0
	ui_atspi_cell_position(n, &row, &col)
	if (ui_atspi_member(m, c"GetRowColumnSpan")):
		dbus_buf* out = dbus_body(b.bus)
		dbus_put_i32(out, row)
		dbus_put_i32(out, col)
		dbus_put_i32(out, 1)
		dbus_put_i32(out, 1)
		return dbus_reply(b.bus, m, c"iiii")
	if (ui_atspi_member(m, c"GetRowHeaderCells") || ui_atspi_member(m, c"GetColumnHeaderCells")):
		dbus_buf* out = dbus_body(b.bus)
		int mark = dbus_array_begin(out, 8)
		if (ui_atspi_member(m, c"GetColumnHeaderCells")):
			ui_access_node* header = ui_atspi_row_cell(ui_atspi_header_row(n.parent.parent), col)
			if (header != 0): ui_atspi_put_ref(b, out, header.id)
		dbus_array_end(out, mark, 8)
		return dbus_reply(b.bus, m, c"a(so)")
	return ui_atspi_unknown(b, m)


int ui_atspi_call_selection(ui_atspi_bridge* b, dbus_message* m, ui_access_node* n):
	dbus_reader r
	dbus_message_reader(m, &r)
	if (ui_atspi_member(m, c"GetSelectedChild")):
		return ui_atspi_reply_ref(b, m, ui_atspi_selected_at(n, dbus_read_i32(&r)))
	if (ui_atspi_member(m, c"SelectChild")):
		ui_access_node* c = ui_atspi_child_at(b, n, dbus_read_i32(&r))
		return ui_atspi_reply_bool(b, m, (c != 0) && ui_atspi_select(b, c))
	if (ui_atspi_member(m, c"IsChildSelected")):
		ui_access_node* c = ui_atspi_child_at(b, n, dbus_read_i32(&r))
		return ui_atspi_reply_bool(b, m, ui_atspi_selectable_child(c) && ((c.states & UI_ACCESS_SELECTED) != 0))
	# Single selection driven by activation: nothing can be deselected
	# or selected wholesale.
	if (ui_atspi_member(m, c"DeselectSelectedChild") || ui_atspi_member(m, c"DeselectChild") || ui_atspi_member(m, c"SelectAll") || ui_atspi_member(m, c"ClearSelection")):
		return ui_atspi_reply_bool(b, m, 0)
	return ui_atspi_unknown(b, m)


/* The libatspi cache: GetItems preloads the whole tree and AddAccessible
/ RemoveAccessible keep it current. */

ui_access_node* ui_atspi_preorder_next(ui_access_node* n):
	if (n.first_child != 0): return n.first_child
	while (n != 0):
		if (n.next_sibling != 0): return n.next_sibling
		n = n.parent
	return 0


# One ((so)(so)(so)iiassusau) item: self, application, parent, index in
# parent, child count, interfaces, name, role, description, states.
void ui_atspi_put_cache_item(ui_atspi_bridge* b, dbus_buf* out, ui_access_node* n):
	dbus_put_struct(out)
	if (n == 0): ui_atspi_put_ref(b, out, 0)
	else: ui_atspi_put_ref(b, out, n.id)
	ui_atspi_put_ref(b, out, 0)
	ui_atspi_put_parent(b, out, n)
	if (n == 0): dbus_put_i32(out, 0 - 1)
	else: dbus_put_i32(out, ui_atspi_index_in_parent(n))
	dbus_put_i32(out, ui_atspi_child_count(b, n))
	ui_atspi_put_interfaces(out, n)
	int lo = 0
	int hi = 0
	if (n == 0):
		dbus_put_string(out, b.app_name)
		dbus_put_u32(out, ATSPI_ROLE_APPLICATION)
		dbus_put_string(out, c"")
	else:
		ui_atspi_put_name(out, n)
		dbus_put_u32(out, ui_atspi_role(n))
		ui_atspi_put_text(out, &n.description)
		ui_atspi_states(b, n, &lo, &hi)
	int mark = dbus_array_begin(out, 4)
	dbus_put_u32(out, lo)
	dbus_put_u32(out, hi)
	dbus_array_end(out, mark, 4)


int ui_atspi_call_cache(ui_atspi_bridge* b, dbus_message* m):
	dbus_buf* out = dbus_body(b.bus)
	int mark = dbus_array_begin(out, 8)
	ui_atspi_put_cache_item(b, out, 0)
	if (b.published != 0):
		ui_access_node* n = b.published.root
		while (n != 0):
			ui_atspi_put_cache_item(b, out, n)
			n = ui_atspi_preorder_next(n)
	dbus_array_end(out, mark, 8)
	return dbus_reply(b.bus, m, c"a((so)(so)(so)iiassusau)")


# Answer one method call addressed to an object path.
int ui_atspi_handle_call(ui_atspi_bridge* b, dbus_message* m):
	if (strcmp(m.interface, c"org.freedesktop.DBus.Peer") == 0):
		dbus_body(b.bus)
		if (ui_atspi_member(m, c"Ping")): return dbus_reply(b.bus, m, c"")
		return ui_atspi_unknown(b, m)
	if ((strcmp(m.path, c"/org/a11y/atspi/cache") == 0) && ui_atspi_on(m, c"org.a11y.atspi.Cache") && ui_atspi_member(m, c"GetItems")):
		return ui_atspi_call_cache(b, m)
	int id = ui_atspi_path_id(m.path)
	ui_access_node* n = 0
	if (id > 0):
		n = ui_access_find(b.published, id)
		if (n == 0): id = 0 - 1
	if (id < 0): return dbus_error_reply(b.bus, m, c"org.freedesktop.DBus.Error.UnknownObject", m.path)
	if (strcmp(m.interface, c"org.freedesktop.DBus.Properties") == 0): return ui_atspi_call_properties(b, m, n)
	if (strcmp(m.interface, c"org.a11y.atspi.Accessible") == 0): return ui_atspi_call_accessible(b, m, n)
	# Calls without an interface reach Accessible when the member is one of its methods.
	if ((m.interface[0] == 0) && ui_atspi_accessible_member(m)): return ui_atspi_call_accessible(b, m, n)
	if ((n == 0) && (strcmp(m.interface, c"org.a11y.atspi.Application") == 0)): return ui_atspi_call_application(b, m)
	if (n != 0):
		if (strcmp(m.interface, c"org.a11y.atspi.Component") == 0): return ui_atspi_call_component(b, m, n)
		if ((strcmp(m.interface, c"org.a11y.atspi.Action") == 0) && ui_atspi_has_action(n)): return ui_atspi_call_action(b, m, n)
		if ((strcmp(m.interface, c"org.a11y.atspi.Text") == 0) && ui_atspi_has_text(n)): return ui_atspi_call_text(b, m, n)
		if ((strcmp(m.interface, c"org.a11y.atspi.EditableText") == 0) && ui_atspi_has_editable(n)): return ui_atspi_call_editable(b, m, n)
		if ((strcmp(m.interface, c"org.a11y.atspi.Value") == 0) && ui_atspi_has_value(n)): return ui_atspi_call_value(b, m, n)
		if ((strcmp(m.interface, c"org.a11y.atspi.Table") == 0) && ui_atspi_has_table(n)): return ui_atspi_call_table(b, m, n)
		if ((strcmp(m.interface, c"org.a11y.atspi.TableCell") == 0) && ui_atspi_has_table_cell(n)): return ui_atspi_call_table_cell(b, m, n)
		if ((strcmp(m.interface, c"org.a11y.atspi.Selection") == 0) && ui_atspi_has_selection(n)): return ui_atspi_call_selection(b, m, n)
	return ui_atspi_unknown(b, m)


/* Events: org.a11y.atspi.Event.* signals with the (siiva{sv}) body. */

void ui_atspi_event_head(dbus_buf* out, char* kind, int detail1, int detail2):
	dbus_put_string(out, kind)
	dbus_put_i32(out, detail1)
	dbus_put_i32(out, detail2)


void ui_atspi_event_tail(dbus_buf* out):
	int mark = dbus_array_begin(out, 8)
	dbus_array_end(out, mark, 8)


void ui_atspi_emit(ui_atspi_bridge* b, int id, char* iface, char* member, char* kind, int detail1, int detail2):
	char[64] path
	char* p = ui_atspi_root_path()
	if (id > 0): p = ui_atspi_node_path(&path[0], id)
	dbus_buf* out = dbus_body(b.bus)
	ui_atspi_event_head(out, kind, detail1, detail2)
	dbus_put_sig(out, c"i")
	dbus_put_i32(out, 0)
	ui_atspi_event_tail(out)
	dbus_signal(b.bus, p, iface, member, c"siiva{sv}")


void ui_atspi_emit_state(ui_atspi_bridge* b, int id, char* state, int on):
	ui_atspi_emit(b, id, c"org.a11y.atspi.Event.Object", c"StateChanged", state, on, 0)


# ChildrenChanged on parent_id (0 = the application root) for child.
void ui_atspi_emit_children(ui_atspi_bridge* b, int parent_id, char* kind, int index, int child_id):
	char[64] path
	char* p = ui_atspi_root_path()
	if (parent_id > 0): p = ui_atspi_node_path(&path[0], parent_id)
	dbus_buf* out = dbus_body(b.bus)
	ui_atspi_event_head(out, kind, index, 0)
	dbus_put_sig(out, c"(so)")
	ui_atspi_put_ref(b, out, child_id)
	ui_atspi_event_tail(out)
	dbus_signal(b.bus, p, c"org.a11y.atspi.Event.Object", c"ChildrenChanged", c"siiva{sv}")


void ui_atspi_emit_name(ui_atspi_bridge* b, int id, char* kind, ui_access_text* text):
	char[64] path
	dbus_buf* out = dbus_body(b.bus)
	ui_atspi_event_head(out, kind, 0, 0)
	dbus_put_sig(out, c"s")
	ui_atspi_put_text(out, text)
	ui_atspi_event_tail(out)
	dbus_signal(b.bus, ui_atspi_node_path(&path[0], id), c"org.a11y.atspi.Event.Object", c"PropertyChange", c"siiva{sv}")


# TextChanged for the whole of a field's text (screen readers echo the
# inserted part).
void ui_atspi_emit_text(ui_atspi_bridge* b, int id, char* kind, ui_access_text* text):
	int count = ui_atspi_char_count(text)
	if (count == 0): return
	char[64] path
	dbus_buf* out = dbus_body(b.bus)
	ui_atspi_event_head(out, kind, 0, count)
	dbus_put_sig(out, c"s")
	ui_atspi_put_text(out, text)
	ui_atspi_event_tail(out)
	dbus_signal(b.bus, ui_atspi_node_path(&path[0], id), c"org.a11y.atspi.Event.Object", c"TextChanged", c"siiva{sv}")


# Object:Announcement (at-spi2-core 2.46+, what ATK's notification signal
# becomes): detail1 is the politeness (ATSPI_LIVE_POLITE 1, ASSERTIVE 2)
# and the text the event's string. Orca speaks it whatever has focus,
# which name and text changes of an unfocused object do not achieve.
void ui_atspi_emit_announcement(ui_atspi_bridge* b, int id, ui_access_text* text, int live):
	char[64] path
	char* p = ui_atspi_root_path()
	if (id > 0): p = ui_atspi_node_path(&path[0], id)
	dbus_buf* out = dbus_body(b.bus)
	ui_atspi_event_head(out, c"", live, 0)
	dbus_put_sig(out, c"s")
	ui_atspi_put_text(out, text)
	ui_atspi_event_tail(out)
	dbus_signal(b.bus, p, c"org.a11y.atspi.Event.Object", c"Announcement", c"siiva{sv}")


int ui_atspi_text_same(ui_access_text* a, ui_access_text* b):
	if (a.length != b.length): return 0
	for i in range(a.length):
		if (a.data[i] != b.data[i]): return 0
	return 1


int ui_atspi_has_child(ui_access_node* parent, int id):
	ui_access_node* c = parent.first_child
	while (c != 0):
		if (c.id == id): return 1
		c = c.next_sibling
	return 0


# Announce what changed from old to new (new is already published).
void ui_atspi_emit_cache_add(ui_atspi_bridge* b, ui_access_node* n):
	ui_atspi_put_cache_item(b, dbus_body(b.bus), n)
	dbus_signal(b.bus, c"/org/a11y/atspi/cache", c"org.a11y.atspi.Cache", c"AddAccessible", c"((so)(so)(so)iiassusau)")


void ui_atspi_emit_cache_remove(ui_atspi_bridge* b, int id):
	char[64] path
	dbus_buf* out = dbus_body(b.bus)
	dbus_put_struct(out)
	dbus_put_string(out, b.bus.unique_name)
	dbus_put_path(out, ui_atspi_node_path(&path[0], id))
	dbus_signal(b.bus, c"/org/a11y/atspi/cache", c"org.a11y.atspi.Cache", c"RemoveAccessible", c"(so)")


void ui_atspi_emit_changes(ui_atspi_bridge* b, ui_access_tree* old, ui_access_tree* fresh):
	# The cache first, parents before children, so the events below
	# refer to objects a caching client already knows.
	if ((old == 0) || (old.root == 0) || (fresh.root == 0) || (fresh.root.id != old.root.id)): ui_atspi_emit_cache_add(b, 0)
	ui_access_node* walk = fresh.root
	while (walk != 0):
		if (ui_access_find(old, walk.id) == 0): ui_atspi_emit_cache_add(b, walk)
		walk = ui_atspi_preorder_next(walk)
	if ((old == 0) || (old.root == 0)):
		if (fresh.root != 0):
			ui_atspi_emit_children(b, 0, c"add", 0, fresh.root.id)
			ui_atspi_emit(b, fresh.root.id, c"org.a11y.atspi.Event.Window", c"Activate", c"", 0, 0)
	else if ((fresh.root == 0) || (fresh.root.id != old.root.id)):
		ui_atspi_emit_children(b, 0, c"remove", 0, old.root.id)
		if (fresh.root != 0): ui_atspi_emit_children(b, 0, c"add", 0, fresh.root.id)
	if (old != 0):
		# Nodes that disappeared are gone for good.
		for int id in old.nodes:
			ui_access_node* gone = old.nodes[id]
			if (ui_access_find(fresh, id) == 0):
				ui_atspi_emit_state(b, id, c"defunct", 1)
				ui_atspi_emit_cache_remove(b, id)
				if ((gone.parent != 0) && (ui_access_find(fresh, gone.parent.id) != 0)):
					ui_atspi_emit_children(b, gone.parent.id, c"remove", ui_atspi_index_in_parent(gone), id)
	for int id in fresh.nodes:
		ui_access_node* n = fresh.nodes[id]
		ui_access_node* was = ui_access_find(old, id)
		if (was == 0):
			if (n.parent != 0):
				ui_access_node* parent_was = ui_access_find(old, n.parent.id)
				if (parent_was != 0): ui_atspi_emit_children(b, n.parent.id, c"add", ui_atspi_index_in_parent(n), id)
			continue
		# Every AT-SPI state that changed but focus (announced last, the
		# old focus first).
		int lo = 0
		int hi = 0
		int was_lo = 0
		int was_hi = 0
		ui_atspi_states_for(n, 0, &lo, &hi)
		ui_atspi_states_for(was, 0, &was_lo, &was_hi)
		for k in range(64):
			int on = 0
			int off = 0
			if (k < 32):
				on = (lo >> k) & 1
				off = (was_lo >> k) & 1
			else:
				on = (hi >> (k - 32)) & 1
				off = (was_hi >> (k - 32)) & 1
			if ((on != off) && (ui_atspi_state_nick(k) != 0)): ui_atspi_emit_state(b, id, ui_atspi_state_nick(k), on)
		# The effective name, so a row named from its cells reports
		# a change when a cell's name changes.
		if (!ui_access_effective_name_same(n, was)):
			ui_access_text name
			ui_access_effective_name(n, &name)
			ui_atspi_emit_name(b, id, c"accessible-name", &name)
			free(name.data)
		if (!ui_atspi_text_same(&n.description, &was.description)): ui_atspi_emit_name(b, id, c"accessible-description", &n.description)
		if ((n.role == UI_ACCESS_PROGRESS) && !ui_atspi_text_same(&n.value, &was.value)): ui_atspi_emit_name(b, id, c"accessible-value", &n.value)
		if (ui_atspi_has_text(n) && !ui_atspi_text_same(&n.value, &was.value)):
			ui_atspi_emit_text(b, id, c"delete", &was.value)
			ui_atspi_emit_text(b, id, c"insert", &n.value)
		# The selection, then where the caret went (Orca reads the
		# selected text on the first and the moved-over text on the
		# second).
		if (ui_atspi_has_text(n)):
			if ((ui_access_has_selection(n) || ui_access_has_selection(was)) && ((n.selection_start != was.selection_start) || (n.selection_end != was.selection_end))):
				ui_atspi_emit(b, id, c"org.a11y.atspi.Event.Object", c"TextSelectionChanged", c"", 0, 0)
			if ((n.caret != was.caret) && (n.caret >= 0)):
				ui_atspi_emit(b, id, c"org.a11y.atspi.Event.Object", c"TextCaretMoved", c"", n.caret, 0)
	# One SelectionChanged per container whose selected children changed,
	# after the per-child selected states.
	walk = fresh.root
	while (walk != 0):
		ui_access_node* had = ui_access_find(old, walk.id)
		if (ui_atspi_has_selection(walk) && (had != 0) && !ui_atspi_selection_same(walk, had)):
			ui_atspi_emit(b, walk.id, c"org.a11y.atspi.Event.Object", c"SelectionChanged", c"", 0, 0)
		walk = ui_atspi_preorder_next(walk)
	int old_focus = 0
	if (old != 0): old_focus = old.focused_id
	if (fresh.focused_id != old_focus):
		if ((old_focus != 0) && (ui_access_find(fresh, old_focus) != 0)): ui_atspi_emit_state(b, old_focus, c"focused", 0)
		if (fresh.focused_id != 0): ui_atspi_emit_state(b, fresh.focused_id, c"focused", 1)
	# Live regions announce text added or changed in them (not the first
	# publication's content, as on the web), after the focus change.
	if ((old != 0) && (old.root != 0)):
		walk = fresh.root
		while (walk != 0):
			ui_access_text* said = ui_access_live_change(walk, ui_access_find(old, walk.id))
			if (said != 0): ui_atspi_emit_announcement(b, walk.id, said, ui_access_live_root(walk).live)
			walk = ui_atspi_preorder_next(walk)
	if ((fresh.announcement.length > 0) && (fresh.root != 0)):
		ui_atspi_emit_announcement(b, fresh.root.id, &fresh.announcement, fresh.announcement_live)


/* Connection. */

# The accessibility bus address: $AT_SPI_BUS_ADDRESS, else what the
# session bus's org.a11y.Bus service hands out. A fresh string, or 0.
char* ui_atspi_bus_address():
	char* env = env_get(c"AT_SPI_BUS_ADDRESS")
	if ((env != 0) && (env[0] != 0)): return dbus_strdup(env)
	char* session_address = dbus_session_address()
	if (session_address == 0): return 0
	dbus_conn* session = dbus_open(session_address)
	free(session_address)
	if (session == 0): return 0
	dbus_body(session)
	dbus_message reply
	char* address = 0
	if (dbus_call_sync(session, &reply, 2000, c"org.a11y.Bus", c"/org/a11y/bus", c"org.a11y.Bus", c"GetAddress", 0) == 1):
		dbus_reader r
		dbus_message_reader(&reply, &r)
		char* s = dbus_read_string(&r, 0)
		if ((r.failed == 0) && (s[0] != 0)): address = dbus_strdup(s)
	dbus_message_free(&reply)
	dbus_close(session)
	return address


# Embed the application root in the registry's desktop. The reply (the
# desktop's reference) is collected by ui_access_atspi_dispatch.
void ui_atspi_embed(ui_atspi_bridge* b):
	dbus_buf* out = dbus_body(b.bus)
	ui_atspi_put_ref(b, out, 0)
	b.embed_serial = dbus_call(b.bus, c"org.a11y.atspi.Registry", ui_atspi_root_path(), c"org.a11y.atspi.Socket", c"Embed", c"(so)")


# Connect to the accessibility bus at address (0 = discover it) and
# register as app_name. Returns 0 when there is no reachable bus.
ui_atspi_bridge* ui_access_atspi_open_at(char* address, char* app_name):
	char* found = address
	if (found == 0): found = ui_atspi_bus_address()
	if (found == 0): return 0
	dbus_conn* bus = dbus_open(found)
	if (address == 0): free(found)
	if (bus == 0): return 0
	ui_atspi_bridge* b = new ui_atspi_bridge()
	b.bus = bus
	b.published = 0
	b.app_name = dbus_strdup(app_name)
	b.desktop_name = 0
	b.desktop_path = 0
	b.embed_serial = 0
	b.app_id = 0
	b.origin_x = 0
	b.origin_y = 0
	b.queued = 0
	dbus_buf_init(&b.scratch)
	ui_atspi_embed(b)
	return b


ui_atspi_bridge* ui_access_atspi_open(char* app_name):
	return ui_access_atspi_open_at(0, app_name)


# The window's top-left corner on screen, for screen-coordinate queries.
void ui_access_atspi_set_origin(ui_atspi_bridge* b, int x, int y):
	if (b == 0): return
	b.origin_x = x
	b.origin_y = y


# Copy tree into the bridge and announce the changes since the last
# publication. Queued actions against the old snapshot are dropped, as
# in the other bridges. Returns 0 when the bridge or tree is unusable.
int ui_access_atspi_publish(ui_atspi_bridge* b, ui_access_tree* tree):
	if ((b == 0) || (tree == 0) || (tree.root == 0) || b.bus.failed): return 0
	ui_access_tree* old = b.published
	b.published = ui_access_tree_clone(tree)
	ui_atspi_clear_queue(b)
	ui_atspi_emit_changes(b, old, b.published)
	ui_access_tree_free(old)
	# The announcement is spoken once: consumed from both trees.
	ui_access_announcement_clear(b.published)
	ui_access_announcement_clear(tree)
	return b.bus.failed == 0


# Answer pending queries, then apply queued actions to tree through
# ui_access_dispatch (focus requests that are accepted also move
# tree.focused_id). Call once per frame, before replacing tree. Returns
# the number of actions consumed; -1 once the bus connection is lost.
int ui_access_atspi_dispatch(ui_atspi_bridge* b, ui_access_tree* tree):
	if (b == 0): return 0
	int handled = 0
	while (handled < 256):
		dbus_message m
		int got = dbus_next(b.bus, &m)
		if (got < 0): return 0 - 1
		if (got == 0): break
		if (m.type == DBUS_METHOD_CALL): ui_atspi_handle_call(b, &m)
		else if ((m.type == DBUS_METHOD_RETURN) && (m.reply_serial == b.embed_serial) && (b.embed_serial != 0)):
			dbus_reader r
			dbus_message_reader(&m, &r)
			dbus_read_align(&r, 8)
			char* name = dbus_read_string(&r, 0)
			char* path = dbus_read_string(&r, 0)
			if (r.failed == 0):
				free(b.desktop_name)
				free(b.desktop_path)
				b.desktop_name = dbus_strdup(name)
				b.desktop_path = dbus_strdup(path)
		dbus_message_free(&m)
		handled = handled + 1
	int count = 0
	for i in range(b.queued):
		ui_atspi_request* r = &b.queue[i]
		if (tree != 0):
			int accepted = ui_access_dispatch(tree, r.id, r.action, r.value, r.length)
			if (accepted && (r.action == UI_ACCESS_FOCUS)): tree.focused_id = r.id
		count = count + 1
	ui_atspi_clear_queue(b)
	if (b.bus.failed): return 0 - 1
	return count


# 1 once the registry has embedded the application in its desktop.
int ui_access_atspi_embedded(ui_atspi_bridge* b):
	return (b != 0) && (b.desktop_name != 0)


void ui_access_atspi_close(ui_atspi_bridge* b):
	if (b == 0): return
	if ((b.published != 0) && (b.published.root != 0) && (b.bus.failed == 0)):
		ui_atspi_emit_children(b, 0, c"remove", 0, b.published.root.id)
	ui_atspi_clear_queue(b)
	ui_access_tree_free(b.published)
	dbus_close(b.bus)
	free(b.app_name)
	free(b.desktop_name)
	free(b.desktop_path)
	dbus_buf_free(&b.scratch)
	free(b)
