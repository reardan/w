# wbuild: name=graphics_ui_accessibility_uia_test arch_only=win64
# The UI Automation bridge driven in-process, under wine in CI. A UIA
# client (uiautomationcore's UiaNodeFromProvider / UiaGetPropertyValue /
# UiaGetRuntimeId / UiaNavigate) reads the published providers; control
# patterns (Selection, Grid, Table and their items included) and MSAA's
# IAccessible are called through their vtables, because wine's flat
# pattern functions (InvokePattern_Invoke, ...) are stubs and its
# UiaGetPropertyValue does not know the pattern properties. The bridge
# is unhosted (hwnd 0); accessibility_uia_window_test covers a real
# window and a client in another process.
import lib.lib
import lib.assert
import graphics.ui.accessibility_uia

c_lib "uiautomationcore.dll"
extern int UiaNodeFromProvider(int provider, int* node)
extern int UiaNodeRelease(int node)
extern int UiaGetPropertyValue(int node, int property_id, char* out)
extern int UiaGetRuntimeId(int node, int* out)
extern int UiaNavigate(int node, int direction, char* condition, char* cache_request, int* requested, int* tree_structure)
extern int UiaHUiaNodeFromVariant(char* value, int* node)
extern int UiaAddEvent(int node, int event_id, int callback, int scope, int32* properties, int count, char* cache, int* event)
extern int UiaRemoveEvent(int event)

c_lib "user32.dll"
extern int PeekMessageW(char* msg, int hwnd, int filter_min, int filter_max, int remove)
extern int DispatchMessageW(char* msg)

c_lib "oleacc.dll"
extern int ObjectFromLresult(int result, char* riid, int wparam, int* out)

c_lib "oleaut32.dll"
extern int SafeArrayGetElement(int array, int32* index, char* value)
extern int SafeArrayDestroy(int array)
extern int SafeArrayGetUBound(int array, int dim, int32* bound)
extern int VariantClear(char* value)


type uia_m1 = fn(int) -> int
type uia_m2 = fn(int, int) -> int
type uia_m3 = fn(int, int, int) -> int
type uia_point = fn(int, float64, float64, int) -> int
type uia_m4 = fn(int, int, int, int) -> int
type uia_m6 = fn(int, int, int, int, int, int) -> int


int[16] actions_seen
int[16] action_ids
char[64] last_value
int last_length
int action_count


int record_action(void* context, int id, int action, char* data, int length):
	if (action_count < 16):
		actions_seen[action_count] = action
		action_ids[action_count] = id
	action_count = action_count + 1
	if (action == UI_ACCESS_SET_VALUE):
		for i in range(length): last_value[i] = data[i]
		last_length = length
	return 1


int focus_events
int selected_events


# UiaEventCallback(UiaEventArgs* args, SAFEARRAY* requested, BSTR tree);
# UiaEventArgs is {EventArgsType Type; int EventId}.
void on_event(int args, int requested, int tree):
	int id = load_int32(cast(char*, args + 4))
	if (id == UIA_AutomationFocusChangedEventId): focus_events = focus_events + 1
	if (id == UIA_SelectionItem_ElementSelectedEventId): selected_events = selected_events + 1


# Pump messages until the focus and selection events arrived (at most
# ~2s).
void wait_for_events():
	char[64] msg
	int tries = 0
	while (((focus_events == 0) || (selected_events == 0)) && (tries < 40)):
		while (PeekMessageW(&msg[0], 0, 0, 0, 1) & 255): DispatchMessageW(&msg[0])
		if ((focus_events == 0) || (selected_events == 0)): Sleep(50)
		tries = tries + 1


int hr(int v):
	return (v << 32) >> 32


int method(int object, int slot, int nargs):
	int vtbl = load_int64(cast(char*, object))
	return win_c_function(load_int64(cast(char*, vtbl + slot * 8)), nargs, 1)


int call1(int object, int slot):
	uia_m1* f = cast(uia_m1*, method(object, slot, 1))
	return hr(f(object))


int call2(int object, int slot, int a):
	uia_m2* f = cast(uia_m2*, method(object, slot, 2))
	return hr(f(object, a))


int call3(int object, int slot, int a, int b):
	uia_m3* f = cast(uia_m3*, method(object, slot, 3))
	return hr(f(object, a, b))


int call4(int object, int slot, int a, int b, int c):
	uia_m4* f = cast(uia_m4*, method(object, slot, 4))
	return hr(f(object, a, b, c))


int call6(int object, int slot, int a, int b, int c, int d, int e):
	uia_m6* f = cast(uia_m6*, method(object, slot, 6))
	return hr(f(object, a, b, c, d, e))


void release(int object):
	if (object != 0): call1(object, 2)


# GetPatternProvider (Simple slot 4) and the pattern interface it hands out.
int pattern(int simple, int pattern_id):
	int out = 0
	assert_equal(0, call3(simple, 4, pattern_id, cast(int, &out)))
	return out


char* ui_uia_iids_at(int slot):
	return &ui_uia_iids[slot * 16]


int query(int object, int slot):
	int out = 0
	int r = call3(object, 0, cast(int, ui_uia_iids_at(slot)), cast(int, &out))
	if (r != 0): return 0
	return out


# Fragment navigation (Fragment slot 3) from a fragment interface.
int navigate(int fragment, int direction):
	int out = 0
	assert_equal(0, call3(fragment, 3, direction, cast(int, &out)))
	return out


int fragment_of(int simple):
	return query(simple, 2)


int simple_of(int fragment):
	return query(fragment, 1)


# The id a provider reports as its AutomationId.
int automation_id(int simple):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, call3(simple, 5, UIA_AutomationIdPropertyId, cast(int, &v[0])))
	assert_equal(VT_BSTR, load_int16(&v[0]) & 65535)
	int length = 0
	char* text = ui_uia_utf8(load_int64(&v[8]), &length)
	int id = atoi(text)
	free(text)
	VariantClear(&v[0])
	return id


void assert_bstr(char* expect, int bstr):
	asserts(c"BSTR present", bstr != 0)
	int length = 0
	char* text = ui_uia_utf8(bstr, &length)
	assert_equal(strlen(expect), length)
	for i in range(length): assert_equal(expect[i], text[i])
	free(text)


# UiaGetPropertyValue through the client node.
void client_int(int node, int property, int vt, int expect):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, hr(UiaGetPropertyValue(node, property, &v[0])))
	assert_equal(vt, load_int16(&v[0]) & 65535)
	if (vt == VT_BOOL): assert_equal(expect, (load_int16(&v[8]) & 65535) != 0)
	else: assert_equal(expect, load_int32(&v[8]))
	VariantClear(&v[0])


void client_text(int node, int property, char* expect):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, hr(UiaGetPropertyValue(node, property, &v[0])))
	assert_equal(VT_BSTR, load_int16(&v[0]) & 65535)
	assert_bstr(expect, load_int64(&v[8]))
	VariantClear(&v[0])


int client_node(int simple):
	int node = 0
	assert_equal(0, hr(UiaNodeFromProvider(simple, &node)))
	asserts(c"client node", node != 0)
	return node


void add_text(ui_access_tree* tree, int id, int field, char* text):
	assert_equal(1, ui_access_set_text(tree, id, field, text, strlen(text)))


ui_access_tree* build(int with_tabs, int checked):
	ui_access_tree* tree = ui_access_tree_new(64, 1024)
	tree.action = record_action
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, ui_rect_new(0.0, 0.0, 300.0, 200.0))
	add_text(tree, 1, UI_ACCESS_NAME, c"Settings")
	ui_access_node* button = ui_access_add(tree, 2, 1, UI_ACCESS_BUTTON, ui_rect_new(10.0, 10.0, 80.0, 30.0))
	button.states = UI_ACCESS_FOCUSABLE
	button.actions = UI_ACCESS_ACTIVATE | UI_ACCESS_FOCUS
	add_text(tree, 2, UI_ACCESS_NAME, c"Open")
	add_text(tree, 2, UI_ACCESS_DESCRIPTION, c"Opens a file")
	ui_access_node* box = ui_access_add(tree, 3, 1, UI_ACCESS_CHECKBOX, ui_rect_new(10.0, 50.0, 80.0, 20.0))
	box.actions = UI_ACCESS_TOGGLE
	if checked: box.states = UI_ACCESS_CHECKED
	add_text(tree, 3, UI_ACCESS_NAME, c"Wrap")
	ui_access_node* field = ui_access_add(tree, 4, 1, UI_ACCESS_TEXTBOX, ui_rect_new(100.0, 10.0, 150.0, 24.0))
	field.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_FOCUS
	field.states = UI_ACCESS_FOCUSABLE
	add_text(tree, 4, UI_ACCESS_NAME, c"Search")
	add_text(tree, 4, UI_ACCESS_VALUE, c"h\xc3\xa9llo")
	if with_tabs:
		ui_access_add(tree, 5, 1, UI_ACCESS_TAB_LIST, ui_rect_new(10.0, 80.0, 200.0, 30.0))
		ui_access_node* one = ui_access_add(tree, 6, 5, UI_ACCESS_TAB, ui_rect_new(10.0, 80.0, 100.0, 30.0))
		one.states = UI_ACCESS_SELECTED
		one.actions = UI_ACCESS_ACTIVATE
		add_text(tree, 6, UI_ACCESS_NAME, c"One")
		ui_access_node* two = ui_access_add(tree, 7, 5, UI_ACCESS_TAB, ui_rect_new(110.0, 80.0, 100.0, 30.0))
		two.actions = UI_ACCESS_ACTIVATE
		add_text(tree, 7, UI_ACCESS_NAME, c"Two")
	ui_access_node* combo = ui_access_add(tree, 8, 1, UI_ACCESS_COMBOBOX, ui_rect_new(10.0, 120.0, 100.0, 24.0))
	combo.actions = UI_ACCESS_ACTIVATE
	combo.states = UI_ACCESS_READONLY
	add_text(tree, 8, UI_ACCESS_NAME, c"Size")
	add_text(tree, 8, UI_ACCESS_VALUE, c"Medium")
	ui_access_add(tree, 9, 1, UI_ACCESS_PROGRESS, ui_rect_new(10.0, 150.0, 100.0, 10.0))
	add_text(tree, 9, UI_ACCESS_VALUE, c"40%")
	ui_access_node* sw = ui_access_add(tree, 10, 1, UI_ACCESS_SWITCH, ui_rect_new(120.0, 120.0, 40.0, 20.0))
	sw.actions = UI_ACCESS_TOGGLE
	add_text(tree, 10, UI_ACCESS_NAME, c"Dark")
	ui_access_node* heading = ui_access_add(tree, 11, 1, UI_ACCESS_HEADING, ui_rect_new(200.0, 150.0, 90.0, 20.0))
	heading.heading_level = 2
	add_text(tree, 11, UI_ACCESS_NAME, c"Title")
	# A table: a column-header row (13), then two data rows; the
	# selection is on row 16, or on row 19 without checked.
	ui_access_add(tree, 12, 1, UI_ACCESS_TABLE, ui_rect_new(10.0, 170.0, 200.0, 60.0))
	add_text(tree, 12, UI_ACCESS_NAME, c"Files")
	ui_access_add(tree, 13, 12, UI_ACCESS_ROW, ui_rect_new(10.0, 170.0, 200.0, 20.0))
	ui_access_add(tree, 14, 13, UI_ACCESS_CELL, ui_rect_new(10.0, 170.0, 100.0, 20.0))
	add_text(tree, 14, UI_ACCESS_NAME, c"Name")
	ui_access_add(tree, 15, 13, UI_ACCESS_CELL, ui_rect_new(110.0, 170.0, 100.0, 20.0))
	add_text(tree, 15, UI_ACCESS_NAME, c"Size")
	ui_access_node* first = ui_access_add(tree, 16, 12, UI_ACCESS_ROW, ui_rect_new(10.0, 190.0, 200.0, 20.0))
	first.actions = UI_ACCESS_ACTIVATE
	ui_access_add(tree, 17, 16, UI_ACCESS_CELL, ui_rect_new(10.0, 190.0, 100.0, 20.0))
	add_text(tree, 17, UI_ACCESS_NAME, c"a.png")
	ui_access_add(tree, 18, 16, UI_ACCESS_CELL, ui_rect_new(110.0, 190.0, 100.0, 20.0))
	add_text(tree, 18, UI_ACCESS_NAME, c"9 KB")
	ui_access_node* second = ui_access_add(tree, 19, 12, UI_ACCESS_ROW, ui_rect_new(10.0, 210.0, 200.0, 20.0))
	second.actions = UI_ACCESS_ACTIVATE
	ui_access_add(tree, 20, 19, UI_ACCESS_CELL, ui_rect_new(10.0, 210.0, 100.0, 20.0))
	add_text(tree, 20, UI_ACCESS_NAME, c"b.png")
	ui_access_add(tree, 21, 19, UI_ACCESS_CELL, ui_rect_new(110.0, 210.0, 100.0, 20.0))
	add_text(tree, 21, UI_ACCESS_NAME, c"4 KB")
	if checked: first.states = UI_ACCESS_SELECTED
	else: second.states = UI_ACCESS_SELECTED
	# A list with its first item selected.
	ui_access_add(tree, 22, 1, UI_ACCESS_LIST, ui_rect_new(220.0, 10.0, 70.0, 40.0))
	ui_access_node* item = ui_access_add(tree, 23, 22, UI_ACCESS_LIST_ITEM, ui_rect_new(220.0, 10.0, 70.0, 20.0))
	item.states = UI_ACCESS_SELECTED
	item.actions = UI_ACCESS_ACTIVATE
	add_text(tree, 23, UI_ACCESS_NAME, c"Red")
	ui_access_node* other = ui_access_add(tree, 24, 22, UI_ACCESS_LIST_ITEM, ui_rect_new(220.0, 30.0, 70.0, 20.0))
	other.actions = UI_ACCESS_ACTIVATE
	add_text(tree, 24, UI_ACCESS_NAME, c"Blue")
	tree.focused_id = 2
	return tree


# The Simple provider of root child id, found by walking FirstChild /
# NextSibling through the provider vtables.
int find_child(int root, int id):
	int f = navigate(fragment_of(root), NavigateDirection_FirstChild)
	while (f != 0):
		int s = simple_of(f)
		if (automation_id(s) == id):
			release(f)
			return s
		release(s)
		int next = navigate(f, NavigateDirection_NextSibling)
		release(f)
		f = next
	return 0


# Navigate from an element's Fragment interface; its HRESULT.
int navigate_hr(int simple):
	int fragment = query(simple, 2)
	int out = 0
	int r = call3(fragment, 3, NavigateDirection_Parent, cast(int, &out))
	release(fragment)
	return r


int client_node_maybe(int simple):
	int node = 0
	if (hr(UiaNodeFromProvider(simple, &node)) != 0): return 0
	return node


# The AutomationIds of a SAFEARRAY of providers (destroyed).
list[int] array_ids(int array):
	asserts(c"array", array != 0)
	list[int] ids = new list[int]
	int32[1] bound
	assert_equal(0, hr(SafeArrayGetUBound(array, 1, &bound[0])))
	int32[1] index
	for i in range(bound[0] + 1):
		index[0] = i
		int unknown = 0
		assert_equal(0, hr(SafeArrayGetElement(array, &index[0], cast(char*, &unknown))))
		int simple = query(unknown, 1)
		ids.push(automation_id(simple))
		release(simple)
		release(unknown)
	SafeArrayDestroy(array)
	return ids


# An element-array method (pattern slot) answering exactly ids a, b
# (0: unused).
void assert_array(int object, int slot, int count, int a, int b):
	int array = 0
	assert_equal(0, call2(object, slot, cast(int, &array)))
	list[int] ids = array_ids(array)
	assert_equal(count, ids.length)
	if (count > 0): assert_equal(a, ids[0])
	if (count > 1): assert_equal(b, ids[1])
	list_free[int](ids)


# A 32-bit pattern getter.
int get32(int object, int slot):
	int32[1] out
	out[0] = 0 - 7
	assert_equal(0, call2(object, slot, cast(int, &out[0])))
	return out[0]


# A provider property's VARIANT type and 32-bit payload.
int provider_i4(int simple, int property):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, call3(simple, 5, property, cast(int, &v[0])))
	assert_equal(VT_I4, load_int16(&v[0]) & 65535)
	return load_int32(&v[8])


/* MSAA through the IAccessible vtable. */

char* child_id(char* v, int id):
	ui_uia_variant_clear(v)
	ui_uia_variant_i4(v, id)
	return v


int acc_of(int simple):
	int a = query(simple, UI_UIA_ACCESSIBLE + 1)
	asserts(c"IAccessible", a != 0)
	return a


# A BSTR getter (slot) for child; its HRESULT, the text compared when
# expect is not 0.
int acc_text(int acc, int slot, int child, char* expect):
	char[24] v
	int bstr = 0
	int r = call3(acc, slot, cast(int, child_id(&v[0], child)), cast(int, &bstr))
	if (expect != 0):
		assert_equal(0, r)
		assert_bstr(expect, bstr)
	if (bstr != 0): SysFreeString(bstr)
	return r


int acc_i4(int acc, int slot, int child):
	char[24] v
	char[24] out
	ui_uia_variant_clear(&out[0])
	assert_equal(0, call3(acc, slot, cast(int, child_id(&v[0], child)), cast(int, &out[0])))
	assert_equal(VT_I4, load_int16(&out[0]) & 65535)
	return load_int32(&out[8])


int acc_role(int acc, int child):
	return acc_i4(acc, 13, child)


int acc_state(int acc, int child):
	return acc_i4(acc, 14, child)


# A VARIANT answer: VT_I4 child id, else the object (released) compared
# with expect.
void assert_acc_variant(char* v, int expect_vt, int expect):
	assert_equal(expect_vt, load_int16(v) & 65535)
	if (expect_vt == VT_I4): assert_equal(expect, load_int32(&v[8]))
	if (expect_vt == VT_DISPATCH):
		int object = load_int64(&v[8])
		assert_equal(expect, object)
		release(object)


int main():
	ui_uia_bridge* bridge = ui_access_uia_open(0)
	asserts(c"bridge", bridge != 0)
	ui_access_uia_set_origin(bridge, 1000, 500)
	assert_equal(0, ui_access_uia_root(bridge))
	ui_access_tree* app = build(1, 1)
	assert_equal(1, ui_access_uia_publish(bridge, app))
	int root = ui_access_uia_root(bridge)
	asserts(c"root provider", root != 0)

	# --- the UIA client API (wine's uiautomationcore) ---
	int root_node = client_node(root)
	client_int(root_node, UIA_ControlTypePropertyId, VT_I4, UIA_PaneControlTypeId)
	client_text(root_node, UIA_NamePropertyId, c"Settings")
	client_text(root_node, UIA_FrameworkIdPropertyId, c"W")
	int runtime = 0
	assert_equal(0, hr(UiaGetRuntimeId(root_node, &runtime)))
	asserts(c"runtime id", runtime != 0)
	int32[1] index
	int32[1] part
	index[0] = 1
	assert_equal(0, hr(SafeArrayGetElement(runtime, &index[0], cast(char*, &part[0]))))
	assert_equal(1, part[0])
	SafeArrayDestroy(runtime)

	# UiaNavigate to the first child with a true condition and a
	# cache request for the element alone; the answer is a 1x1 array
	# holding the child node.
	char[8] condition
	save_int64(&condition[0], 0)                       /* ConditionType_True */
	char[48] cache
	for i in range(48): cache[i] = 0
	save_int64(&cache[0], cast(int, &condition[0]))    /* pViewCondition */
	save_int32(&cache[8], 1)                           /* TreeScope_Element */
	save_int32(&cache[44], 1)                          /* AutomationElementMode_Full */
	int requested = 0
	int structure = 0
	assert_equal(0, hr(UiaNavigate(root_node, NavigateDirection_FirstChild, &condition[0], &cache[0], &requested, &structure)))
	asserts(c"navigate result", requested != 0)
	char* data = cast(char*, load_int64(cast(char*, requested + 16)))  /* SAFEARRAY.pvData */
	int button_node = 0
	assert_equal(0, hr(UiaHUiaNodeFromVariant(data, &button_node)))
	client_text(button_node, UIA_NamePropertyId, c"Open")
	client_int(button_node, UIA_ControlTypePropertyId, VT_I4, UIA_ButtonControlTypeId)
	client_int(button_node, UIA_IsEnabledPropertyId, VT_BOOL, 1)
	client_int(button_node, UIA_HasKeyboardFocusPropertyId, VT_BOOL, 1)
	client_int(button_node, UIA_IsKeyboardFocusablePropertyId, VT_BOOL, 1)
	client_text(button_node, UIA_HelpTextPropertyId, c"Opens a file")
	SafeArrayDestroy(requested)

	# --- provider vtables, for what wine's client cannot drive ---
	int button = find_child(root, 2)
	int box = find_child(root, 3)
	int field = find_child(root, 4)
	int combo = find_child(root, 8)
	int progress = find_child(root, 9)
	int sw = find_child(root, 10)
	int heading = find_child(root, 11)
	asserts(c"children", (button != 0) && (box != 0) && (field != 0) && (combo != 0) && (progress != 0) && (sw != 0) && (heading != 0))
	int tabs = find_child(root, 5)
	int tab_two = simple_of(navigate(fragment_of(tabs), NavigateDirection_LastChild))
	assert_equal(7, automation_id(tab_two))

	# Identity: the same node hands out the same COM object, and IUnknown
	# is the Simple interface.
	int again = find_child(root, 2)
	assert_equal(button, again)
	release(again)
	int unknown = query(button, 0)
	assert_equal(button, unknown)
	release(unknown)
	assert_equal(0, query(button, 3))                  /* not a fragment root */
	asserts(c"root is a fragment root", query(root, 3) != 0)

	# Options: server side, COM threading.
	int32[1] options
	assert_equal(0, call2(button, 3, cast(int, &options[0])))
	assert_equal(33, options[0])

	# Pattern support by role.
	assert_equal(0, pattern(button, UIA_TogglePatternId))
	int invoke = pattern(button, UIA_InvokePatternId)
	asserts(c"invoke pattern", invoke != 0)
	assert_equal(0, pattern(box, UIA_InvokePatternId))
	int toggle = pattern(box, UIA_TogglePatternId)
	int switch_toggle = pattern(sw, UIA_TogglePatternId)
	int value = pattern(field, UIA_ValuePatternId)
	int combo_value = pattern(combo, UIA_ValuePatternId)
	int expand = pattern(combo, UIA_ExpandCollapsePatternId)
	int select = pattern(tab_two, UIA_SelectionItemPatternId)
	int range = pattern(progress, UIA_RangeValuePatternId)
	asserts(c"patterns", (toggle != 0) && (switch_toggle != 0) && (value != 0) && (combo_value != 0) && (expand != 0) && (select != 0) && (range != 0))

	# Pattern reads.
	int32[1] state
	assert_equal(0, call2(toggle, 4, cast(int, &state[0])))
	assert_equal(1, state[0])                          /* ToggleState_On */
	assert_equal(0, call2(switch_toggle, 4, cast(int, &state[0])))
	assert_equal(0, state[0])
	int text = 0
	assert_equal(0, call2(value, 4, cast(int, &text)))
	assert_bstr(c"h\xc3\xa9llo", text)
	SysFreeString(text)
	assert_equal(0, call2(value, 5, cast(int, &state[0])))
	assert_equal(0, state[0])
	assert_equal(0, call2(combo_value, 5, cast(int, &state[0])))
	assert_equal(1, state[0])                          /* read-only combobox */
	assert_equal(0, call2(expand, 5, cast(int, &state[0])))
	assert_equal(0, state[0])                          /* Collapsed */
	assert_equal(0, call2(select, 6, cast(int, &state[0])))
	assert_equal(0, state[0])
	int container = 0
	assert_equal(0, call2(select, 7, cast(int, &container)))
	assert_equal(tabs, container)
	release(container)
	float64[1] number
	assert_equal(0, call2(range, 4, cast(int, &number[0])))
	assert_equal(40, cast(int, number[0]))
	assert_equal(0, call2(range, 6, cast(int, &number[0])))
	assert_equal(100, cast(int, number[0]))
	assert_equal(0, call2(range, 5, cast(int, &state[0])))
	assert_equal(1, state[0])

	# Properties straight from the provider.
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, call3(sw, 5, UIA_ControlTypePropertyId, cast(int, &v[0])))
	assert_equal(UIA_ButtonControlTypeId, load_int32(&v[8]))
	assert_equal(0, call3(sw, 5, UIA_LocalizedControlTypePropertyId, cast(int, &v[0])))
	assert_bstr(c"toggle switch", load_int64(&v[8]))
	VariantClear(&v[0])
	assert_equal(0, call3(heading, 5, UIA_HeadingLevelPropertyId, cast(int, &v[0])))
	assert_equal(HeadingLevel_None + 2, load_int32(&v[8]))
	assert_equal(0, call3(box, 5, UIA_ToggleToggleStatePropertyId, cast(int, &v[0])))
	assert_equal(1, load_int32(&v[8]))
	assert_equal(0, call3(tab_two, 5, UIA_SelectionItemIsSelectedPropertyId, cast(int, &v[0])))
	assert_equal(VT_BOOL, load_int16(&v[0]) & 65535)
	assert_equal(0, load_int16(&v[8]))

	# Bounds are screen coordinates: origin (1000, 500) plus the node's.
	float64[4] rect
	int button_fragment = fragment_of(button)
	assert_equal(0, call2(button_fragment, 5, cast(int, &rect[0])))
	assert_equal(1010, cast(int, rect[0]))
	assert_equal(510, cast(int, rect[1]))
	assert_equal(80, cast(int, rect[2]))
	assert_equal(30, cast(int, rect[3]))

	# Root: ElementProviderFromPoint (doubles in xmm1/xmm2) and GetFocus.
	int fragment_root = query(root, 3)
	uia_point* from_point = cast(uia_point*, method(fragment_root, 3, 4))
	int hit = 0
	assert_equal(0, hr(from_point(fragment_root, 1015.0, 520.0, cast(int, &hit))))
	asserts(c"hit", hit != 0)
	int hit_simple = simple_of(hit)
	assert_equal(2, automation_id(hit_simple))
	release(hit_simple)
	release(hit)
	assert_equal(0, hr(from_point(fragment_root, 5000.0, 5000.0, cast(int, &hit))))
	assert_equal(0, hit)
	int focus = 0
	assert_equal(0, call2(fragment_root, 4, cast(int, &focus)))
	int focus_simple = simple_of(focus)
	assert_equal(button, focus_simple)
	release(focus_simple)
	release(focus)
	int fragment_back = 0
	assert_equal(0, call2(button_fragment, 8, cast(int, &fragment_back)))
	assert_equal(fragment_root, fragment_back)
	release(fragment_back)
	assert_equal(0, navigate(fragment_of(root), NavigateDirection_Parent))

	# --- Selection, Grid and Table ---
	int table = find_child(root, 12)
	int list_box = find_child(root, 22)
	asserts(c"containers", (table != 0) && (list_box != 0))
	int selection = pattern(table, UIA_SelectionPatternId)
	int tab_selection = pattern(tabs, UIA_SelectionPatternId)
	int list_selection = pattern(list_box, UIA_SelectionPatternId)
	asserts(c"selection patterns", (selection != 0) && (tab_selection != 0) && (list_selection != 0))
	assert_equal(0, pattern(button, UIA_SelectionPatternId))
	assert_array(selection, 3, 1, 16, 0)
	assert_equal(0, get32(selection, 4))               /* CanSelectMultiple */
	assert_equal(0, get32(selection, 5))               /* IsSelectionRequired */
	assert_array(tab_selection, 3, 1, 6, 0)
	assert_equal(1, get32(tab_selection, 5))
	assert_array(list_selection, 3, 1, 23, 0)
	int grid = pattern(table, UIA_GridPatternId)
	int table_pattern = pattern(table, UIA_TablePatternId)
	asserts(c"grid and table", (grid != 0) && (table_pattern != 0))
	assert_equal(0, pattern(list_box, UIA_GridPatternId))
	assert_equal(2, get32(grid, 4))                    /* data rows */
	assert_equal(2, get32(grid, 5))
	int cell = 0
	assert_equal(0, call4(grid, 3, 1, 1, cast(int, &cell)))
	assert_equal(21, automation_id(cell))
	int stray = 0
	assert_equal(cast(int, UIA_E_INVALIDARG), call4(grid, 3, 2, 0, cast(int, &stray)))
	assert_equal(0, stray)
	assert_array(table_pattern, 4, 2, 14, 15)          /* column headers */
	assert_array(table_pattern, 3, 0, 0, 0)            /* no row headers */
	assert_equal(0, get32(table_pattern, 5))           /* RowMajor */
	int grid_item = pattern(cell, UIA_GridItemPatternId)
	int table_item = pattern(cell, UIA_TableItemPatternId)
	asserts(c"cell patterns", (grid_item != 0) && (table_item != 0))
	assert_equal(1, get32(grid_item, 3))
	assert_equal(1, get32(grid_item, 4))
	assert_equal(1, get32(grid_item, 5))
	assert_equal(1, get32(grid_item, 6))
	int containing = 0
	assert_equal(0, call2(grid_item, 7, cast(int, &containing)))
	assert_equal(table, containing)
	release(containing)
	assert_array(table_item, 4, 1, 15, 0)
	assert_array(table_item, 3, 0, 0, 0)
	assert_equal(1, provider_i4(cell, UIA_GridItemRowPropertyId))
	assert_equal(1, provider_i4(cell, UIA_GridItemColumnPropertyId))
	assert_equal(2, provider_i4(table, UIA_GridRowCountPropertyId))
	assert_equal(2, provider_i4(table, UIA_GridColumnCountPropertyId))
	assert_equal(0, provider_i4(table, UIA_TableRowOrColumnMajorPropertyId))
	ui_uia_variant_clear(&v[0])
	assert_equal(0, call3(cell, 5, UIA_GridItemContainingGridPropertyId, cast(int, &v[0])))
	assert_equal(VT_UNKNOWN, load_int16(&v[0]) & 65535)
	assert_equal(table, load_int64(&v[8]))
	VariantClear(&v[0])
	assert_equal(0, call3(table, 5, UIA_SelectionSelectionPropertyId, cast(int, &v[0])))
	assert_equal(VT_UNKNOWN | VT_ARRAY, load_int16(&v[0]) & 65535)
	list[int] selected_ids = array_ids(load_int64(&v[8]))
	assert_equal(16, selected_ids[0])
	list_free[int](selected_ids)
	ui_uia_variant_clear(&v[0])
	assert_equal(0, call3(tab_two, 5, UIA_SelectionIsSelectionRequiredPropertyId, cast(int, &v[0])))
	assert_equal(VT_EMPTY, load_int16(&v[0]) & 65535)  /* not a container */
	# Rows: the header row is a Header of HeaderItems (not selectable,
	# not grid items); data rows are DataItems selected in the table.
	int header_row = simple_of(navigate(fragment_of(table), NavigateDirection_FirstChild))
	assert_equal(13, automation_id(header_row))
	assert_equal(UIA_HeaderControlTypeId, provider_i4(header_row, UIA_ControlTypePropertyId))
	assert_equal(0, pattern(header_row, UIA_SelectionItemPatternId))
	int header_cell = simple_of(navigate(fragment_of(header_row), NavigateDirection_FirstChild))
	assert_equal(UIA_HeaderItemControlTypeId, provider_i4(header_cell, UIA_ControlTypePropertyId))
	assert_equal(0, pattern(header_cell, UIA_GridItemPatternId))
	int data_row = simple_of(navigate(fragment_of(cell), NavigateDirection_Parent))
	assert_equal(19, automation_id(data_row))
	assert_equal(UIA_DataItemControlTypeId, provider_i4(data_row, UIA_ControlTypePropertyId))
	int row_select = pattern(data_row, UIA_SelectionItemPatternId)
	container = 0
	assert_equal(0, call2(row_select, 7, cast(int, &container)))
	assert_equal(table, container)
	release(container)
	# The same answers through wine's client, where its property table
	# knows them.
	int table_node = client_node(table)
	client_int(table_node, UIA_ControlTypePropertyId, VT_I4, UIA_TableControlTypeId)
	client_text(table_node, UIA_NamePropertyId, c"Files")
	UiaNodeRelease(table_node)

	# --- MSAA IAccessible ---
	int acc = acc_of(root)
	int dispatch = query(root, UI_UIA_IDISPATCH_SLOT)
	assert_equal(acc, dispatch)
	release(dispatch)
	int unknown_of_acc = query(acc, 0)
	assert_equal(root, unknown_of_acc)
	release(unknown_of_acc)
	int32[1] count
	assert_equal(0, call2(acc, 3, cast(int, &count[0])))   /* GetTypeInfoCount */
	assert_equal(0, count[0])
	assert_equal(cast(int, UIA_E_NOTIMPL), call1(acc, 6))  /* Invoke */
	assert_equal(0, call2(acc, 8, cast(int, &count[0])))
	assert_equal(10, count[0])
	acc_text(acc, 10, CHILDID_SELF, c"Settings")
	assert_equal(ROLE_SYSTEM_CLIENT, acc_role(acc, CHILDID_SELF))
	acc_text(acc, 10, 1, c"Open")
	assert_equal(ROLE_SYSTEM_PUSHBUTTON, acc_role(acc, 1))
	assert_equal(STATE_SYSTEM_FOCUSED | STATE_SYSTEM_FOCUSABLE, acc_state(acc, 1))
	acc_text(acc, 12, 0 - 2, c"Opens a file")
	acc_text(acc, 20, 0 - 2, c"Press")
	assert_equal(UIA_S_FALSE, acc_text(acc, 11, 0 - 2, 0))  /* no value */
	acc_text(acc, 11, 0 - 4, c"h\xc3\xa9llo")
	acc_text(acc, 11, 0 - 9, c"40%")
	assert_equal(UIA_S_FALSE, acc_text(acc, 15, 0 - 2, 0))  /* help */
	assert_equal(UIA_S_FALSE, acc_text(acc, 17, 0 - 2, 0))  /* shortcut */
	assert_equal(ROLE_SYSTEM_CHECKBUTTON, acc_role(acc, 0 - 3))
	assert_equal(STATE_SYSTEM_CHECKED, acc_state(acc, 0 - 3))
	acc_text(acc, 20, 0 - 3, c"Uncheck")
	assert_equal(ROLE_SYSTEM_CHECKBUTTON, acc_role(acc, 0 - 10))
	assert_equal(ROLE_SYSTEM_TEXT, acc_role(acc, 0 - 4))
	assert_equal(ROLE_SYSTEM_PAGETABLIST, acc_role(acc, 0 - 5))
	assert_equal(ROLE_SYSTEM_PAGETAB, acc_role(acc, 0 - 6))
	assert_equal(STATE_SYSTEM_SELECTED | STATE_SYSTEM_SELECTABLE, acc_state(acc, 0 - 6))
	acc_text(acc, 20, 0 - 6, c"Switch")
	assert_equal(ROLE_SYSTEM_COMBOBOX, acc_role(acc, 0 - 8))
	assert_equal(STATE_SYSTEM_READONLY | STATE_SYSTEM_COLLAPSED | STATE_SYSTEM_HASPOPUP, acc_state(acc, 0 - 8))
	acc_text(acc, 11, 0 - 8, c"Medium")
	acc_text(acc, 20, 0 - 8, c"Open")
	assert_equal(ROLE_SYSTEM_PROGRESSBAR, acc_role(acc, 0 - 9))
	assert_equal(ROLE_SYSTEM_STATICTEXT, acc_role(acc, 0 - 11))
	assert_equal(ROLE_SYSTEM_TABLE, acc_role(acc, 0 - 12))
	assert_equal(ROLE_SYSTEM_ROW, acc_role(acc, 0 - 13))
	assert_equal(0, acc_state(acc, 0 - 13))            /* the header row */
	assert_equal(ROLE_SYSTEM_COLUMNHEADER, acc_role(acc, 0 - 14))
	assert_equal(ROLE_SYSTEM_CELL, acc_role(acc, 0 - 17))
	assert_equal(STATE_SYSTEM_SELECTED | STATE_SYSTEM_SELECTABLE, acc_state(acc, 0 - 16))
	acc_text(acc, 20, 0 - 16, c"Select")
	assert_equal(ROLE_SYSTEM_LIST, acc_role(acc, 0 - 22))
	assert_equal(ROLE_SYSTEM_LISTITEM, acc_role(acc, 0 - 23))
	# Child ids out of range, or not VT_I4.
	char[24] child
	char[24] answer
	ui_uia_variant_clear(&answer[0])
	assert_equal(cast(int, UIA_E_INVALIDARG), call3(acc, 13, cast(int, child_id(&child[0], 11)), cast(int, &answer[0])))
	assert_equal(cast(int, UIA_E_INVALIDARG), call3(acc, 13, cast(int, child_id(&child[0], 0 - 999)), cast(int, &answer[0])))
	save_int16(&child[0], VT_BSTR)
	assert_equal(cast(int, UIA_E_INVALIDARG), call3(acc, 13, cast(int, &child[0]), cast(int, &answer[0])))
	# Children as objects, and their parents.
	int button_acc = acc_of(button)
	int child_object = 0
	assert_equal(0, call3(acc, 9, cast(int, child_id(&child[0], 1)), cast(int, &child_object)))
	assert_equal(button_acc, child_object)
	release(child_object)
	int parent_object = 0
	assert_equal(0, call2(button_acc, 7, cast(int, &parent_object)))
	assert_equal(acc, parent_object)
	release(parent_object)
	assert_equal(UIA_S_FALSE, call2(acc, 7, cast(int, &parent_object)))  /* unhosted */
	assert_equal(0, parent_object)
	acc_text(button_acc, 10, CHILDID_SELF, c"Open")
	# Location, hit testing, navigation, focus and selection.
	int32[4] location
	assert_equal(0, call6(acc, 22, cast(int, &location[0]), cast(int, &location[1]), cast(int, &location[2]), cast(int, &location[3]), cast(int, child_id(&child[0], 0 - 2))))
	assert_equal(1010, location[0])
	assert_equal(510, location[1])
	assert_equal(80, location[2])
	assert_equal(30, location[3])
	ui_uia_variant_clear(&answer[0])
	assert_equal(0, call4(acc, 24, 1015, 520, cast(int, &answer[0])))
	assert_acc_variant(&answer[0], VT_DISPATCH, button_acc)
	assert_equal(0, call4(button_acc, 24, 1015, 520, cast(int, &answer[0])))
	assert_acc_variant(&answer[0], VT_I4, CHILDID_SELF)
	assert_equal(UIA_S_FALSE, call4(acc, 24, 5000, 5000, cast(int, &answer[0])))
	assert_acc_variant(&answer[0], VT_EMPTY, 0)
	assert_equal(0, call4(acc, 23, NAVDIR_FIRSTCHILD, cast(int, child_id(&child[0], CHILDID_SELF)), cast(int, &answer[0])))
	assert_acc_variant(&answer[0], VT_DISPATCH, button_acc)
	int box_acc = acc_of(box)
	assert_equal(0, call4(acc, 23, NAVDIR_NEXT, cast(int, child_id(&child[0], 1)), cast(int, &answer[0])))
	assert_acc_variant(&answer[0], VT_DISPATCH, box_acc)
	assert_equal(UIA_S_FALSE, call4(acc, 23, NAVDIR_PREVIOUS, cast(int, child_id(&child[0], 1)), cast(int, &answer[0])))
	assert_equal(cast(int, UIA_E_INVALIDARG), call4(acc, 23, NAVDIR_FIRSTCHILD, cast(int, child_id(&child[0], 1)), cast(int, &answer[0])))
	assert_equal(cast(int, DISP_E_MEMBERNOTFOUND), call4(acc, 23, NAVDIR_UP, cast(int, child_id(&child[0], 1)), cast(int, &answer[0])))
	assert_equal(0, call2(acc, 18, cast(int, &answer[0])))
	assert_acc_variant(&answer[0], VT_DISPATCH, button_acc)
	assert_equal(0, call2(button_acc, 18, cast(int, &answer[0])))
	assert_acc_variant(&answer[0], VT_I4, CHILDID_SELF)
	assert_equal(UIA_S_FALSE, call2(box_acc, 18, cast(int, &answer[0])))
	int table_acc = acc_of(table)
	int first_row_acc = 0
	assert_equal(0, call3(acc, 9, cast(int, child_id(&child[0], 0 - 16)), cast(int, &first_row_acc)))
	assert_equal(0, call2(table_acc, 19, cast(int, &answer[0])))
	assert_acc_variant(&answer[0], VT_DISPATCH, first_row_acc)
	assert_equal(UIA_S_FALSE, call2(button_acc, 19, cast(int, &answer[0])))
	assert_equal(cast(int, UIA_E_NOTIMPL), call3(acc, 26, cast(int, child_id(&child[0], 0 - 4)), 0))  /* put_accName */
	# OBJID_CLIENT: WM_GETOBJECT's LRESULT is the root IAccessible.
	int lresult = ui_access_uia_getobject(bridge, 0, 0, OBJID_CLIENT)
	asserts(c"OBJID_CLIENT answered", lresult > 0)
	int from_lresult = 0
	assert_equal(0, hr(ObjectFromLresult(lresult, ui_uia_iids_at(UI_UIA_ACCESSIBLE + 1), 0, &from_lresult)))
	acc_text(from_lresult, 10, CHILDID_SELF, c"Settings")
	release(from_lresult)

	# Actions queue until dispatch, which revalidates them against the
	# application's tree.
	assert_equal(0, call1(invoke, 3))
	assert_equal(0, call1(toggle, 3))
	char[16] wide
	char* hi = c"Hi\xe2\x82\xac"   /* "Hi" + U+20AC */
	save_int16(&wide[0], 'H')
	save_int16(&wide[2], 'i')
	save_int16(&wide[4], 8364)
	save_int16(&wide[6], 0)
	assert_equal(0, call2(value, 3, cast(int, &wide[0])))
	assert_equal(0, call1(select, 3))
	assert_equal(0, call1(expand, 3))
	assert_equal(0, call1(expand, 4))                  /* already collapsed: no-op */
	assert_equal(0, call1(button_fragment, 7))         /* SetFocus */
	assert_equal(cast(int, UIA_E_ELEMENTNOTENABLED), call2(combo_value, 3, cast(int, &wide[0])))
	assert_equal(cast(int, UIA_E_ELEMENTNOTENABLED), call2(range, 3, 0))
	assert_equal(0, action_count)
	assert_equal(6, ui_access_uia_dispatch(bridge, app))
	assert_equal(6, action_count)
	assert_equal(UI_ACCESS_ACTIVATE, actions_seen[0])
	assert_equal(2, action_ids[0])
	assert_equal(UI_ACCESS_TOGGLE, actions_seen[1])
	assert_equal(3, action_ids[1])
	assert_equal(UI_ACCESS_SET_VALUE, actions_seen[2])
	assert_equal(4, action_ids[2])
	assert_equal(5, last_length)
	for i in range(5): assert_equal(hi[i], last_value[i])
	assert_equal(UI_ACCESS_ACTIVATE, actions_seen[3])
	assert_equal(7, action_ids[3])
	assert_equal(UI_ACCESS_ACTIVATE, actions_seen[4])
	assert_equal(8, action_ids[4])
	assert_equal(UI_ACCESS_FOCUS, actions_seen[5])
	assert_equal(2, app.focused_id)
	assert_equal(0, ui_access_uia_dispatch(bridge, app))

	# MSAA actions go through the same queue.
	action_count = 0
	assert_equal(0, call2(acc, 25, cast(int, child_id(&child[0], 0 - 3))))   /* toggle */
	assert_equal(cast(int, DISP_E_MEMBERNOTFOUND), call2(acc, 25, cast(int, child_id(&child[0], 0 - 11))))
	char[8] ok
	save_int16(&ok[0], 'o')
	save_int16(&ok[2], 'k')
	save_int16(&ok[4], 0)
	assert_equal(0, call3(acc, 27, cast(int, child_id(&child[0], 0 - 4)), cast(int, &ok[0])))
	assert_equal(cast(int, DISP_E_MEMBERNOTFOUND), call3(acc, 27, cast(int, child_id(&child[0], 0 - 2)), cast(int, &ok[0])))
	assert_equal(0, call3(acc, 21, SELFLAG_TAKESELECTION, cast(int, child_id(&child[0], 0 - 19))))
	assert_equal(0, call3(acc, 21, SELFLAG_TAKESELECTION, cast(int, child_id(&child[0], 0 - 16))))   /* already */
	assert_equal(cast(int, UIA_E_FAIL), call3(acc, 21, SELFLAG_REMOVESELECTION, cast(int, child_id(&child[0], 0 - 16))))
	assert_equal(cast(int, UIA_E_INVALIDARG), call3(acc, 21, SELFLAG_EXTENDSELECTION, cast(int, child_id(&child[0], 0 - 16))))
	assert_equal(cast(int, UIA_E_INVALIDARG), call3(acc, 21, SELFLAG_TAKESELECTION, cast(int, child_id(&child[0], 0 - 2))))
	assert_equal(0, call3(acc, 21, SELFLAG_TAKEFOCUS, cast(int, child_id(&child[0], 0 - 4))))
	assert_equal(4, ui_access_uia_dispatch(bridge, app))
	assert_equal(4, action_count)
	assert_equal(UI_ACCESS_TOGGLE, actions_seen[0])
	assert_equal(3, action_ids[0])
	assert_equal(UI_ACCESS_SET_VALUE, actions_seen[1])
	assert_equal(4, action_ids[1])
	assert_equal(2, last_length)
	assert_equal('o', last_value[0])
	assert_equal(UI_ACCESS_ACTIVATE, actions_seen[2])
	assert_equal(19, action_ids[2])
	assert_equal(UI_ACCESS_FOCUS, actions_seen[3])
	assert_equal(4, action_ids[3])
	int tab_two_acc = acc_of(tab_two)

	# Republish without the tabs and with the checkbox cleared: property
	# and structure events are raised (when clients listen), the tabs'
	# providers stop answering, and the survivors keep their identity.
	# wine delivers focus-changed events to an in-process client (its
	# property-changed and structure-changed paths are stubs).
	int selected_event = 0
	assert_equal(0, hr(UiaAddEvent(root_node, UIA_SelectionItem_ElementSelectedEventId, win_callback(cast(int, on_event), 3), 7, cast(int32*, 0), 0, &cache[0], &selected_event)))
	int focus_event = 0
	assert_equal(0, hr(UiaAddEvent(root_node, UIA_AutomationFocusChangedEventId, win_callback(cast(int, on_event), 3), 7, cast(int32*, 0), 0, &cache[0], &focus_event)))
	ui_access_tree* next = build(0, 0)
	next.focused_id = 4
	assert_equal(1, ui_access_uia_publish(bridge, next))
	wait_for_events()
	assert_equal(1, focus_events)
	assert_equal(1, selected_events)                   /* row 19 */
	assert_equal(0, hr(UiaRemoveEvent(focus_event)))
	assert_equal(0, hr(UiaRemoveEvent(selected_event)))
	# The selection moved with the republication.
	assert_array(selection, 3, 1, 19, 0)
	assert_equal(0, call2(table_acc, 19, cast(int, &answer[0])))
	int second_row_acc = 0
	assert_equal(0, call3(acc, 9, cast(int, child_id(&child[0], 0 - 19)), cast(int, &second_row_acc)))
	assert_acc_variant(&answer[0], VT_DISPATCH, second_row_acc)
	release(second_row_acc)
	# A removed node's IAccessible fails, and its child id is gone.
	int dead_name = 0
	assert_equal(cast(int, UIA_E_FAIL), call3(tab_two_acc, 10, cast(int, child_id(&child[0], CHILDID_SELF)), cast(int, &dead_name)))
	assert_equal(cast(int, UIA_E_INVALIDARG), call3(acc, 10, cast(int, child_id(&child[0], 0 - 7)), cast(int, &dead_name)))
	release(tab_two_acc)
	assert_equal(0, call2(toggle, 4, cast(int, &state[0])))
	assert_equal(0, state[0])
	assert_equal(button, find_child(root, 2))
	release(button)
	assert_equal(cast(int, UIA_E_ELEMENTNOTAVAILABLE), call1(select, 3))
	assert_equal(cast(int, UIA_E_ELEMENTNOTAVAILABLE), call2(select, 6, cast(int, &state[0])))
	assert_equal(cast(int, UIA_E_ELEMENTNOTAVAILABLE), call3(tab_two, 5, UIA_NamePropertyId, cast(int, &v[0])))
	assert_equal(cast(int, UIA_E_ELEMENTNOTAVAILABLE), call3(tab_two, 4, UIA_InvokePatternId, cast(int, &v[0])))
	assert_equal(cast(int, UIA_E_ELEMENTNOTAVAILABLE), navigate_hr(tab_two))
	assert_equal(0, query(tab_two, 7))                 /* patterns gone too */
	# Through the client the dead element no longer reports a name:
	# Windows propagates the provider's UIA_E_ELEMENTNOTAVAILABLE, wine
	# answers S_OK with the reserved not-supported value (VT_UNKNOWN).
	char[24] dead_value
	ui_uia_variant_clear(&dead_value[0])
	int tab_node = client_node_maybe(tab_two)
	if (tab_node != 0):
		int dead_hr = hr(UiaGetPropertyValue(tab_node, UIA_NamePropertyId, &dead_value[0]))
		asserts(c"dead property", (dead_hr != 0) || ((load_int16(&dead_value[0]) & 65535) != VT_BSTR))
		UiaNodeRelease(tab_node)
	release(select)
	release(tab_two)
	release(tabs)

	# WM_GETOBJECT answers UiaRootObjectId and OBJID_CLIENT, nothing else.
	assert_equal(0, ui_access_uia_getobject(bridge, 0, 0, OBJID_WINDOW))
	assert_equal(0, ui_access_uia_wm_getobject(0, 0, 0 - 3))         /* OBJID_SYSMENU */

	UiaNodeRelease(button_node)
	UiaNodeRelease(root_node)
	release(invoke)
	release(toggle)
	release(switch_toggle)
	release(value)
	release(combo_value)
	release(expand)
	release(range)
	release(button_fragment)
	release(fragment_root)
	release(selection)
	release(tab_selection)
	release(list_selection)
	release(grid)
	release(table_pattern)
	release(grid_item)
	release(table_item)
	release(row_select)
	release(cell)
	release(data_row)
	release(header_row)
	release(header_cell)
	release(first_row_acc)
	release(box_acc)
	release(table_acc)
	release(button_acc)
	release(acc)
	release(table)
	release(list_box)
	ui_access_uia_close(bridge)
	ui_access_tree_free(app)
	ui_access_tree_free(next)
	println(c"UI Automation bridge OK")
	return 0
