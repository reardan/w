# wbuild: name=graphics_ui_accessibility_uia_test arch_only=win64
# The UI Automation bridge driven in-process, under wine in CI. A UIA
# client (uiautomationcore's UiaNodeFromProvider / UiaGetPropertyValue /
# UiaGetRuntimeId / UiaNavigate) reads the published providers; control
# patterns are called through their vtables, because wine's flat
# pattern functions (InvokePattern_Invoke, ...) are stubs. The bridge is
# unhosted (hwnd 0): CI's wine has no display to create a window on.
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

c_lib "oleaut32.dll"
extern int SafeArrayGetElement(int array, int32* index, char* value)
extern int SafeArrayDestroy(int array)
extern int SafeArrayGetUBound(int array, int dim, int32* bound)
extern int VariantClear(char* value)


type uia_m1 = fn(int) -> int
type uia_m2 = fn(int, int) -> int
type uia_m3 = fn(int, int, int) -> int
type uia_point = fn(int, float64, float64, int) -> int


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
	ui_access_tree* tree = ui_access_tree_new(16, 512)
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

	# Republish without the tabs and with the checkbox cleared: property
	# and structure events are raised (when clients listen), the tabs'
	# providers stop answering, and the survivors keep their identity.
	ui_access_tree* next = build(0, 0)
	assert_equal(1, ui_access_uia_publish(bridge, next))
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

	# WM_GETOBJECT answers only UiaRootObjectId.
	assert_equal(0, ui_access_uia_getobject(bridge, 0, 0, 0 - 4))   /* OBJID_CLIENT */
	assert_equal(0, ui_access_uia_wm_getobject(0, 0, 0 - 4))

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
	ui_access_uia_close(bridge)
	ui_access_tree_free(app)
	ui_access_tree_free(next)
	println(c"UI Automation bridge OK")
	return 0
