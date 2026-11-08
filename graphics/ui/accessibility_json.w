# JSON form of an accessibility snapshot (graphics.ui.accessibility),
# for graphics.control's a11y_tree command and tools that want to look
# at what assistive technology would see (docs/projects/wdrive.md).
#
#	{"id":1073741824,"role":"document","name":"","bounds":[x,y,w,h],
#	 "states":["focusable",...],"focused":true,"value":"...",
#	 "children":[...]}
#
# value, description, caret/selection, range, heading level, states,
# focused and children appear only when the node has them. Bounds are
# whole logical pixels in the window's top-left coordinates, the same
# space the control channel's pointer commands use.
import lib.lib
import structures.string
import graphics.ui.rect
import graphics.ui.accessibility


char* ui_access_role_name(int role):
	if (role == UI_ACCESS_DOCUMENT): return c"document"
	if (role == UI_ACCESS_GROUP): return c"group"
	if (role == UI_ACCESS_TEXT): return c"text"
	if (role == UI_ACCESS_HEADING): return c"heading"
	if (role == UI_ACCESS_LINK): return c"link"
	if (role == UI_ACCESS_BUTTON): return c"button"
	if (role == UI_ACCESS_CHECKBOX): return c"checkbox"
	if (role == UI_ACCESS_TEXTBOX): return c"textbox"
	if (role == UI_ACCESS_IMAGE): return c"image"
	if (role == UI_ACCESS_LIST): return c"list"
	if (role == UI_ACCESS_LIST_ITEM): return c"list_item"
	if (role == UI_ACCESS_TABLE): return c"table"
	if (role == UI_ACCESS_ROW): return c"row"
	if (role == UI_ACCESS_CELL): return c"cell"
	if (role == UI_ACCESS_RADIO): return c"radio"
	if (role == UI_ACCESS_SWITCH): return c"switch"
	if (role == UI_ACCESS_COMBOBOX): return c"combobox"
	if (role == UI_ACCESS_TAB_LIST): return c"tab_list"
	if (role == UI_ACCESS_TAB): return c"tab"
	if (role == UI_ACCESS_PROGRESS): return c"progress"
	if (role == UI_ACCESS_DIALOG): return c"dialog"
	if (role == UI_ACCESS_SLIDER): return c"slider"
	return c"unknown"


# Append data[0..length) as a JSON string (UTF-8 passes through).
void ui_access_json_text(string_builder* out, char* data, int length):
	string_append_char(out, '"')
	for i in range(length):
		int c = data[i] & 255
		if ((c == '"') || (c == 92)):
			string_append_char(out, 92)
			string_append_char(out, c)
		else if (c == '\n'): string_append(out, c"\\n")
		else if (c == '\t'): string_append(out, c"\\t")
		else if (c == '\r'): string_append(out, c"\\r")
		else if (c < 32):
			string_append(out, c"\\u00")
			string_append_char(out, c"0123456789abcdef"[c >> 4])
			string_append_char(out, c"0123456789abcdef"[c & 15])
		else: string_append_char(out, c)
	string_append_char(out, '"')


void ui_access_json_field(string_builder* out, char* key):
	string_append(out, c",\"")
	string_append(out, key)
	string_append(out, c"\":")


void ui_access_json_state(string_builder* out, int* first, char* name):
	if (first[0] == 0): string_append_char(out, ',')
	first[0] = 0
	string_append_char(out, '"')
	string_append(out, name)
	string_append_char(out, '"')


void ui_access_json_states(string_builder* out, int states):
	if (states == 0): return
	ui_access_json_field(out, c"states")
	string_append_char(out, '[')
	int first = 1
	if (states & UI_ACCESS_DISABLED): ui_access_json_state(out, &first, c"disabled")
	if (states & UI_ACCESS_CHECKED): ui_access_json_state(out, &first, c"checked")
	if (states & UI_ACCESS_SELECTED): ui_access_json_state(out, &first, c"selected")
	if (states & UI_ACCESS_EXPANDED): ui_access_json_state(out, &first, c"expanded")
	if (states & UI_ACCESS_READONLY): ui_access_json_state(out, &first, c"readonly")
	if (states & UI_ACCESS_HIDDEN): ui_access_json_state(out, &first, c"hidden")
	if (states & UI_ACCESS_FOCUSABLE): ui_access_json_state(out, &first, c"focusable")
	if (states & UI_ACCESS_MULTISELECTABLE): ui_access_json_state(out, &first, c"multiselectable")
	if (states & UI_ACCESS_HEADER): ui_access_json_state(out, &first, c"header")
	string_append_char(out, ']')


void ui_access_json_node(string_builder* out, ui_access_tree* tree, ui_access_node* n, int depth):
	string_append(out, c"{\"id\":")
	string_append_int(out, n.id)
	ui_access_json_field(out, c"role")
	string_append_char(out, '"')
	string_append(out, ui_access_role_name(n.role))
	string_append_char(out, '"')
	ui_access_json_field(out, c"name")
	ui_access_text name
	ui_access_effective_name(n, &name)
	ui_access_json_text(out, name.data, name.length)
	if (n.value.length > 0):
		ui_access_json_field(out, c"value")
		ui_access_json_text(out, n.value.data, n.value.length)
	if (n.description.length > 0):
		ui_access_json_field(out, c"description")
		ui_access_json_text(out, n.description.data, n.description.length)
	ui_access_json_field(out, c"bounds")
	string_append_char(out, '[')
	string_append_int(out, cast(int, n.bounds.x))
	string_append_char(out, ',')
	string_append_int(out, cast(int, n.bounds.y))
	string_append_char(out, ',')
	string_append_int(out, cast(int, n.bounds.w))
	string_append_char(out, ',')
	string_append_int(out, cast(int, n.bounds.h))
	string_append_char(out, ']')
	ui_access_json_states(out, n.states)
	if (n.heading_level > 0):
		ui_access_json_field(out, c"level")
		string_append_int(out, n.heading_level)
	if (n.caret >= 0):
		ui_access_json_field(out, c"caret")
		string_append_int(out, n.caret)
	if ((n.selection_start >= 0) && (n.selection_end > n.selection_start)):
		ui_access_json_field(out, c"selection")
		string_append_char(out, '[')
		string_append_int(out, n.selection_start)
		string_append_char(out, ',')
		string_append_int(out, n.selection_end)
		string_append_char(out, ']')
	if (n.has_range):
		char[32] number
		ui_access_json_field(out, c"range")
		string_append_char(out, '[')
		int k = ui_access_number_format(&number[0], n.range_min)
		string_append_bytes(out, &number[0], k)
		string_append_char(out, ',')
		k = ui_access_number_format(&number[0], n.range_now)
		string_append_bytes(out, &number[0], k)
		string_append_char(out, ',')
		k = ui_access_number_format(&number[0], n.range_max)
		string_append_bytes(out, &number[0], k)
		string_append_char(out, ']')
	if ((tree.focused_id != 0) && (tree.focused_id == n.id)): string_append(out, c",\"focused\":true")
	# Snapshots are budgeted (max_nodes), so depth stays bounded; the cap
	# only guards a malformed tree.
	if ((n.first_child != 0) && (depth < 256)):
		ui_access_json_field(out, c"children")
		string_append_char(out, '[')
		ui_access_node* child = n.first_child
		while (child != 0):
			ui_access_json_node(out, tree, child, depth + 1)
			child = child.next_sibling
			if (child != 0): string_append_char(out, ',')
		string_append_char(out, ']')
	string_append_char(out, '}')


# Malloc'd JSON for the whole snapshot; "null" when it has no root.
char* ui_access_tree_json(ui_access_tree* tree):
	string_builder* out = string_new()
	if ((tree == 0) || (tree.root == 0)): string_append(out, c"null")
	else: ui_access_json_node(out, tree, tree.root, 0)
	char* text = out.data
	free(out)
	return text
