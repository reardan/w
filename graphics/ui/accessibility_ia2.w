/*
graphics.ui.accessibility_ia2: IAccessible2's relations and its
companion interfaces (#911) for the UI Automation / MSAA bridge, part of
graphics.ui.accessibility_uia: that file imports this one after its
element plumbing (elements, interface kinds, BSTRs, VARIANTs, the
action queue, the basic IAccessible2 methods and the vtable helpers)
and before ui_uia_init, so this file builds on those definitions and
is not compiled on its own.

Screen readers that read IAccessible2 (NVDA, JAWS) reach every
interface below by QueryInterface on a node's IAccessible2 (or
IServiceProvider::QueryService), as the IA2 specification has it:

- IAccessible2's relations (get_nRelations, get_relation,
  get_relations) as IAccessibleRelation objects, and IAccessible2_2's
  get_relationTargetsOfType, from the model's relations
  (ui_access_add_relation) and their reverses: labelledBy / labelFor,
  describedBy / descriptionFor, controllerFor / controlledBy, memberOf.
  IAccessible2_2's get_attribute and get_accessibleWithCaret, and
  IAccessible2_3's get_selectionRanges, complete the revisions the
  vtable answers for.
- IAccessibleText on textboxes, over the snapshot's glyph boxes, text
  attributes and selections; IAccessibleEditableText on editable ones,
  whose edits queue UI_ACCESS_SET_VALUE with the edited text.
- IAccessibleTable2 on tables and IAccessibleTableCell on their data
  cells, from graphics.ui.accessibility_table (header row, row headers,
  spans and row selection).
- IAccessibleValue on progress bars and sliders, from the node's range
  values; a slider offering UI_ACCESS_SET_VALUE takes setCurrentValue.

Offsets count characters (code points) of the node's value, like every
other bridge; IA2_TEXT_OFFSET_LENGTH (-1) is the text's length and
IA2_TEXT_OFFSET_CARET (-2) the caret. Interfaces and constants follow
the IAccessible2 1.3 IDL (AccessibleText.idl, AccessibleTable2.idl, ...).
*/

const int IA2_TEXT_OFFSET_LENGTH = 0 - 1
const int IA2_TEXT_OFFSET_CARET = 0 - 2
const int IA2_TEXT_BOUNDARY_CHAR = 0
const int IA2_TEXT_BOUNDARY_WORD = 1
const int IA2_TEXT_BOUNDARY_SENTENCE = 2
const int IA2_TEXT_BOUNDARY_PARAGRAPH = 3
const int IA2_TEXT_BOUNDARY_LINE = 4
const int IA2_TEXT_BOUNDARY_ALL = 5
const int IA2_COORDTYPE_SCREEN_RELATIVE = 0
const int IA2_COORDTYPE_PARENT_RELATIVE = 1
const int IA2_SCROLL_TYPE_TOP_LEFT = 0
const int IA2_SCROLL_TYPE_BOTTOM_RIGHT = 1
const int IA2_SCROLL_TYPE_TOP_EDGE = 2
const int IA2_SCROLL_TYPE_BOTTOM_EDGE = 3
const int IA2_SCROLL_TYPE_ANYWHERE = 6
const int IA2_EVENT_TEXT_CARET_MOVED = 0x11b
const int IA2_EVENT_TEXT_INSERTED = 0x11e
const int IA2_EVENT_TEXT_REMOVED = 0x11f
const int IA2_EVENT_TEXT_SELECTION_CHANGED = 0x121


/* IAccessibleRelation: its own COM object, holding one reference to the
element it relates from. */

struct ui_ia2_relation_obj:
	int vtbl
	int element                 # ui_uia_element*
	int kind                    # a UI_ACCESS_REL_* or its reverse
	int refs


# The IA2 relation type string of kind.
char* ui_ia2_relation_name(int kind):
	if (kind == UI_ACCESS_REL_LABELLED_BY): return c"labelledBy"
	if (kind == UI_ACCESS_REL_LABEL_FOR): return c"labelFor"
	if (kind == UI_ACCESS_REL_DESCRIBED_BY): return c"describedBy"
	if (kind == UI_ACCESS_REL_DESCRIPTION_FOR): return c"descriptionFor"
	if (kind == UI_ACCESS_REL_CONTROLLER_FOR): return c"controllerFor"
	if (kind == UI_ACCESS_REL_CONTROLLED_BY): return c"controlledBy"
	if (kind == UI_ACCESS_REL_MEMBER_OF): return c"memberOf"
	return c""


# The relation kind an IA2 type string names, 0 for none we publish.
int ui_ia2_relation_kind(char* name):
	for k in range(1, UI_ACCESS_REL_LAST + 1):
		if (strcmp(name, ui_ia2_relation_name(k)) == 0): return k
		if ((k != UI_ACCESS_REL_MEMBER_OF) && (strcmp(name, ui_ia2_relation_name(0 - k)) == 0)): return 0 - k
	return 0


int ui_ia2_relation_new(ui_uia_element* e, int kind):
	ui_ia2_relation_obj* r = new ui_ia2_relation_obj()
	r.vtbl = ui_uia_relation_vtable
	r.element = cast(int, e)
	e.refs = e.refs + 1
	r.kind = kind
	r.refs = 1
	return cast(int, r)


int ui_ia2_relation_query(int self, int riid, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	if (riid == 0): return UIA_E_INVALIDARG
	if (!ui_uia_guid_is(riid, 0) && !ui_uia_guid_is(riid, UI_UIA_RELATION_IID)): return UIA_E_NOINTERFACE
	ui_ia2_relation_obj* r = cast(ui_ia2_relation_obj*, self)
	r.refs = r.refs + 1
	save_int64(cast(char*, out), self)
	return UIA_S_OK


int ui_ia2_relation_add_ref(int self):
	ui_ia2_relation_obj* r = cast(ui_ia2_relation_obj*, self)
	r.refs = r.refs + 1
	return r.refs


int ui_ia2_relation_release(int self):
	ui_ia2_relation_obj* r = cast(ui_ia2_relation_obj*, self)
	if (r.refs > 0): r.refs = r.refs - 1
	int left = r.refs
	if (left == 0):
		ui_uia_release(ui_uia_iface_ptr(cast(ui_uia_element*, r.element), UI_UIA_SIMPLE))
		free(r)
	return left


# The relation's element's node, or 0 once it is gone.
ui_access_node* ui_ia2_relation_node(int self):
	ui_ia2_relation_obj* r = cast(ui_ia2_relation_obj*, self)
	return ui_uia_node(cast(ui_uia_element*, r.element))


int ui_ia2_relation_type(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	if (ui_ia2_relation_node(self) == 0): return UIA_E_FAIL
	ui_ia2_relation_obj* r = cast(ui_ia2_relation_obj*, self)
	char* name = ui_ia2_relation_name(r.kind)
	save_int64(cast(char*, out), ui_uia_bstr(name, strlen(name)))
	return UIA_S_OK


int ui_ia2_relation_targets_count(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	ui_access_node* n = ui_ia2_relation_node(self)
	if (n == 0): return UIA_E_FAIL
	ui_ia2_relation_obj* r = cast(ui_ia2_relation_obj*, self)
	ui_uia_bridge* b = ui_uia_bridge_of(cast(ui_uia_element*, r.element))
	ui_access_node* t = 0
	save_int32(cast(char*, out), ui_access_related(b.published, n, r.kind, 0, &t))
	return UIA_S_OK


# get_target: target index as its IAccessible2 (an IUnknown).
int ui_ia2_relation_target(int self, int index, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_access_node* n = ui_ia2_relation_node(self)
	if (n == 0): return UIA_E_FAIL
	ui_ia2_relation_obj* r = cast(ui_ia2_relation_obj*, self)
	ui_uia_bridge* b = ui_uia_bridge_of(cast(ui_uia_element*, r.element))
	ui_access_node* t = 0
	ui_access_related(b.published, n, r.kind, ui_uia_lo32(index), &t)
	if (t == 0): return UIA_E_INVALIDARG
	return ui_uia_hand_out(b, t.id, UI_UIA_IA2, out)


# get_targets: up to max targets into the caller's array.
int ui_ia2_relation_targets(int self, int max, int targets, int count):
	if ((targets == 0) || (count == 0)): return UIA_E_POINTER
	save_int32(cast(char*, count), 0)
	ui_access_node* n = ui_ia2_relation_node(self)
	if (n == 0): return UIA_E_FAIL
	int limit = ui_uia_lo32(max)
	if (limit < 0): return UIA_E_INVALIDARG
	ui_ia2_relation_obj* r = cast(ui_ia2_relation_obj*, self)
	ui_uia_bridge* b = ui_uia_bridge_of(cast(ui_uia_element*, r.element))
	ui_access_node* t = 0
	int total = ui_access_related(b.published, n, r.kind, 0, &t)
	int k = 0
	while ((k < total) && (k < limit)):
		ui_access_related(b.published, n, r.kind, k, &t)
		ui_uia_hand_out(b, t.id, UI_UIA_IA2, targets + k * 8)
		k = k + 1
	save_int32(cast(char*, count), k)
	return UIA_S_OK


/* IAccessible2's relations and the _2 / _3 revisions. */

ui_uia_bridge* ui_ia2_bridge(int self):
	return ui_uia_bridge_of(ui_uia_self(self))


int ui_ia2_n_relations(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	if (n == 0): return UIA_E_FAIL
	int kind = 0
	save_int32(cast(char*, out), ui_access_relation_kinds(ui_ia2_bridge(self).published, n, 0, &kind))
	return UIA_S_OK


int ui_ia2_relation(int self, int index, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_FAIL
	int kind = 0
	ui_access_relation_kinds(ui_ia2_bridge(self).published, n, ui_uia_lo32(index), &kind)
	if (kind == 0): return UIA_E_INVALIDARG
	save_int64(cast(char*, out), ui_ia2_relation_new(e, kind))
	return UIA_S_OK


# get_relations: up to max relation objects into the caller's array;
# S_FALSE when there are none.
int ui_ia2_relations(int self, int max, int items, int count):
	if ((items == 0) || (count == 0)): return UIA_E_POINTER
	save_int32(cast(char*, count), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_FAIL
	int limit = ui_uia_lo32(max)
	if (limit < 0): return UIA_E_INVALIDARG
	int kind = 0
	ui_access_tree* tree = ui_ia2_bridge(self).published
	int total = ui_access_relation_kinds(tree, n, 0, &kind)
	int k = 0
	while ((k < total) && (k < limit)):
		ui_access_relation_kinds(tree, n, k, &kind)
		save_int64(cast(char*, items + k * 8), ui_ia2_relation_new(e, kind))
		k = k + 1
	save_int32(cast(char*, count), k)
	if (k == 0): return UIA_S_FALSE
	return UIA_S_OK


# get_relationTargetsOfType (IAccessible2_2): the targets of one
# relation type, in a CoTaskMemAlloc'd array (max 0: all of them).
int ui_ia2_relation_targets_of_type(int self, int type, int max, int targets, int count):
	if ((targets == 0) || (count == 0)): return UIA_E_POINTER
	save_int64(cast(char*, targets), 0)
	save_int32(cast(char*, count), 0)
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	if (n == 0): return UIA_E_FAIL
	if (type == 0): return UIA_E_INVALIDARG
	int length = 0
	char* name = ui_uia_utf8(type, &length)
	int kind = ui_ia2_relation_kind(name)
	free(name)
	if (kind == 0): return UIA_S_FALSE
	ui_uia_bridge* b = ui_ia2_bridge(self)
	ui_access_node* t = 0
	int total = ui_access_related(b.published, n, kind, 0, &t)
	int limit = ui_uia_lo32(max)
	if ((limit > 0) && (total > limit)): total = limit
	if (total == 0): return UIA_S_FALSE
	int array = CoTaskMemAlloc(total * 8)
	if (array == 0): return UIA_E_FAIL
	for k in range(total):
		ui_access_related(b.published, n, kind, k, &t)
		ui_uia_hand_out(b, t.id, UI_UIA_IA2, array + k * 8)
	save_int64(cast(char*, targets), array)
	save_int32(cast(char*, count), total)
	return UIA_S_OK


# get_attribute (IAccessible2_2): one object attribute by name; only
# "level" (headings) is one the snapshot has.
int ui_ia2_attribute(int self, int name, int out):
	if (out == 0): return UIA_E_POINTER
	char* v = cast(char*, out)
	ui_uia_variant_clear(v)
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	if (n == 0): return UIA_E_FAIL
	if (name == 0): return UIA_E_INVALIDARG
	int length = 0
	char* text = ui_uia_utf8(name, &length)
	int known = (strcmp(text, c"level") == 0) && (n.role == UI_ACCESS_HEADING) && (n.heading_level > 0)
	free(text)
	if (!known): return UIA_S_FALSE
	ui_uia_variant_i4(v, n.heading_level)
	return UIA_S_OK


# get_accessibleWithCaret (IAccessible2_2): the focused text node under
# this one (or this one) and its caret; S_FALSE when the caret is
# elsewhere.
int ui_ia2_with_caret(int self, int out, int caret):
	if ((out == 0) || (caret == 0)): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	save_int32(cast(char*, caret), 0 - 1)
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	if (n == 0): return UIA_E_FAIL
	ui_uia_bridge* b = ui_ia2_bridge(self)
	ui_access_node* f = ui_access_find(b.published, b.published.focused_id)
	if ((f == 0) || (f.caret < 0) || ((f != n) && !ui_msaa_is_ancestor(n, f))): return UIA_S_FALSE
	save_int32(cast(char*, caret), f.caret)
	return ui_uia_hand_out(b, f.id, UI_UIA_IA2, out)


# get_selectionRanges (IAccessible2_3): every text selection of this
# node as IA2Range {anchor, anchorOffset, active, activeOffset} records
# (32 bytes each) in a CoTaskMemAlloc'd array; S_FALSE for none.
int ui_ia2_selection_ranges(int self, int ranges, int count):
	if ((ranges == 0) || (count == 0)): return UIA_E_POINTER
	save_int64(cast(char*, ranges), 0)
	save_int32(cast(char*, count), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_FAIL
	int total = ui_access_selection_total(n)
	if (total == 0): return UIA_S_FALSE
	int array = CoTaskMemAlloc(total * 32)
	if (array == 0): return UIA_E_FAIL
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	for k in range(total):
		int start = 0
		int end = 0
		ui_access_selection_range(n, k, &start, &end)
		int anchor = start
		int active = end
		# The primary selection keeps its direction.
		if ((k == 0) && ui_access_has_selection(n) && (n.caret == n.selection_start)):
			anchor = end
			active = start
		char* r = cast(char*, array + k * 32)
		for i in range(32): r[i] = 0
		ui_uia_hand_out(b, n.id, UI_UIA_IA2, array + k * 32)
		save_int32(&r[8], anchor)
		ui_uia_hand_out(b, n.id, UI_UIA_IA2, array + k * 32 + 16)
		save_int32(&r[24], active)
	save_int64(cast(char*, ranges), array)
	save_int32(cast(char*, count), total)
	return UIA_S_OK


/* IAccessibleText. */

# The node behind an IA2 text interface (0 when gone), with its text
# length in *count.
ui_access_node* ui_ia2_text_node(int self, int* count):
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	count[0] = 0
	if (n != 0): count[0] = ui_access_text_count(n)
	return n


# An IA2 offset: -1 the length, -2 the caret; else itself.
int ui_ia2_offset(ui_access_node* n, int offset, int count):
	int k = ui_uia_lo32(offset)
	if (k == IA2_TEXT_OFFSET_LENGTH): return count
	if (k == IA2_TEXT_OFFSET_CARET): return ui_access_caret_or_zero(n)
	return k


void ui_ia2_put_text(int out, ui_access_node* n, int start, int end):
	int from = ui_access_char_byte(n.value.data, n.value.length, start)
	int to = ui_access_char_byte(n.value.data, n.value.length, end)
	save_int64(cast(char*, out), ui_uia_bstr(&n.value.data[from], to - from))


# Queue a selection edit, as AT-SPI's text interface does: the first
# selection replaces the caret, further ones need a node taking
# several (UI_ACCESS_SET_SELECTIONS). k = total adds, start < 0
# removes.
int ui_ia2_selection_edit(int self, ui_access_node* n, int k, int start, int end):
	ui_uia_bridge* b = ui_ia2_bridge(self)
	int total = ui_access_selection_total(n)
	if ((total <= 1) && (k == 0) && (start >= 0)):
		char[32] payload
		int length = ui_access_selection_format(&payload[0], start, end)
		if (ui_uia_enqueue(b, n, UI_ACCESS_SET_SELECTION, &payload[0], length)): return UIA_S_OK
		return UIA_E_FAIL
	if ((total == 1) && (start < 0)):
		int caret = ui_access_caret_or_zero(n)
		char[32] payload
		int length = ui_access_selection_format(&payload[0], caret, caret)
		if (ui_uia_enqueue(b, n, UI_ACCESS_SET_SELECTION, &payload[0], length)): return UIA_S_OK
		return UIA_E_FAIL
	if ((n.actions & UI_ACCESS_SET_SELECTIONS) == 0): return UIA_E_INVALIDARG
	char* payload = 0
	int length = ui_access_selections_edit(n, k, start, end, &payload)
	if (length <= 0): return UIA_E_INVALIDARG
	int ok = ui_uia_enqueue(b, n, UI_ACCESS_SET_SELECTIONS, payload, length)
	free(payload)
	if ok: return UIA_S_OK
	return UIA_E_FAIL


int ui_ia2_text_add_selection(int self, int start, int end):
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	int s = ui_ia2_offset(n, start, count)
	int e = ui_ia2_offset(n, end, count)
	if (e < s):
		int t = s
		s = e
		e = t
	if ((s < 0) || (e > count) || (s == e)): return UIA_E_INVALIDARG
	return ui_ia2_selection_edit(self, n, ui_access_selection_total(n), s, e)


# Append "name:value;" to buf (cap bytes, NUL-terminated), escaping the
# IA2 attribute syntax characters in value with a backslash.
void ui_ia2_attr_put(char* buf, int cap, char* name, char* value, int length):
	int at = strlen(buf)
	int need = strlen(name) + length * 2 + 3
	if (at + need >= cap): return
	strcpy(&buf[at], name)
	at = at + strlen(name)
	buf[at] = ':'
	at = at + 1
	for i in range(length):
		int c = value[i]
		if ((c == '\\') || (c == ':') || (c == ';') || (c == ',') || (c == '=')):
			buf[at] = '\\'
			at = at + 1
		buf[at] = c
		at = at + 1
	buf[at] = ';'
	buf[at + 1] = 0


void ui_ia2_attr_number(char* buf, int cap, char* name, int v, char* suffix):
	char* digits = itoa(v)
	char[32] text
	strcpy(&text[0], digits)
	strcpy(&text[strlen(&text[0])], suffix)
	free(digits)
	ui_ia2_attr_put(buf, cap, name, &text[0], strlen(&text[0]))


void ui_ia2_attr_color(char* buf, int cap, char* name, int rgb):
	char[32] text
	strcpy(&text[0], c"rgb(")
	for k in range(3):
		char* digits = itoa((rgb >> (16 - k * 8)) & 255)
		strcpy(&text[strlen(&text[0])], digits)
		free(digits)
		if (k < 2): strcpy(&text[strlen(&text[0])], c",")
	strcpy(&text[strlen(&text[0])], c")")
	# rgb(...) keeps its commas: the IA2 colour syntax.
	int at = strlen(buf)
	if (at + strlen(name) + strlen(&text[0]) + 3 >= cap): return
	strcpy(&buf[at], name)
	strcpy(&buf[strlen(buf)], c":")
	strcpy(&buf[strlen(buf)], &text[0])
	strcpy(&buf[strlen(buf)], c";")


# The IA2 text attribute string of attrs a (the IA2 text attributes
# specification's names: font-family, font-size, font-weight,
# font-style, text-underline-style/-type, color, background-color).
void ui_ia2_attr_string(ui_access_text_attrs* a, char* buf, int cap):
	buf[0] = 0
	if (a == 0): return
	if (a.family.length > 0): ui_ia2_attr_put(buf, cap, c"font-family", a.family.data, a.family.length)
	if (a.size > 0): ui_ia2_attr_number(buf, cap, c"font-size", a.size, c"pt")
	if (a.weight > 0): ui_ia2_attr_number(buf, cap, c"font-weight", a.weight, c"")
	if (a.italic): ui_ia2_attr_put(buf, cap, c"font-style", c"italic", 6)
	else: ui_ia2_attr_put(buf, cap, c"font-style", c"normal", 6)
	if (a.underline):
		ui_ia2_attr_put(buf, cap, c"text-underline-style", c"solid", 5)
		ui_ia2_attr_put(buf, cap, c"text-underline-type", c"single", 6)
	if (a.fg >= 0): ui_ia2_attr_color(buf, cap, c"color", a.fg)
	if (a.bg >= 0): ui_ia2_attr_color(buf, cap, c"background-color", a.bg)


# get_attributes: the attributes at offset and the run they hold over.
int ui_ia2_text_attributes(int self, int offset, int start, int end, int out):
	if ((start == 0) || (end == 0) || (out == 0)): return UIA_E_POINTER
	save_int32(cast(char*, start), 0)
	save_int32(cast(char*, end), 0)
	save_int64(cast(char*, out), 0)
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	int k = ui_ia2_offset(n, offset, count)
	if ((k < 0) || (k > count)): return UIA_E_INVALIDARG
	int from = 0
	int to = 0
	ui_access_text_attrs* a = ui_access_attrs_at(n, k, &from, &to)
	save_int32(cast(char*, start), from)
	save_int32(cast(char*, end), to)
	char[640] text
	ui_ia2_attr_string(a, &text[0], 640)
	if (text[0] == 0): return UIA_S_FALSE
	save_int64(cast(char*, out), ui_uia_bstr(&text[0], strlen(&text[0])))
	return UIA_S_OK


int ui_ia2_text_caret(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0 - 1)
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	if (n.caret < 0): return UIA_S_FALSE
	save_int32(cast(char*, out), n.caret)
	if (ui_ia2_bridge(self).published.focused_id != n.id): return UIA_S_FALSE
	return UIA_S_OK


# Snapshot box b of n in IA2 coordinates: screen pixels, or relative to
# the parent's bounds.
void ui_ia2_box(int self, ui_access_node* n, ui_rect box, int coord, int* x, int* y, int* w, int* h):
	ui_uia_bridge* b = ui_ia2_bridge(self)
	float64 ox = 0.0
	float64 oy = 0.0
	if (ui_uia_lo32(coord) == IA2_COORDTYPE_PARENT_RELATIVE):
		if (n.parent != 0):
			ox = 0.0 - cast(float64, n.parent.bounds.x) * b.scale
			oy = 0.0 - cast(float64, n.parent.bounds.y) * b.scale
	else:
		int sx = 0
		int sy = 0
		ui_uia_origin(b, &sx, &sy)
		ox = cast(float64, sx)
		oy = cast(float64, sy)
	x[0] = cast(int, cast(float64, box.x) * b.scale + ox)
	y[0] = cast(int, cast(float64, box.y) * b.scale + oy)
	w[0] = cast(int, cast(float64, box.w) * b.scale + 0.5)
	h[0] = cast(int, cast(float64, box.h) * b.scale + 0.5)


int ui_ia2_text_extents(int self, int offset, int coord, int x, int y, int w, int h):
	if ((x == 0) || (y == 0) || (w == 0) || (h == 0)): return UIA_E_POINTER
	save_int32(cast(char*, x), 0)
	save_int32(cast(char*, y), 0)
	save_int32(cast(char*, w), 0)
	save_int32(cast(char*, h), 0)
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	int k = ui_ia2_offset(n, offset, count)
	if ((k < 0) || (k > count)): return UIA_E_INVALIDARG
	ui_rect box = n.bounds
	if (ui_access_has_glyphs(n)): ui_access_char_box(n, k, &box)
	int[4] v
	ui_ia2_box(self, n, box, coord, &v[0], &v[1], &v[2], &v[3])
	save_int32(cast(char*, x), v[0])
	save_int32(cast(char*, y), v[1])
	save_int32(cast(char*, w), v[2])
	save_int32(cast(char*, h), v[3])
	return UIA_S_OK


int ui_ia2_text_n_selections(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	save_int32(cast(char*, out), ui_access_selection_total(n))
	return UIA_S_OK


# get_offsetAtPoint: the character under (x, y); S_FALSE and -1 off the
# text.
int ui_ia2_text_offset_at_point(int self, int x, int y, int coord, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0 - 1)
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	ui_uia_bridge* b = ui_ia2_bridge(self)
	float64 px = cast(float64, ui_uia_lo32(x))
	float64 py = cast(float64, ui_uia_lo32(y))
	if (ui_uia_lo32(coord) == IA2_COORDTYPE_PARENT_RELATIVE):
		if (n.parent != 0):
			px = px + cast(float64, n.parent.bounds.x) * b.scale
			py = py + cast(float64, n.parent.bounds.y) * b.scale
		px = px / b.scale
		py = py / b.scale
	else:
		int sx = 0
		int sy = 0
		ui_uia_origin(b, &sx, &sy)
		px = (px - cast(float64, sx)) / b.scale
		py = (py - cast(float64, sy)) / b.scale
	int k = ui_access_offset_at_point(n, cast(float32, px), cast(float32, py))
	if (k < 0): return UIA_S_FALSE
	save_int32(cast(char*, out), k)
	return UIA_S_OK


int ui_ia2_text_selection(int self, int index, int start, int end):
	if ((start == 0) || (end == 0)): return UIA_E_POINTER
	save_int32(cast(char*, start), 0)
	save_int32(cast(char*, end), 0)
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	int s = 0
	int e = 0
	if (!ui_access_selection_range(n, ui_uia_lo32(index), &s, &e)): return UIA_E_INVALIDARG
	save_int32(cast(char*, start), s)
	save_int32(cast(char*, end), e)
	return UIA_S_OK


int ui_ia2_text_get(int self, int start, int end, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	int s = ui_ia2_offset(n, start, count)
	int e = ui_ia2_offset(n, end, count)
	if (e < s):
		int t = s
		s = e
		e = t
	if ((s < 0) || (e > count)): return UIA_E_INVALIDARG
	ui_ia2_put_text(out, n, s, e)
	return UIA_S_OK


# 1 when an IA2 unit starts at character p: words and paragraphs as the
# UIA text ranges count them, lines also where the glyph boxes wrap.
int ui_ia2_boundary(ui_access_node* n, int* cp, int count, int unit, int p):
	if ((p <= 0) || (p >= count)): return 1
	if (unit == IA2_TEXT_BOUNDARY_CHAR): return 1
	if (unit == IA2_TEXT_BOUNDARY_ALL): return 0
	if (unit == IA2_TEXT_BOUNDARY_WORD): return ui_uia_boundary(n, cp, count, TextUnit_Word, p)
	if (cp[p - 1] == 10): return 1
	if ((unit == IA2_TEXT_BOUNDARY_LINE) && ui_access_has_glyphs(n)): return n.char_boxes[p].y != n.char_boxes[p - 1].y
	return 0


int ui_ia2_unit_start(ui_access_node* n, int* cp, int count, int unit, int p):
	while ((p > 0) && !ui_ia2_boundary(n, cp, count, unit, p)): p = p - 1
	return p


int ui_ia2_unit_end(ui_access_node* n, int* cp, int count, int unit, int p):
	if (p >= count): return count
	int q = p + 1
	while ((q < count) && !ui_ia2_boundary(n, cp, count, unit, q)): q = q + 1
	return q


# get_textBeforeOffset (which -1), get_textAtOffset (0) and
# get_textAfterOffset (1): the unit before, containing or after
# offset. The end of the text belongs to the last line or paragraph
# (an empty one after a final newline).
int ui_ia2_text_unit(int self, int offset, int boundary, int start, int end, int out, int which):
	if ((start == 0) || (end == 0) || (out == 0)): return UIA_E_POINTER
	save_int32(cast(char*, start), 0)
	save_int32(cast(char*, end), 0)
	save_int64(cast(char*, out), 0)
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	int unit = ui_uia_lo32(boundary)
	if (unit == IA2_TEXT_BOUNDARY_SENTENCE): return UIA_S_FALSE
	if ((unit < 0) || (unit > IA2_TEXT_BOUNDARY_ALL)): return UIA_E_INVALIDARG
	int p = ui_ia2_offset(n, offset, count)
	if ((p < 0) || (p > count)): return UIA_E_INVALIDARG
	int total = 0
	int* cp = ui_uia_codes(n, &total)
	int s = 0
	int e = 0
	if (unit == IA2_TEXT_BOUNDARY_ALL):
		s = 0
		e = total
		if (which != 0):
			s = 0
			e = 0
	else:
		int q = p
		int at_end = q >= total
		if (at_end && (total > 0) && (unit != IA2_TEXT_BOUNDARY_CHAR) && (cp[total - 1] != 10)): q = total - 1
		if ((q >= total) && (which == 0)):
			s = total
			e = total
		else:
			s = ui_ia2_unit_start(n, cp, total, unit, q)
			e = ui_ia2_unit_end(n, cp, total, unit, s)
			if (q >= total):
				s = total
				e = total
			if (which < 0):
				if (s == 0):
					e = 0
				else:
					e = s
					s = ui_ia2_unit_start(n, cp, total, unit, s - 1)
			if (which > 0):
				if (e >= total):
					s = total
					e = total
				else:
					s = e
					e = ui_ia2_unit_end(n, cp, total, unit, s)
	free(cast(char*, cp))
	save_int32(cast(char*, start), s)
	save_int32(cast(char*, end), e)
	ui_ia2_put_text(out, n, s, e)
	if (s == e): return UIA_S_FALSE
	return UIA_S_OK


int ui_ia2_text_before(int self, int offset, int boundary, int start, int end, int out):
	return ui_ia2_text_unit(self, offset, boundary, start, end, out, 0 - 1)


int ui_ia2_text_after(int self, int offset, int boundary, int start, int end, int out):
	return ui_ia2_text_unit(self, offset, boundary, start, end, out, 1)


int ui_ia2_text_at(int self, int offset, int boundary, int start, int end, int out):
	return ui_ia2_text_unit(self, offset, boundary, start, end, out, 0)


int ui_ia2_text_remove_selection(int self, int index):
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	int k = ui_uia_lo32(index)
	if ((k < 0) || (k >= ui_access_selection_total(n))): return UIA_E_INVALIDARG
	return ui_ia2_selection_edit(self, n, k, 0 - 1, 0 - 1)


int ui_ia2_text_set_caret(int self, int offset):
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	int k = ui_ia2_offset(n, offset, count)
	if ((k < 0) || (k > count)): return UIA_E_INVALIDARG
	char[32] payload
	int length = ui_access_selection_format(&payload[0], k, k)
	if (ui_uia_enqueue(ui_ia2_bridge(self), n, UI_ACCESS_SET_SELECTION, &payload[0], length)): return UIA_S_OK
	return UIA_E_FAIL


int ui_ia2_text_set_selection(int self, int index, int start, int end):
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	int k = ui_uia_lo32(index)
	int s = ui_ia2_offset(n, start, count)
	int e = ui_ia2_offset(n, end, count)
	if (e < s):
		int t = s
		s = e
		e = t
	int total = ui_access_selection_total(n)
	if ((s < 0) || (e > count) || (k < 0) || ((k >= total) && !((k == 0) && (total == 0)))): return UIA_E_INVALIDARG
	return ui_ia2_selection_edit(self, n, k, s, e)


int ui_ia2_text_count(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	save_int32(cast(char*, out), count)
	return UIA_S_OK


# scrollSubstringTo / scrollSubstringToPoint: a SCROLL_TO request for
# a node that scrolls (ui_textarea); S_OK with nothing to do otherwise.
int ui_ia2_scroll_range(int self, int start, int end, int align):
	int count = 0
	ui_access_node* n = ui_ia2_text_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	int s = ui_ia2_offset(n, start, count)
	int e = ui_ia2_offset(n, end, count)
	if (e < s):
		int t = s
		s = e
		e = t
	if ((s < 0) || (e > count)): return UIA_E_INVALIDARG
	if ((n.actions & UI_ACCESS_SCROLL_TO) == 0): return UIA_S_OK
	char[48] payload
	int length = ui_access_scroll_format(&payload[0], s, e, align)
	if (ui_uia_enqueue(ui_ia2_bridge(self), n, UI_ACCESS_SCROLL_TO, &payload[0], length)): return UIA_S_OK
	return UIA_E_FAIL


# The SCROLL_TO alignment of an IA2ScrollType.
int ui_ia2_scroll_align(int type):
	int t = ui_uia_lo32(type)
	if ((t == IA2_SCROLL_TYPE_TOP_LEFT) || (t == IA2_SCROLL_TYPE_TOP_EDGE)): return UI_ACCESS_SCROLL_TOP
	if ((t == IA2_SCROLL_TYPE_BOTTOM_RIGHT) || (t == IA2_SCROLL_TYPE_BOTTOM_EDGE)): return UI_ACCESS_SCROLL_BOTTOM
	return UI_ACCESS_SCROLL_ANYWHERE


int ui_ia2_text_scroll(int self, int start, int end, int type):
	return ui_ia2_scroll_range(self, start, end, ui_ia2_scroll_align(type))


int ui_ia2_text_scroll_point(int self, int start, int end, int coord, int x, int y):
	return ui_ia2_scroll_range(self, start, end, UI_ACCESS_SCROLL_ANYWHERE)


# get_newText / get_oldText: the segment the last published change
# inserted or removed (ui_ia2_track_text); S_FALSE when there was none.
int ui_ia2_text_segment(int self, int out, int inserted):
	if (out == 0): return UIA_E_POINTER
	char* segment = cast(char*, out)
	for i in range(16): segment[i] = 0
	ui_uia_element* e = ui_uia_self(self)
	if (ui_uia_node(e) == 0): return UIA_E_FAIL
	char* data = e.text_removed
	int length = e.text_removed_length
	if inserted:
		data = e.text_inserted
		length = e.text_inserted_length
	if (data == 0): return UIA_S_FALSE
	save_int64(cast(char*, out), ui_uia_bstr(data, length))
	save_int32(cast(char*, out + 8), e.text_change_start)
	save_int32(cast(char*, out + 12), e.text_change_start + ui_access_char_count(data, length))
	return UIA_S_OK


int ui_ia2_text_new(int self, int out):
	return ui_ia2_text_segment(self, out, 1)


int ui_ia2_text_old(int self, int out):
	return ui_ia2_text_segment(self, out, 0)


void ui_ia2_element_text_clear(ui_uia_element* e):
	free(e.text_inserted)
	free(e.text_removed)
	e.text_inserted = 0
	e.text_removed = 0
	e.text_inserted_length = 0
	e.text_removed_length = 0


void ui_ia2_win_event(ui_uia_bridge* b, int event, int id):
	int child = 0 - id
	if (id == b.published.root.id): child = CHILDID_SELF
	NotifyWinEvent(event, b.hwnd, OBJID_CLIENT, child)


# Record on each handed-out text element what changed between old and
# fresh (the common prefix and suffix bound it) for get_newText and
# get_oldText, and, for a window-hosted tree, raise IA2's text
# inserted / removed / caret / selection WinEvents.
void ui_ia2_track_text(ui_uia_bridge* b, ui_access_tree* old, ui_access_tree* fresh):
	if ((old == 0) || (fresh == 0)): return
	for int id in b.elements:
		ui_uia_element* e = b.elements[id]
		ui_access_node* n = ui_access_find(fresh, id)
		ui_access_node* was = ui_access_find(old, id)
		if ((n == 0) || (was == 0) || (n.role != UI_ACCESS_TEXTBOX)): continue
		ui_access_text* a = &was.value
		ui_access_text* c = &n.value
		if (!ui_access_text_same(a, c)):
			int prefix = 0
			while ((prefix < a.length) && (prefix < c.length) && (a.data[prefix] == c.data[prefix])): prefix = prefix + 1
			while ((prefix > 0) && ((c.data[prefix] & 192) == 128)): prefix = prefix - 1
			int suffix = 0
			while ((suffix < a.length - prefix) && (suffix < c.length - prefix) && (a.data[a.length - 1 - suffix] == c.data[c.length - 1 - suffix])): suffix = suffix + 1
			while ((suffix > 0) && (a.length - suffix < a.length) && ((a.data[a.length - suffix] & 192) == 128)): suffix = suffix - 1
			ui_ia2_element_text_clear(e)
			e.text_change_start = ui_access_char_count(c.data, prefix)
			int removed = a.length - prefix - suffix
			int inserted = c.length - prefix - suffix
			e.text_removed = cast(char*, malloc(removed + 1))
			for i in range(removed): e.text_removed[i] = a.data[prefix + i]
			e.text_removed[removed] = 0
			e.text_removed_length = removed
			e.text_inserted = cast(char*, malloc(inserted + 1))
			for i in range(inserted): e.text_inserted[i] = c.data[prefix + i]
			e.text_inserted[inserted] = 0
			e.text_inserted_length = inserted
			if (b.hwnd != 0):
				if (removed > 0): ui_ia2_win_event(b, IA2_EVENT_TEXT_REMOVED, id)
				if (inserted > 0): ui_ia2_win_event(b, IA2_EVENT_TEXT_INSERTED, id)
		if (b.hwnd != 0):
			if (n.caret != was.caret): ui_ia2_win_event(b, IA2_EVENT_TEXT_CARET_MOVED, id)
			if ((n.selection_start != was.selection_start) || (n.selection_end != was.selection_end) || !ui_access_depth_same(n, was)): ui_ia2_win_event(b, IA2_EVENT_TEXT_SELECTION_CHANGED, id)


/* IAccessibleEditableText: edits queue the edited value. */

ui_access_node* ui_ia2_edit_node(int self, int* count):
	ui_access_node* n = ui_ia2_text_node(self, count)
	if ((n != 0) && !ui_uia_supports(ui_ia2_bridge(self), n, UI_UIA_TEXT_EDIT)): return 0
	return n


# Queue n's value with characters [start, end) replaced by insert.
int ui_ia2_replace(int self, ui_access_node* n, int start, int end, char* insert, int insert_length):
	int count = ui_access_text_count(n)
	if (end < start):
		int t = start
		start = end
		end = t
	if ((start < 0) || (end > count)): return UIA_E_INVALIDARG
	int from = ui_access_char_byte(n.value.data, n.value.length, start)
	int to = ui_access_char_byte(n.value.data, n.value.length, end)
	int length = n.value.length - (to - from) + insert_length
	char* text = cast(char*, malloc(length + 1))
	int k = 0
	for i in range(from):
		text[k] = n.value.data[i]
		k = k + 1
	for i in range(insert_length):
		text[k] = insert[i]
		k = k + 1
	for i in range(to, n.value.length):
		text[k] = n.value.data[i]
		k = k + 1
	int ok = ui_uia_enqueue(ui_ia2_bridge(self), n, UI_ACCESS_SET_VALUE, text, length)
	free(text)
	if ok: return UIA_S_OK
	return UIA_E_FAIL


int ui_ia2_edit_delete(int self, int start, int end):
	int count = 0
	ui_access_node* n = ui_ia2_edit_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	return ui_ia2_replace(self, n, ui_ia2_offset(n, start, count), ui_ia2_offset(n, end, count), c"", 0)


# insertText / replaceText take the new text as a BSTR*.
int ui_ia2_edit_insert(int self, int offset, int text):
	int count = 0
	ui_access_node* n = ui_ia2_edit_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	if ((text == 0) || (load_int64(cast(char*, text)) == 0)): return UIA_E_INVALIDARG
	int length = 0
	char* s = ui_uia_utf8(load_int64(cast(char*, text)), &length)
	int k = ui_ia2_offset(n, offset, count)
	int r = ui_ia2_replace(self, n, k, k, s, length)
	free(s)
	return r


int ui_ia2_edit_replace(int self, int start, int end, int text):
	int count = 0
	ui_access_node* n = ui_ia2_edit_node(self, &count)
	if (n == 0): return UIA_E_FAIL
	if ((text == 0) || (load_int64(cast(char*, text)) == 0)): return UIA_E_INVALIDARG
	int length = 0
	char* s = ui_uia_utf8(load_int64(cast(char*, text)), &length)
	int r = ui_ia2_replace(self, n, ui_ia2_offset(n, start, count), ui_ia2_offset(n, end, count), s, length)
	free(s)
	return r


# copyText, cutText, pasteText and setAttributes: the snapshot reaches
# neither the clipboard nor the widget's styling.
int ui_ia2_edit_unsupported(int self, int a, int b):
	if (ui_uia_node(ui_uia_self(self)) == 0): return UIA_E_FAIL
	return UIA_E_NOTIMPL


int ui_ia2_edit_paste(int self, int offset):
	return ui_ia2_edit_unsupported(self, offset, 0)


int ui_ia2_edit_set_attributes(int self, int start, int end, int attributes):
	return ui_ia2_edit_unsupported(self, start, end)


/* IAccessibleTable2 and IAccessibleTableCell. */

int ui_ia2_out32(int out, int v):
	save_int32(cast(char*, out), v)
	return UIA_S_OK


ui_access_node* ui_ia2_table_node(int self, int out):
	if (out == 0): return 0
	return ui_uia_node(ui_uia_self(self))


int ui_ia2_table_cell_at(int self, int row, int col, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	ui_access_node* c = ui_access_table_cell_at(n, ui_uia_lo32(row), ui_uia_lo32(col))
	if (c == 0): return UIA_E_INVALIDARG
	return ui_uia_hand_out(ui_ia2_bridge(self), c.id, UI_UIA_IA2, out)


# get_caption / get_summary: the snapshot has neither.
int ui_ia2_table_none(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	if (ui_ia2_table_node(self, out) == 0): return UIA_E_FAIL
	return UIA_S_FALSE


# The header-row cell over column col, or 0.
ui_access_node* ui_ia2_column_header(ui_access_node* table, int col):
	ui_access_node* header = ui_access_header_row(table)
	if (header == 0): return 0
	ui_access_node* c = header.first_child
	while (c != 0):
		int hc = 0
		int hs = 0
		if (ui_access_header_cell_column(c, &hc, &hs) && (col >= hc) && (col < hc + hs)): return c
		c = c.next_sibling
	return 0


# The row header covering data row row, or 0.
ui_access_node* ui_ia2_row_header(ui_access_node* table, int row):
	ui_access_node* found = 0
	ui_access_grid g
	ui_access_grid_begin(&g, table)
	while (ui_access_grid_next(&g)):
		if ((found == 0) && ui_access_is_row_header(g.cell) && (row >= g.row) && (row < g.row + g.row_span)): found = g.cell
	return found


int ui_ia2_put_name(int out, ui_access_node* n):
	if ((n == 0) || (n.name.length == 0)): return UIA_S_FALSE
	save_int64(cast(char*, out), ui_uia_bstr(n.name.data, n.name.length))
	return UIA_S_OK


int ui_ia2_table_column_description(int self, int col, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	int c = ui_uia_lo32(col)
	if ((c < 0) || (c >= ui_access_table_columns(n))): return UIA_E_INVALIDARG
	return ui_ia2_put_name(out, ui_ia2_column_header(n, c))


int ui_ia2_table_row_description(int self, int row, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	int r = ui_uia_lo32(row)
	if ((r < 0) || (r >= ui_access_table_rows(n))): return UIA_E_INVALIDARG
	return ui_ia2_put_name(out, ui_ia2_row_header(n, r))


int ui_ia2_table_columns(int self, int out):
	if (out == 0): return UIA_E_POINTER
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	return ui_ia2_out32(out, ui_access_table_columns(n))


int ui_ia2_table_rows(int self, int out):
	if (out == 0): return UIA_E_POINTER
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	return ui_ia2_out32(out, ui_access_table_rows(n))


# The selected data rows' indices, in order.
list[int] ui_ia2_selected_rows(ui_access_node* table):
	list[int] rows = new list[int]
	int k = 0
	ui_access_node* c = table.first_child
	while (c != 0):
		if (ui_access_is_data_row(c)):
			if ((c.states & UI_ACCESS_SELECTED) != 0): rows.push(k)
			k = k + 1
		c = c.next_sibling
	return rows


# The cells of the selected rows (a cell spanning into one counts once).
list[int] ui_ia2_selected_cells(ui_access_node* table):
	list[int] cells = new list[int]
	ui_access_grid g
	ui_access_grid_begin(&g, table)
	while (ui_access_grid_next(&g)):
		if ((g.row_node.states & UI_ACCESS_SELECTED) != 0): cells.push(g.cell.id)
	return cells


int ui_ia2_table_n_selected_cells(int self, int out):
	if (out == 0): return UIA_E_POINTER
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	list[int] cells = ui_ia2_selected_cells(n)
	int count = cells.length
	list_free[int](cells)
	return ui_ia2_out32(out, count)


# Columns are never selected: rows are the table's selectable items.
int ui_ia2_table_n_selected_columns(int self, int out):
	if (out == 0): return UIA_E_POINTER
	if (ui_ia2_table_node(self, out) == 0): return UIA_E_FAIL
	return ui_ia2_out32(out, 0)


int ui_ia2_table_n_selected_rows(int self, int out):
	if (out == 0): return UIA_E_POINTER
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	return ui_ia2_out32(out, ui_access_selected_count(n))


# A CoTaskMemAlloc'd array of the IAccessible2s of ids in *out and their
# count in *count; S_FALSE (null, 0) for none.
int ui_ia2_put_objects(ui_uia_bridge* b, list[int] ids, int out, int count):
	save_int64(cast(char*, out), 0)
	save_int32(cast(char*, count), 0)
	if (ids.length == 0): return UIA_S_FALSE
	int array = CoTaskMemAlloc(ids.length * 8)
	if (array == 0): return UIA_E_FAIL
	for i in range(ids.length): ui_uia_hand_out(b, ids[i], UI_UIA_IA2, array + i * 8)
	save_int64(cast(char*, out), array)
	save_int32(cast(char*, count), ids.length)
	return UIA_S_OK


int ui_ia2_table_selected_cells(int self, int out, int count):
	if ((out == 0) || (count == 0)): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	save_int32(cast(char*, count), 0)
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	list[int] cells = ui_ia2_selected_cells(n)
	int r = ui_ia2_put_objects(ui_ia2_bridge(self), cells, out, count)
	list_free[int](cells)
	return r


int ui_ia2_table_selected_columns(int self, int out, int count):
	if ((out == 0) || (count == 0)): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	save_int32(cast(char*, count), 0)
	if (ui_ia2_table_node(self, out) == 0): return UIA_E_FAIL
	return UIA_S_FALSE


int ui_ia2_table_selected_rows(int self, int out, int count):
	if ((out == 0) || (count == 0)): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	save_int32(cast(char*, count), 0)
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	list[int] rows = ui_ia2_selected_rows(n)
	int total = rows.length
	if (total == 0):
		list_free[int](rows)
		return UIA_S_FALSE
	int array = CoTaskMemAlloc(total * 4)
	if (array == 0):
		list_free[int](rows)
		return UIA_E_FAIL
	for i in range(total): save_int32(cast(char*, array + i * 4), rows[i])
	list_free[int](rows)
	save_int64(cast(char*, out), array)
	save_int32(cast(char*, count), total)
	return UIA_S_OK


int ui_ia2_put_bool(int out, int v):
	char* p = cast(char*, out)
	p[0] = v != 0
	return UIA_S_OK


int ui_ia2_table_column_selected(int self, int col, int out):
	if (out == 0): return UIA_E_POINTER
	ui_ia2_put_bool(out, 0)
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	int c = ui_uia_lo32(col)
	if ((c < 0) || (c >= ui_access_table_columns(n))): return UIA_E_INVALIDARG
	return UIA_S_OK


int ui_ia2_table_row_selected(int self, int row, int out):
	if (out == 0): return UIA_E_POINTER
	ui_ia2_put_bool(out, 0)
	ui_access_node* n = ui_ia2_table_node(self, out)
	if (n == 0): return UIA_E_FAIL
	ui_access_node* r = ui_access_table_row(n, ui_uia_lo32(row))
	if (r == 0): return UIA_E_INVALIDARG
	return ui_ia2_put_bool(out, (r.states & UI_ACCESS_SELECTED) != 0)


# selectRow selects only that row, unselectRow deselects it, as their
# rows' SelectionItem pattern does.
int ui_ia2_table_select(int self, int row, int mode):
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_FAIL
	ui_access_node* r = ui_access_table_row(n, ui_uia_lo32(row))
	if (r == 0): return UIA_E_INVALIDARG
	int hr = ui_uia_select_mode(ui_uia_bridge_of(e), r, mode)
	if (hr == UIA_S_OK): return UIA_S_OK
	return UIA_E_INVALIDARG


int ui_ia2_table_select_row(int self, int row):
	return ui_ia2_table_select(self, row, UI_ACCESS_SELECT_ONLY)


int ui_ia2_table_unselect_row(int self, int row):
	return ui_ia2_table_select(self, row, UI_ACCESS_SELECT_REMOVE)


int ui_ia2_table_column_unsupported(int self, int col):
	if (ui_uia_node(ui_uia_self(self)) == 0): return UIA_E_FAIL
	return UIA_E_NOTIMPL


# get_modelChange: no IA2_EVENT_TABLE_MODEL_CHANGED is raised, so there
# is none to describe (an IA2TableModelChange of five longs, zeroed).
int ui_ia2_table_model_change(int self, int out):
	if (out == 0): return UIA_E_POINTER
	char* change = cast(char*, out)
	for i in range(20): change[i] = 0
	if (ui_uia_node(ui_uia_self(self)) == 0): return UIA_E_FAIL
	return UIA_S_FALSE


# A data cell's slot (ui_access_cell_slot) behind a cell interface.
ui_access_node* ui_ia2_cell_slot(int self, int* row, int* col, int* row_span, int* col_span):
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	if (n == 0): return 0
	if (!ui_access_cell_slot(n, row, col, row_span, col_span)): return 0
	return n


int ui_ia2_cell_answer(int self, int out, int which):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	int[4] slot
	ui_access_node* n = ui_ia2_cell_slot(self, &slot[0], &slot[1], &slot[2], &slot[3])
	if (n == 0): return UIA_E_FAIL
	return ui_ia2_out32(out, slot[which])


int ui_ia2_cell_row(int self, int out):
	return ui_ia2_cell_answer(self, out, 0)


int ui_ia2_cell_column(int self, int out):
	return ui_ia2_cell_answer(self, out, 1)


int ui_ia2_cell_row_extent(int self, int out):
	return ui_ia2_cell_answer(self, out, 2)


int ui_ia2_cell_column_extent(int self, int out):
	return ui_ia2_cell_answer(self, out, 3)


# get_columnHeaderCells (columns 1) / get_rowHeaderCells (0).
int ui_ia2_cell_headers(int self, int out, int count, int columns):
	if ((out == 0) || (count == 0)): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	save_int32(cast(char*, count), 0)
	int[4] slot
	ui_access_node* n = ui_ia2_cell_slot(self, &slot[0], &slot[1], &slot[2], &slot[3])
	if (n == 0): return UIA_E_FAIL
	list[int] ids = new list[int]
	ui_access_node* h = 0
	int total = 0
	if columns: total = ui_access_column_headers_of(n, 0, &h)
	else: total = ui_access_row_headers_of(n, 0, &h)
	for i in range(total):
		if columns: ui_access_column_headers_of(n, i, &h)
		else: ui_access_row_headers_of(n, i, &h)
		ids.push(h.id)
	int r = ui_ia2_put_objects(ui_ia2_bridge(self), ids, out, count)
	list_free[int](ids)
	return r


int ui_ia2_cell_column_headers(int self, int out, int count):
	return ui_ia2_cell_headers(self, out, count, 1)


int ui_ia2_cell_row_headers(int self, int out, int count):
	return ui_ia2_cell_headers(self, out, count, 0)


int ui_ia2_cell_selected(int self, int out):
	if (out == 0): return UIA_E_POINTER
	ui_ia2_put_bool(out, 0)
	int[4] slot
	ui_access_node* n = ui_ia2_cell_slot(self, &slot[0], &slot[1], &slot[2], &slot[3])
	if (n == 0): return UIA_E_FAIL
	return ui_ia2_put_bool(out, (n.parent.states & UI_ACCESS_SELECTED) != 0)


int ui_ia2_cell_extents(int self, int row, int col, int row_extent, int col_extent, int selected):
	if ((row == 0) || (col == 0) || (row_extent == 0) || (col_extent == 0) || (selected == 0)): return UIA_E_POINTER
	int[4] slot
	for i in range(4): slot[i] = 0
	ui_access_node* n = ui_ia2_cell_slot(self, &slot[0], &slot[1], &slot[2], &slot[3])
	save_int32(cast(char*, row), slot[0])
	save_int32(cast(char*, col), slot[1])
	save_int32(cast(char*, row_extent), slot[2])
	save_int32(cast(char*, col_extent), slot[3])
	ui_ia2_put_bool(selected, 0)
	if (n == 0): return UIA_E_FAIL
	return ui_ia2_put_bool(selected, (n.parent.states & UI_ACCESS_SELECTED) != 0)


int ui_ia2_cell_table(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	int[4] slot
	ui_access_node* n = ui_ia2_cell_slot(self, &slot[0], &slot[1], &slot[2], &slot[3])
	if (n == 0): return UIA_E_FAIL
	return ui_uia_hand_out(ui_ia2_bridge(self), n.parent.parent.id, UI_UIA_IA2, out)


/* IAccessibleValue. */

int ui_ia2_value_answer(int self, int out, int which):
	if (out == 0): return UIA_E_POINTER
	char* v = cast(char*, out)
	ui_uia_variant_clear(v)
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	if (n == 0): return UIA_E_FAIL
	save_int16(v, VT_R8)
	ui_uia_put_double(cast(int, &v[8]), ui_uia_range_of(n, which))
	return UIA_S_OK


int ui_ia2_value_current(int self, int out):
	return ui_ia2_value_answer(self, out, 0)


int ui_ia2_value_maximum(int self, int out):
	return ui_ia2_value_answer(self, out, 1)


int ui_ia2_value_minimum(int self, int out):
	return ui_ia2_value_answer(self, out, 2)


# setCurrentValue (the VARIANT arrives by reference): a number (VT_R8,
# VT_R4, VT_I4) or decimal text, for a slider that takes values.
int ui_ia2_value_set(int self, int value):
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_FAIL
	if (value == 0): return UIA_E_INVALIDARG
	if (!ui_uia_range_writable(n)): return UIA_E_FAIL
	char* v = cast(char*, value)
	int vt = load_int16(v) & 65535
	float64 x = 0.0
	if (vt == VT_R8): x = ui_uia_double_from_bits(load_int64(&v[8]))
	else if (vt == VT_I4): x = cast(float64, load_int32(&v[8]))
	else if (vt == 4):
		float32* f = cast(float32*, &v[8])
		x = cast(float64, f[0])
	else if (vt == VT_BSTR):
		int length = 0
		char* text = ui_uia_utf8(load_int64(&v[8]), &length)
		int ok = ui_uia_enqueue(ui_uia_bridge_of(e), n, UI_ACCESS_SET_VALUE, text, length)
		free(text)
		if ok: return UIA_S_OK
		return UIA_E_FAIL
	else: return UIA_E_INVALIDARG
	if (n.has_range && ((x < cast(float64, n.range_min)) || (x > cast(float64, n.range_max)))): return UIA_E_INVALIDARG
	char[48] text
	int length = ui_access_number_format(&text[0], cast(float32, x))
	if (ui_uia_enqueue(ui_uia_bridge_of(e), n, UI_ACCESS_SET_VALUE, &text[0], length)): return UIA_S_OK
	return UIA_E_FAIL


/* Vtables and interface ids, called from ui_uia_init. */

void ui_ia2_init():
	# IAccessible2_2                {6C9430E9-299D-4E6F-BD01-A82A1E88D3FF}
	ui_uia_guid(UI_UIA_IA2_2_IID, 0x6c9430e9, 0x299d, 0x4e6f, 0xbd, 0x01, 0xa8, 0x2a, 0x1e, 0x88, 0xd3, 0xff)
	# IAccessible2_3                {5BE18059-762E-4E73-9476-ABA294FED411}
	ui_uia_guid(UI_UIA_IA2_3_IID, 0x5be18059, 0x762e, 0x4e73, 0x94, 0x76, 0xab, 0xa2, 0x94, 0xfe, 0xd4, 0x11)
	# IAccessibleRelation           {7CDF86EE-C3DA-496a-BDA4-281B336E1FDC}
	ui_uia_guid(UI_UIA_RELATION_IID, 0x7cdf86ee, 0xc3da, 0x496a, 0xbd, 0xa4, 0x28, 0x1b, 0x33, 0x6e, 0x1f, 0xdc)
	# IAccessibleText               {24FD2FFB-3AAD-4a08-8335-A3AD89C0FB4B}
	ui_uia_guid(ui_uia_kind_slot(UI_UIA_IA2_TEXT), 0x24fd2ffb, 0x3aad, 0x4a08, 0x83, 0x35, 0xa3, 0xad, 0x89, 0xc0, 0xfb, 0x4b)
	# IAccessibleEditableText       {A59AA09A-7011-4b65-939D-32B1FB5547E3}
	ui_uia_guid(ui_uia_kind_slot(UI_UIA_IA2_EDIT), cast(int, 0xa59aa09a), 0x7011, 0x4b65, 0x93, 0x9d, 0x32, 0xb1, 0xfb, 0x55, 0x47, 0xe3)
	# IAccessibleTable2             {6167f295-06f0-4cdd-a1fa-02e25153d869}
	ui_uia_guid(ui_uia_kind_slot(UI_UIA_IA2_TABLE), 0x6167f295, 0x06f0, 0x4cdd, 0xa1, 0xfa, 0x02, 0xe2, 0x51, 0x53, 0xd8, 0x69)
	# IAccessibleTableCell          {594116B1-C99F-4847-AD06-0A7A86ECE645}
	ui_uia_guid(ui_uia_kind_slot(UI_UIA_IA2_CELL), 0x594116b1, 0xc99f, 0x4847, 0xad, 0x06, 0x0a, 0x7a, 0x86, 0xec, 0xe6, 0x45)
	# IAccessibleValue              {35855B5B-C566-4fd0-A7B1-E65465600394}
	ui_uia_guid(ui_uia_kind_slot(UI_UIA_IA2_VALUE), 0x35855b5b, 0xc566, 0x4fd0, 0xa7, 0xb1, 0xe6, 0x54, 0x65, 0x60, 0x03, 0x94)

	# IAccessible2's relation entries and the _2 / _3 methods.
	int* vt = cast(int*, ui_uia_vtables[UI_UIA_IA2])
	vt[28] = ui_uia_thunk(cast(int, ui_ia2_n_relations), 2)
	vt[29] = ui_uia_thunk(cast(int, ui_ia2_relation), 3)
	vt[30] = ui_uia_thunk(cast(int, ui_ia2_relations), 4)
	vt[46] = ui_uia_thunk(cast(int, ui_ia2_attribute), 3)
	vt[47] = ui_uia_thunk(cast(int, ui_ia2_with_caret), 3)
	vt[48] = ui_uia_thunk(cast(int, ui_ia2_relation_targets_of_type), 5)
	vt[49] = ui_uia_thunk(cast(int, ui_ia2_selection_ranges), 3)

	int* rel = cast(int*, malloc(8 * 8))
	rel[0] = ui_uia_thunk(cast(int, ui_ia2_relation_query), 3)
	rel[1] = ui_uia_thunk(cast(int, ui_ia2_relation_add_ref), 1)
	rel[2] = ui_uia_thunk(cast(int, ui_ia2_relation_release), 1)
	rel[3] = ui_uia_thunk(cast(int, ui_ia2_relation_type), 2)
	rel[4] = ui_uia_thunk(cast(int, ui_ia2_relation_type), 2)
	rel[5] = ui_uia_thunk(cast(int, ui_ia2_relation_targets_count), 2)
	rel[6] = ui_uia_thunk(cast(int, ui_ia2_relation_target), 3)
	rel[7] = ui_uia_thunk(cast(int, ui_ia2_relation_targets), 4)
	ui_uia_relation_vtable = cast(int, rel)

	vt = ui_uia_vtable(19)
	vt[3] = ui_uia_thunk(cast(int, ui_ia2_text_add_selection), 3)
	vt[4] = ui_uia_thunk(cast(int, ui_ia2_text_attributes), 5)
	vt[5] = ui_uia_thunk(cast(int, ui_ia2_text_caret), 2)
	vt[6] = ui_uia_thunk(cast(int, ui_ia2_text_extents), 7)
	vt[7] = ui_uia_thunk(cast(int, ui_ia2_text_n_selections), 2)
	vt[8] = ui_uia_thunk(cast(int, ui_ia2_text_offset_at_point), 5)
	vt[9] = ui_uia_thunk(cast(int, ui_ia2_text_selection), 4)
	vt[10] = ui_uia_thunk(cast(int, ui_ia2_text_get), 4)
	vt[11] = ui_uia_thunk(cast(int, ui_ia2_text_before), 6)
	vt[12] = ui_uia_thunk(cast(int, ui_ia2_text_after), 6)
	vt[13] = ui_uia_thunk(cast(int, ui_ia2_text_at), 6)
	vt[14] = ui_uia_thunk(cast(int, ui_ia2_text_remove_selection), 2)
	vt[15] = ui_uia_thunk(cast(int, ui_ia2_text_set_caret), 2)
	vt[16] = ui_uia_thunk(cast(int, ui_ia2_text_set_selection), 4)
	vt[17] = ui_uia_thunk(cast(int, ui_ia2_text_count), 2)
	vt[18] = ui_uia_thunk(cast(int, ui_ia2_text_scroll), 4)
	vt[19] = ui_uia_thunk(cast(int, ui_ia2_text_scroll_point), 6)
	vt[20] = ui_uia_thunk(cast(int, ui_ia2_text_new), 2)
	vt[21] = ui_uia_thunk(cast(int, ui_ia2_text_old), 2)
	ui_uia_vtables[UI_UIA_IA2_TEXT] = cast(int, vt)

	vt = ui_uia_vtable(7)
	vt[3] = ui_uia_thunk(cast(int, ui_ia2_edit_unsupported), 3)
	vt[4] = ui_uia_thunk(cast(int, ui_ia2_edit_delete), 3)
	vt[5] = ui_uia_thunk(cast(int, ui_ia2_edit_insert), 3)
	vt[6] = ui_uia_thunk(cast(int, ui_ia2_edit_unsupported), 3)
	vt[7] = ui_uia_thunk(cast(int, ui_ia2_edit_paste), 2)
	vt[8] = ui_uia_thunk(cast(int, ui_ia2_edit_replace), 4)
	vt[9] = ui_uia_thunk(cast(int, ui_ia2_edit_set_attributes), 4)
	ui_uia_vtables[UI_UIA_IA2_EDIT] = cast(int, vt)

	vt = ui_uia_vtable(20)
	vt[3] = ui_uia_thunk(cast(int, ui_ia2_table_cell_at), 4)
	vt[4] = ui_uia_thunk(cast(int, ui_ia2_table_none), 2)
	vt[5] = ui_uia_thunk(cast(int, ui_ia2_table_column_description), 3)
	vt[6] = ui_uia_thunk(cast(int, ui_ia2_table_columns), 2)
	vt[7] = ui_uia_thunk(cast(int, ui_ia2_table_rows), 2)
	vt[8] = ui_uia_thunk(cast(int, ui_ia2_table_n_selected_cells), 2)
	vt[9] = ui_uia_thunk(cast(int, ui_ia2_table_n_selected_columns), 2)
	vt[10] = ui_uia_thunk(cast(int, ui_ia2_table_n_selected_rows), 2)
	vt[11] = ui_uia_thunk(cast(int, ui_ia2_table_row_description), 3)
	vt[12] = ui_uia_thunk(cast(int, ui_ia2_table_selected_cells), 3)
	vt[13] = ui_uia_thunk(cast(int, ui_ia2_table_selected_columns), 3)
	vt[14] = ui_uia_thunk(cast(int, ui_ia2_table_selected_rows), 3)
	vt[15] = ui_uia_thunk(cast(int, ui_ia2_table_none), 2)
	vt[16] = ui_uia_thunk(cast(int, ui_ia2_table_column_selected), 3)
	vt[17] = ui_uia_thunk(cast(int, ui_ia2_table_row_selected), 3)
	vt[18] = ui_uia_thunk(cast(int, ui_ia2_table_select_row), 2)
	vt[19] = ui_uia_thunk(cast(int, ui_ia2_table_column_unsupported), 2)
	vt[20] = ui_uia_thunk(cast(int, ui_ia2_table_unselect_row), 2)
	vt[21] = ui_uia_thunk(cast(int, ui_ia2_table_column_unsupported), 2)
	vt[22] = ui_uia_thunk(cast(int, ui_ia2_table_model_change), 2)
	ui_uia_vtables[UI_UIA_IA2_TABLE] = cast(int, vt)

	vt = ui_uia_vtable(9)
	vt[3] = ui_uia_thunk(cast(int, ui_ia2_cell_column_extent), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_ia2_cell_column_headers), 3)
	vt[5] = ui_uia_thunk(cast(int, ui_ia2_cell_column), 2)
	vt[6] = ui_uia_thunk(cast(int, ui_ia2_cell_row_extent), 2)
	vt[7] = ui_uia_thunk(cast(int, ui_ia2_cell_row_headers), 3)
	vt[8] = ui_uia_thunk(cast(int, ui_ia2_cell_row), 2)
	vt[9] = ui_uia_thunk(cast(int, ui_ia2_cell_selected), 2)
	vt[10] = ui_uia_thunk(cast(int, ui_ia2_cell_extents), 6)
	vt[11] = ui_uia_thunk(cast(int, ui_ia2_cell_table), 2)
	ui_uia_vtables[UI_UIA_IA2_CELL] = cast(int, vt)

	vt = ui_uia_vtable(4)
	vt[3] = ui_uia_thunk(cast(int, ui_ia2_value_current), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_ia2_value_set), 2)
	vt[5] = ui_uia_thunk(cast(int, ui_ia2_value_maximum), 2)
	vt[6] = ui_uia_thunk(cast(int, ui_ia2_value_minimum), 2)
	ui_uia_vtables[UI_UIA_IA2_VALUE] = cast(int, vt)
