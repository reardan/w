# wbuild: name=graphics_ui_accessibility_uia_window_test arch_only=win64
# The UI Automation / MSAA bridge hosted by a real window, under wine
# with an X display (CI runs tests_win64 under xvfb-run; without a
# display wine cannot create a window and the test skips). The tree is
# published through graphics.__arch__.access_platform, which installs
# graphics.window_win32's WM_GETOBJECT hook, so:
#
#   - in process: WM_GETOBJECT answers OBJID_CLIENT with the root's
#     IAccessible (AccessibleObjectFromWindow); the hosted root reports
#     no runtime id of its own and its host provider
#     (UiaHostProviderFromHwnd); bounds follow ClientToScreen; the
#     root's MSAA parent is the window's system object; republishing
#     raises the MSAA focus and selection WinEvents
#     (SetWinEventHook + AccessibleObjectFromEvent);
#   - from a second process (this executable run as "client"): wine's
#     UiaNodeFromHandle reads the hosted tree (names, control types,
#     the window-based runtime ids, screen bounds, Grid properties) and
#     oleacc's AccessibleObjectFromWindow drives the IAccessible proxy
#     (names, roles, children, selection, location, hit testing), whose
#     accDoDefaultAction and put_accValue reach the application.
import lib.lib
import lib.assert
import lib.ci_skip
import graphics.ui.accessibility_uia
import graphics.window_win32
import graphics.__arch__.access_platform

c_lib "uiautomationcore.dll"
extern int UiaNodeFromHandle(int hwnd, int* node)
extern int UiaNodeRelease(int node)
extern int UiaGetPropertyValue(int node, int property_id, char* out)
extern int UiaGetRuntimeId(int node, int* out)
extern int UiaNavigate(int node, int direction, char* condition, char* cache_request, int* requested, int* tree_structure)
extern int UiaHUiaNodeFromVariant(char* value, int* node)

c_lib "oleacc.dll"
extern int AccessibleObjectFromEvent(int hwnd, int object_id, int child_id, int* out, char* child)

c_lib "user32.dll"
extern int SendMessageW(int hwnd, int msg, int wparam, int lparam)
extern int SetWinEventHook(int event_min, int event_max, int module, int callback, int process, int thread, int flags)
extern int UnhookWinEvent(int hook)

c_lib "kernel32.dll"
extern int GetModuleFileNameA(int module, char* buffer, int size)

c_lib "oleaut32.dll"
extern int SafeArrayGetElement(int array, int32* index, char* value)
extern int SafeArrayGetUBound(int array, int dim, int32* bound)
extern int SafeArrayDestroy(int array)
extern int VariantClear(char* value)


type win_m1 = fn(int) -> int
type win_m2 = fn(int, int) -> int
type win_m3 = fn(int, int, int) -> int
type win_m4 = fn(int, int, int, int) -> int
type win_m6 = fn(int, int, int, int, int, int) -> int

const int WM_GETOBJECT = 61


int hr(int v):
	return (v << 32) >> 32


int method(int object, int slot, int nargs):
	int vtbl = load_int64(cast(char*, object))
	return win_c_function(load_int64(cast(char*, vtbl + slot * 8)), nargs, 1)


int call1(int object, int slot):
	win_m1* f = cast(win_m1*, method(object, slot, 1))
	return hr(f(object))


int call2(int object, int slot, int a):
	win_m2* f = cast(win_m2*, method(object, slot, 2))
	return hr(f(object, a))


int call3(int object, int slot, int a, int b):
	win_m3* f = cast(win_m3*, method(object, slot, 3))
	return hr(f(object, a, b))


int call4(int object, int slot, int a, int b, int c):
	win_m4* f = cast(win_m4*, method(object, slot, 4))
	return hr(f(object, a, b, c))


int call6(int object, int slot, int a, int b, int c, int d, int e):
	win_m6* f = cast(win_m6*, method(object, slot, 6))
	return hr(f(object, a, b, c, d, e))


void release(int object):
	if (object != 0): call1(object, 2)


char* iid(int slot):
	return &ui_uia_iids[slot * 16]


int query(int object, int slot):
	int out = 0
	if (call3(object, 0, cast(int, iid(slot)), cast(int, &out)) != 0): return 0
	return out


void assert_bstr_text(char* expect, int bstr):
	asserts(c"BSTR present", bstr != 0)
	int length = 0
	char* text = ui_uia_utf8(bstr, &length)
	if (strcmp(text, expect) != 0):
		print(c"expected ")
		print(expect)
		print(c" got ")
		println(text)
	asserts(c"text", strcmp(text, expect) == 0)
	free(text)
	SysFreeString(bstr)


/* IAccessible through its vtable (slots after IDispatch's 7). */

# A VT_I4 child-id VARIANT.
char* child_id(char* v, int id):
	ui_uia_variant_clear(v)
	ui_uia_variant_i4(v, id)
	return v


void acc_name(int acc, int child, char* expect):
	char[24] v
	int bstr = 0
	assert_equal(0, call3(acc, 10, cast(int, child_id(&v[0], child)), cast(int, &bstr)))
	assert_bstr_text(expect, bstr)


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


int acc_child(int acc, int child):
	char[24] v
	int out = 0
	assert_equal(0, call3(acc, 9, cast(int, child_id(&v[0], child)), cast(int, &out)))
	asserts(c"child object", out != 0)
	int a = query(out, UI_UIA_ACCESSIBLE + 1)
	release(out)
	asserts(c"child IAccessible", a != 0)
	return a


# The IAccessible of a VT_DISPATCH VARIANT (consumed).
int acc_of_variant(char* v):
	assert_equal(VT_DISPATCH, load_int16(v) & 65535)
	int a = query(load_int64(&v[8]), UI_UIA_ACCESSIBLE + 1)
	VariantClear(v)
	asserts(c"IAccessible", a != 0)
	return a


/* The client process. */

void client_text(int node, int property, char* expect):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, hr(UiaGetPropertyValue(node, property, &v[0])))
	assert_equal(VT_BSTR, load_int16(&v[0]) & 65535)
	assert_bstr_text(expect, load_int64(&v[8]))


int client_i4(int node, int property):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, hr(UiaGetPropertyValue(node, property, &v[0])))
	assert_equal(VT_I4, load_int16(&v[0]) & 65535)
	return load_int32(&v[8])


# BoundingRectangle as a VT_R8 array.
void client_bounds(int node, int x, int y, int w, int h):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, hr(UiaGetPropertyValue(node, 30001, &v[0])))
	assert_equal(VT_ARRAY | 5, load_int16(&v[0]) & 65535)
	int array = load_int64(&v[8])
	float64[4] rect
	int32[1] index
	for i in range(4):
		index[0] = i
		assert_equal(0, hr(SafeArrayGetElement(array, &index[0], cast(char*, &rect[i]))))
	print(c"bounds ")
	for i in range(4):
		print(itoa(cast(int, rect[i])))
		print(c" ")
	println(c"")
	assert_equal(x, cast(int, rect[0]))
	assert_equal(y, cast(int, rect[1]))
	assert_equal(w, cast(int, rect[2]))
	assert_equal(h, cast(int, rect[3]))
	VariantClear(&v[0])


# The runtime id's parts, as "a.b.c".
void client_runtime_id(int node, int length, int a, int b, int c):
	int runtime = 0
	assert_equal(0, hr(UiaGetRuntimeId(node, &runtime)))
	asserts(c"runtime id", runtime != 0)
	int32[1] bound
	SafeArrayGetUBound(runtime, 1, &bound[0])
	int32[1] index
	int32[3] part
	print(c"runtime id")
	for i in range(bound[0] + 1):
		index[0] = i
		int32[1] value
		SafeArrayGetElement(runtime, &index[0], cast(char*, &value[0]))
		if (i < 3): part[i] = value[0]
		print(c" ")
		print(itoa(value[0]))
	println(c"")
	assert_equal(length, bound[0] + 1)
	assert_equal(a, part[0])
	assert_equal(b, part[1])
	if (length > 2): assert_equal(c, part[2])
	SafeArrayDestroy(runtime)


# UiaNavigate from node in direction; the node it reaches.
int client_navigate(int node, int direction):
	char[8] condition
	save_int64(&condition[0], 0)                       /* ConditionType_True */
	char[48] cache
	for i in range(48): cache[i] = 0
	save_int64(&cache[0], cast(int, &condition[0]))
	save_int32(&cache[8], 1)                           /* TreeScope_Element */
	save_int32(&cache[44], 1)                          /* AutomationElementMode_Full */
	int requested = 0
	int structure = 0
	assert_equal(0, hr(UiaNavigate(node, direction, &condition[0], &cache[0], &requested, &structure)))
	asserts(c"navigate result", requested != 0)
	char* data = cast(char*, load_int64(cast(char*, requested + 16)))
	int to = 0
	assert_equal(0, hr(UiaHUiaNodeFromVariant(data, &to)))
	return to


int client(int hwnd, int ox, int oy):
	ui_uia_init()                                      /* the interface ids */
	CoInitializeEx(0, 2)

	# UI Automation: wine's client marshals every call back to the
	# application's thread.
	int root = 0
	assert_equal(0, hr(UiaNodeFromHandle(hwnd, &root)))
	asserts(c"root node", root != 0)
	client_text(root, UIA_NamePropertyId, c"Hosted")
	client_text(root, UIA_FrameworkIdPropertyId, c"W")
	assert_equal(UIA_PaneControlTypeId, client_i4(root, UIA_ControlTypePropertyId))
	client_runtime_id(root, 2, 42, hwnd, 0)
	int button = client_navigate(root, NavigateDirection_FirstChild)
	client_text(button, UIA_NamePropertyId, c"Open")
	assert_equal(UIA_ButtonControlTypeId, client_i4(button, UIA_ControlTypePropertyId))
	# [UiaAppendRuntimeId, id] under the window: [42, hwnd, 4, id], the
	# form Windows gives appended ids too.
	client_runtime_id(button, 4, 42, hwnd, 4)
	client_bounds(button, ox + 10, oy + 10, 80, 30)
	int table = client_navigate(button, NavigateDirection_NextSibling)
	assert_equal(UIA_TableControlTypeId, client_i4(table, UIA_ControlTypePropertyId))
	int header = client_navigate(table, NavigateDirection_FirstChild)
	assert_equal(UIA_HeaderControlTypeId, client_i4(header, UIA_ControlTypePropertyId))
	UiaNodeRelease(header)
	UiaNodeRelease(table)
	UiaNodeRelease(button)
	UiaNodeRelease(root)
	println(c"client: UI Automation OK")

	# MSAA: oleacc's proxy of the root IAccessible.
	int acc = 0
	assert_equal(0, hr(AccessibleObjectFromWindow(hwnd, OBJID_CLIENT, iid(UI_UIA_ACCESSIBLE + 1), &acc)))
	asserts(c"IAccessible", acc != 0)
	acc_name(acc, CHILDID_SELF, c"Hosted")
	assert_equal(ROLE_SYSTEM_CLIENT, acc_role(acc, CHILDID_SELF))
	int32[4] count
	assert_equal(0, call2(acc, 8, cast(int, &count[0])))
	assert_equal(3, count[0])
	acc_name(acc, 1, c"Open")
	assert_equal(ROLE_SYSTEM_PUSHBUTTON, acc_role(acc, 1))
	asserts(c"focused", (acc_state(acc, 1) & STATE_SYSTEM_FOCUSED) != 0)
	acc_name(acc, 0 - 7, c"a.png")
	assert_equal(ROLE_SYSTEM_CELL, acc_role(acc, 0 - 7))
	assert_equal(ROLE_SYSTEM_COLUMNHEADER, acc_role(acc, 0 - 5))
	char[24] v
	char[24] out
	int32[4] box
	assert_equal(0, call6(acc, 22, cast(int, &box[0]), cast(int, &box[1]), cast(int, &box[2]), cast(int, &box[3]), cast(int, child_id(&v[0], 1))))
	assert_equal(ox + 10, box[0])
	assert_equal(oy + 10, box[1])
	assert_equal(80, box[2])
	assert_equal(30, box[3])
	# Children as objects: the table, its selection, hit testing.
	int table_acc = acc_child(acc, 2)
	assert_equal(ROLE_SYSTEM_TABLE, acc_role(table_acc, CHILDID_SELF))
	ui_uia_variant_clear(&out[0])
	assert_equal(0, call2(table_acc, 19, cast(int, &out[0])))
	int row = acc_of_variant(&out[0])
	assert_equal(ROLE_SYSTEM_ROW, acc_role(row, CHILDID_SELF))
	asserts(c"selected row", (acc_state(row, CHILDID_SELF) & STATE_SYSTEM_SELECTED) != 0)
	acc_name(row, 1, c"a.png")
	release(row)
	release(table_acc)
	ui_uia_variant_clear(&out[0])
	assert_equal(0, call4(acc, 24, ox + 15, oy + 15, cast(int, &out[0])))
	int hit = acc_of_variant(&out[0])
	acc_name(hit, CHILDID_SELF, c"Open")
	release(hit)
	# Actions reach the application (checked by the server).
	assert_equal(0, call2(acc, 25, cast(int, child_id(&v[0], 1))))
	char[16] wide
	save_int16(&wide[0], 'o')
	save_int16(&wide[2], 'k')
	save_int16(&wide[4], 0)
	int typed = SysAllocStringLen(&wide[0], 2)
	assert_equal(0, call3(acc, 27, cast(int, child_id(&v[0], 0 - 10)), typed))
	SysFreeString(typed)
	release(acc)
	println(c"client: MSAA OK")
	return 0


/* The application (server) process. */

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


ui_access_tree* build(int selected_row, int focused):
	ui_access_tree* tree = ui_access_tree_new(32, 512)
	tree.action = record_action
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, ui_rect_new(0.0, 0.0, 300.0, 200.0))
	ui_access_set_text(tree, 1, UI_ACCESS_NAME, c"Hosted", 6)
	ui_access_node* button = ui_access_add(tree, 2, 1, UI_ACCESS_BUTTON, ui_rect_new(10.0, 10.0, 80.0, 30.0))
	button.states = UI_ACCESS_FOCUSABLE
	button.actions = UI_ACCESS_ACTIVATE | UI_ACCESS_FOCUS
	ui_access_set_text(tree, 2, UI_ACCESS_NAME, c"Open", 4)
	ui_access_add(tree, 3, 1, UI_ACCESS_TABLE, ui_rect_new(10.0, 50.0, 200.0, 60.0))
	ui_access_add(tree, 4, 3, UI_ACCESS_ROW, ui_rect_new(10.0, 50.0, 200.0, 20.0))
	ui_access_add(tree, 5, 4, UI_ACCESS_CELL, ui_rect_new(10.0, 50.0, 200.0, 20.0))
	ui_access_set_text(tree, 5, UI_ACCESS_NAME, c"Name", 4)
	ui_access_node* first = ui_access_add(tree, 6, 3, UI_ACCESS_ROW, ui_rect_new(10.0, 70.0, 200.0, 20.0))
	first.actions = UI_ACCESS_ACTIVATE
	ui_access_add(tree, 7, 6, UI_ACCESS_CELL, ui_rect_new(10.0, 70.0, 200.0, 20.0))
	ui_access_set_text(tree, 7, UI_ACCESS_NAME, c"a.png", 5)
	ui_access_node* second = ui_access_add(tree, 8, 3, UI_ACCESS_ROW, ui_rect_new(10.0, 90.0, 200.0, 20.0))
	second.actions = UI_ACCESS_ACTIVATE
	ui_access_add(tree, 9, 8, UI_ACCESS_CELL, ui_rect_new(10.0, 90.0, 200.0, 20.0))
	ui_access_set_text(tree, 9, UI_ACCESS_NAME, c"b.png", 5)
	if (selected_row == 6): first.states = UI_ACCESS_SELECTED
	else: second.states = UI_ACCESS_SELECTED
	ui_access_node* field = ui_access_add(tree, 10, 1, UI_ACCESS_TEXTBOX, ui_rect_new(10.0, 120.0, 150.0, 24.0))
	field.states = UI_ACCESS_FOCUSABLE
	field.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_FOCUS
	ui_access_set_text(tree, 10, UI_ACCESS_NAME, c"Search", 6)
	tree.focused_id = focused
	return tree


int[8] events
int[8] event_children
int event_count
int event_hwnd


# WINEVENTPROC(hook, event, hwnd, object_id, child_id, thread, time)
void on_win_event(int hook, int event, int hwnd, int object_id, int child, int thread, int time):
	if ((event_count < 8) && (ui_uia_lo32(object_id) == OBJID_CLIENT)):
		events[event_count] = event & 65535
		event_children[event_count] = ui_uia_lo32(child)
		event_hwnd = hwnd
		event_count = event_count + 1


void pump(ui_uia_bridge* bridge, ui_access_tree* tree):
	char[64] msg
	while (PeekMessageW(&msg[0], 0, 0, 0, 1) & 255): DispatchMessageW(&msg[0])
	ui_access_platform_dispatch(cast(int, bridge), tree)


int event_index(int event):
	for i in range(event_count):
		if (events[i] == event): return i
	return 0 - 1


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if ((argc > 4) && (strcmp(args[1], c"client") == 0)): return client(atoi(args[2]), atoi(args[3]), atoi(args[4]))

	# A plain window (no GL context) whose procedure is graphics.
	# window_win32's, so its WM_GETOBJECT hook is the one under test.
	gfx_window* win = new gfx_window()
	gfx_win32_active = win
	int instance = GetModuleHandleA(cast(char*, 0))
	assert_equal(1, gfx_win32_register_class(instance))
	int hwnd = CreateWindowExW(0, gfx_win32_class_name, gfx_win32_class_name, 282001408, 100, 50, 320, 240, 0, 0, instance, 0)
	if (hwnd == 0):
		test_skip(c"SKIP graphics_ui_accessibility_uia_window_test: wine created no window (no X display; run under xvfb-run -a)")
		return 0
	win.hwnd = hwnd
	win.width = 320
	win.height = 240

	int handle = ui_access_platform_open(win, c"Hosted")
	asserts(c"bridge", handle != 0)
	ui_uia_bridge* bridge = cast(ui_uia_bridge*, handle)
	asserts(c"hook installed", gfx_win32_getobject != 0)
	ui_access_tree* app = build(6, 2)
	assert_equal(1, ui_access_platform_publish(handle, app))

	# Screen origin of the client area.
	int32[2] point
	point[0] = 0
	point[1] = 0
	ClientToScreen(hwnd, &point[0])
	int ox = point[0]
	int oy = point[1]
	print(c"client origin ")
	print(itoa(ox))
	print(c" ")
	println(itoa(oy))
	asserts(c"origin", (ox >= 100) && (oy >= 50))

	# --- in process ---
	int root = ui_access_uia_root(bridge)
	int fragment = query(root, UI_UIA_FRAGMENT + 1)
	int runtime = 1
	assert_equal(0, call2(fragment, 4, cast(int, &runtime)))
	assert_equal(0, runtime)                           /* the window's id is used */
	float64[4] rect
	assert_equal(0, call2(fragment, 5, cast(int, &rect[0])))
	assert_equal(ox, cast(int, rect[0]))
	assert_equal(oy, cast(int, rect[1]))
	release(fragment)
	int host = 0
	assert_equal(0, call2(root, 6, cast(int, &host)))
	asserts(c"host provider", host != 0)
	release(host)

	# WM_GETOBJECT through the window procedure: OBJID_CLIENT gets an
	# LRESULT for the IAccessible, OBJID_WINDOW is left to the system.
	asserts(c"OBJID_CLIENT answered", SendMessageW(hwnd, WM_GETOBJECT, 0, OBJID_CLIENT) > 0)
	int acc = 0
	assert_equal(0, hr(AccessibleObjectFromWindow(hwnd, OBJID_CLIENT, iid(UI_UIA_ACCESSIBLE + 1), &acc)))
	acc_name(acc, CHILDID_SELF, c"Hosted")
	int parent = 0
	assert_equal(0, call2(acc, 7, cast(int, &parent)))
	asserts(c"window object", parent != 0)
	# (wine's window object answers E_NOTIMPL for get_accRole, so only
	# its identity as an IAccessible is checked.)
	int window_acc = query(parent, UI_UIA_ACCESSIBLE + 1)
	asserts(c"window IAccessible", window_acc != 0)
	release(window_acc)
	release(parent)
	int32[4] box
	char[24] v
	assert_equal(0, call6(acc, 22, cast(int, &box[0]), cast(int, &box[1]), cast(int, &box[2]), cast(int, &box[3]), cast(int, child_id(&v[0], 0 - 9))))
	assert_equal(ox + 10, box[0])
	assert_equal(oy + 90, box[1])
	release(acc)

	# --- another process ---
	char[512] path
	GetModuleFileNameA(0, &path[0], 400)
	char* command = cast(char*, malloc(600))
	strcpy(command, c"\"")
	strappend(command, &path[0])
	strappend(command, c"\" client ")
	strappend(command, itoa(hwnd))
	strappend(command, c" ")
	strappend(command, itoa(ox))
	strappend(command, c" ")
	strappend(command, itoa(oy))
	char[104] startup
	for i in range(104): startup[i] = 0
	save_int32(&startup[0], 104)
	char[24] info
	asserts(c"client started", (CreateProcessA(0, command, 0, 0, 1, 0, 0, 0, &startup[0], &info[0]) & 255) != 0)
	int process = load_int64(&info[0])
	int code = 259                                     /* STILL_ACTIVE */
	int tries = 0
	while ((code == 259) && (tries < 1500)):
		pump(bridge, app)
		GetExitCodeProcess(process, &code)
		if (code == 259): Sleep(20)
		tries = tries + 1
	if (code == 259): TerminateProcess(process, 1)
	assert_equal(0, code)
	pump(bridge, app)
	# accDoDefaultAction on the button, put_accValue on the textbox.
	assert_equal(2, action_count)
	assert_equal(UI_ACCESS_ACTIVATE, actions_seen[0])
	assert_equal(2, action_ids[0])
	assert_equal(UI_ACCESS_SET_VALUE, actions_seen[1])
	assert_equal(10, action_ids[1])
	assert_equal(2, last_length)
	assert_equal('o', last_value[0])
	assert_equal('k', last_value[1])

	# --- MSAA WinEvents of a republication ---
	int hook = SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_SELECTION, 0, win_callback(cast(int, on_win_event), 7), 0, 0, 0)
	asserts(c"win event hook", hook != 0)
	ui_access_tree* next = build(8, 10)
	assert_equal(1, ui_access_platform_publish(handle, next))
	tries = 0
	while ((event_count < 2) && (tries < 100)):
		pump(bridge, next)
		if (event_count < 2): Sleep(20)
		tries = tries + 1
	UnhookWinEvent(hook)
	int focus = event_index(EVENT_OBJECT_FOCUS)
	int selection = event_index(EVENT_OBJECT_SELECTION)
	asserts(c"focus event", focus >= 0)
	asserts(c"selection event", selection >= 0)
	assert_equal(0 - 10, event_children[focus])
	assert_equal(0 - 8, event_children[selection])
	assert_equal(hwnd, event_hwnd)
	# What a client does with the event: resolve the child id.
	int from_event = 0
	char[24] child
	ui_uia_variant_clear(&child[0])
	assert_equal(0, hr(AccessibleObjectFromEvent(hwnd, OBJID_CLIENT, 0 - 10, &from_event, &child[0])))
	asserts(c"object from event", from_event != 0)
	acc_name(from_event, load_int32(&child[8]), c"Search")
	release(from_event)

	ui_access_platform_close(handle)
	assert_equal(0, cast(int, gfx_win32_getobject))
	DestroyWindow(hwnd)
	ui_access_tree_free(app)
	ui_access_tree_free(next)
	println(c"UI Automation / MSAA window bridge OK")
	return 0
