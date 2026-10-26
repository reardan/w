/*
graphics.ui.accessibility_uia: publishes semantic snapshots
(graphics.ui.accessibility) to Windows UI Automation, the API Narrator,
NVDA and JAWS read, as server-side UIA providers written in W. win64
only; no C helper, no ATL.

	ui_uia_bridge* bridge = ui_access_uia_open(win.hwnd)
	gfx_win32_getobject = ui_access_uia_wm_getobject   # graphics.window_win32
	... each frame, after ui_end (see docs/projects/accessibility.md):
	ui_access_uia_dispatch(bridge, published)   # apply queued actions
	if (snapshot changed): ui_access_uia_publish(bridge, fresh)
	...
	ui_access_uia_close(bridge)

Every snapshot node becomes a COM object (one per node id, reused
across publications while the id exists) implementing IUnknown,
IRawElementProviderSimple and IRawElementProviderFragment; the snapshot
root also implements IRawElementProviderFragmentRoot and is hosted by
the window (UiaHostProviderFromHwnd), which hands it out from
WM_GETOBJECT through UiaReturnRawElementProvider. Control patterns by
role: Invoke (buttons, links and other activatable nodes), Toggle
(checkboxes, switches), Value (textboxes; read-only on comboboxes),
SelectionItem (tabs, list items, data rows, radio buttons), Selection
(lists, tab lists, tables), Grid and Table (tables), GridItem and
TableItem (data cells), ExpandCollapse (comboboxes and expanded nodes)
and RangeValue (progress, read-only). Table structure (the column-header
row, data rows and cells) and selection come from
graphics.ui.accessibility_table, which the AT-SPI bridge shares.

The same objects implement MSAA's IAccessible (IDispatch-derived, its
IDispatch methods unimplemented) for legacy clients: WM_GETOBJECT for
OBJID_CLIENT answers the root's through LresultFromObject. Children are
reachable as child ids (1..n under an object, or -id for any node, the
form the WinEvents NotifyWinEvent raises for a hosted tree use) and as
their own IAccessible objects.

Each interface is a two-word object {vtable, element}: the vtables are
arrays of win_callback thunks (lib/__arch__/win64/syscalls.w) into the
W functions below, so the Microsoft x64 ABI arrives as plain W
arguments. ElementProviderFromPoint takes its doubles in xmm1/xmm2, so
its thunk is preceded by a stub moving them into rdx/r8.

Publication copies the snapshot; queries are answered from that copy.
Actions (Invoke, Toggle, SetValue, Select, Expand/Collapse, SetFocus)
are queued (64 at most, values within the snapshot's text budget) and
applied by ui_access_uia_dispatch through ui_access_dispatch, which
revalidates them against the application's tree, as the Cocoa, web and
AT-SPI bridges do. A provider a client keeps after its node disappears
answers UIA_E_ELEMENTNOTAVAILABLE and is disconnected
(UiaDisconnectProvider).

Providers report ProviderOptions_ServerSideProvider |
UseComThreading, so UI Automation calls them on the thread that opened
the bridge (a COM single-threaded apartment, initialised by
ui_access_uia_open) while that thread pumps messages
(gfx_window_poll). Constants and interface ids are from the Windows SDK
headers UIAutomationCore.h / UIAutomationClient.h /
UIAutomationCoreApi.h.
*/
import lib.lib
import lib.utf8
import graphics.ui.accessibility
import graphics.ui.accessibility_table


c_lib "uiautomationcore.dll"
extern int UiaReturnRawElementProvider(int hwnd, int wparam, int lparam, int provider)
extern int UiaHostProviderFromHwnd(int hwnd, int* provider)
extern int UiaRaiseAutomationEvent(int provider, int event_id)
# The two VARIANTs are passed by value, which the x64 ABI turns into
# pointers to caller-owned copies.
extern int UiaRaiseAutomationPropertyChangedEvent(int provider, int property_id, char* old_value, char* new_value)
extern int UiaRaiseStructureChangedEvent(int provider, int change, int32* runtime_id, int length)
extern int UiaClientsAreListening()
extern int UiaDisconnectProvider(int provider)

c_lib "oleaut32.dll"
extern int SysAllocStringLen(char* text, int length)
extern void SysFreeString(int bstr)
extern int SafeArrayCreateVector(int vt, int lower_bound, int count)
extern int SafeArrayPutElement(int array, int32* index, char* value)

c_lib "ole32.dll"
extern int CoInitializeEx(int reserved, int flags)

c_lib "user32.dll"
extern int ClientToScreen(int hwnd, int32* point)
extern void NotifyWinEvent(int event, int hwnd, int object_id, int child_id)

c_lib "oleacc.dll"
extern int LresultFromObject(char* riid, int wparam, int object)
extern int AccessibleObjectFromWindow(int hwnd, int object_id, char* riid, int* out)


const int ui_uia_max_requests = 64

# HRESULTs (winerror.h, UIAutomationCoreApi.h). Only the low 32 bits
# reach the caller (eax).
const int UIA_S_OK = 0
const int UIA_E_NOTIMPL = 0x80004001
const int UIA_E_NOINTERFACE = 0x80004002
const int UIA_E_POINTER = 0x80004003
const int UIA_E_INVALIDARG = 0x80070057
const int UIA_E_ELEMENTNOTENABLED = 0x80040200
const int UIA_E_ELEMENTNOTAVAILABLE = 0x80040201
const int UIA_E_INVALIDOPERATION = 0x80131509
const int UIA_S_FALSE = 1
const int UIA_E_FAIL = 0x80004005

# Interfaces, in the order of each element's iface table.
const int UI_UIA_SIMPLE = 0
const int UI_UIA_FRAGMENT = 1
const int UI_UIA_ROOT = 2
const int UI_UIA_INVOKE = 3
const int UI_UIA_TOGGLE = 4
const int UI_UIA_VALUE = 5
const int UI_UIA_SELECTION_ITEM = 6
const int UI_UIA_EXPAND = 7
const int UI_UIA_RANGE = 8
const int UI_UIA_SELECTION = 9
const int UI_UIA_GRID = 10
const int UI_UIA_GRID_ITEM = 11
const int UI_UIA_TABLE = 12
const int UI_UIA_TABLE_ITEM = 13
const int UI_UIA_ACCESSIBLE = 14
const int UI_UIA_IFACES = 15
# ui_uia_iids slot of IDispatch (IAccessible's base), after IUnknown and
# the interface kinds (slot kind + 1).
const int UI_UIA_IDISPATCH_SLOT = 16

# Control pattern ids (UIA_*PatternId).
const int UIA_InvokePatternId = 10000
const int UIA_SelectionPatternId = 10001
const int UIA_ValuePatternId = 10002
const int UIA_RangeValuePatternId = 10003
const int UIA_ExpandCollapsePatternId = 10005
const int UIA_GridPatternId = 10006
const int UIA_GridItemPatternId = 10007
const int UIA_SelectionItemPatternId = 10010
const int UIA_TablePatternId = 10012
const int UIA_TableItemPatternId = 10013
const int UIA_TogglePatternId = 10015

# Property ids (UIA_*PropertyId).
const int UIA_RuntimeIdPropertyId = 30000
const int UIA_ControlTypePropertyId = 30003
const int UIA_LocalizedControlTypePropertyId = 30004
const int UIA_NamePropertyId = 30005
const int UIA_HasKeyboardFocusPropertyId = 30008
const int UIA_IsKeyboardFocusablePropertyId = 30009
const int UIA_IsEnabledPropertyId = 30010
const int UIA_AutomationIdPropertyId = 30011
const int UIA_HelpTextPropertyId = 30013
const int UIA_IsControlElementPropertyId = 30016
const int UIA_IsContentElementPropertyId = 30017
const int UIA_IsOffscreenPropertyId = 30022
const int UIA_FrameworkIdPropertyId = 30024
const int UIA_ValueValuePropertyId = 30045
const int UIA_SelectionSelectionPropertyId = 30059
const int UIA_SelectionCanSelectMultiplePropertyId = 30060
const int UIA_SelectionIsSelectionRequiredPropertyId = 30061
const int UIA_GridRowCountPropertyId = 30062
const int UIA_GridColumnCountPropertyId = 30063
const int UIA_GridItemRowPropertyId = 30064
const int UIA_GridItemColumnPropertyId = 30065
const int UIA_GridItemRowSpanPropertyId = 30066
const int UIA_GridItemColumnSpanPropertyId = 30067
const int UIA_GridItemContainingGridPropertyId = 30068
const int UIA_ExpandCollapseExpandCollapseStatePropertyId = 30070
const int UIA_SelectionItemIsSelectedPropertyId = 30079
const int UIA_SelectionItemSelectionContainerPropertyId = 30080
const int UIA_TableRowOrColumnMajorPropertyId = 30083
const int UIA_ToggleToggleStatePropertyId = 30086
const int UIA_FullDescriptionPropertyId = 30159
const int UIA_HeadingLevelPropertyId = 30173
const int UIA_IsDialogPropertyId = 30174
const int HeadingLevel_None = 80050

# Event ids (UIA_*EventId) and StructureChangeType.
const int UIA_StructureChangedEventId = 20002
const int UIA_AutomationFocusChangedEventId = 20005
const int UIA_SelectionItem_ElementSelectedEventId = 20012
const int StructureChangeType_ChildrenInvalidated = 2

# Control type ids (UIA_*ControlTypeId).
const int UIA_ButtonControlTypeId = 50000
const int UIA_CheckBoxControlTypeId = 50002
const int UIA_ComboBoxControlTypeId = 50003
const int UIA_EditControlTypeId = 50004
const int UIA_HyperlinkControlTypeId = 50005
const int UIA_ImageControlTypeId = 50006
const int UIA_ListItemControlTypeId = 50007
const int UIA_ListControlTypeId = 50008
const int UIA_ProgressBarControlTypeId = 50012
const int UIA_RadioButtonControlTypeId = 50013
const int UIA_TabControlTypeId = 50018
const int UIA_TabItemControlTypeId = 50019
const int UIA_TextControlTypeId = 50020
const int UIA_GroupControlTypeId = 50026
const int UIA_DataItemControlTypeId = 50029
const int UIA_DocumentControlTypeId = 50030
const int UIA_WindowControlTypeId = 50032
const int UIA_PaneControlTypeId = 50033
const int UIA_HeaderControlTypeId = 50034
const int UIA_HeaderItemControlTypeId = 50035
const int UIA_TableControlTypeId = 50036

# NavigateDirection, ProviderOptions, ToggleState, ExpandCollapseState.
const int NavigateDirection_Parent = 0
const int NavigateDirection_NextSibling = 1
const int NavigateDirection_PreviousSibling = 2
const int NavigateDirection_FirstChild = 3
const int NavigateDirection_LastChild = 4
const int ProviderOptions_ServerSideProvider = 1
const int ProviderOptions_UseComThreading = 32
const int UiaAppendRuntimeId = 3
const int UiaRootObjectId = 0 - 25

# VARIANT types (wtypes.h).
const int VT_EMPTY = 0
const int VT_I4 = 3
const int VT_BSTR = 8
const int VT_DISPATCH = 9
const int VT_BOOL = 11
const int VT_UNKNOWN = 13
const int VT_ARRAY = 8192

# MSAA (oleacc.h, winuser.h): object and child ids, roles, states,
# navigation and selection flags, WinEvents.
const int OBJID_WINDOW = 0
const int OBJID_CLIENT = 0 - 4
const int CHILDID_SELF = 0
const int ROLE_SYSTEM_CLIENT = 10
const int ROLE_SYSTEM_DOCUMENT = 15
const int ROLE_SYSTEM_DIALOG = 18
const int ROLE_SYSTEM_GROUPING = 20
const int ROLE_SYSTEM_TABLE = 24
const int ROLE_SYSTEM_COLUMNHEADER = 25
const int ROLE_SYSTEM_ROW = 28
const int ROLE_SYSTEM_CELL = 29
const int ROLE_SYSTEM_LINK = 30
const int ROLE_SYSTEM_LIST = 33
const int ROLE_SYSTEM_LISTITEM = 34
const int ROLE_SYSTEM_PAGETAB = 37
const int ROLE_SYSTEM_GRAPHIC = 40
const int ROLE_SYSTEM_STATICTEXT = 41
const int ROLE_SYSTEM_TEXT = 42
const int ROLE_SYSTEM_PUSHBUTTON = 43
const int ROLE_SYSTEM_CHECKBUTTON = 44
const int ROLE_SYSTEM_RADIOBUTTON = 45
const int ROLE_SYSTEM_COMBOBOX = 46
const int ROLE_SYSTEM_PROGRESSBAR = 48
const int ROLE_SYSTEM_PAGETABLIST = 60
const int STATE_SYSTEM_UNAVAILABLE = 0x1
const int STATE_SYSTEM_SELECTED = 0x2
const int STATE_SYSTEM_FOCUSED = 0x4
const int STATE_SYSTEM_CHECKED = 0x10
const int STATE_SYSTEM_READONLY = 0x40
const int STATE_SYSTEM_EXPANDED = 0x200
const int STATE_SYSTEM_COLLAPSED = 0x400
const int STATE_SYSTEM_INVISIBLE = 0x8000
const int STATE_SYSTEM_OFFSCREEN = 0x10000
const int STATE_SYSTEM_FOCUSABLE = 0x100000
const int STATE_SYSTEM_SELECTABLE = 0x200000
const int STATE_SYSTEM_LINKED = 0x400000
const int STATE_SYSTEM_HASPOPUP = 0x40000000
const int NAVDIR_UP = 1
const int NAVDIR_NEXT = 5
const int NAVDIR_PREVIOUS = 6
const int NAVDIR_FIRSTCHILD = 7
const int NAVDIR_LASTCHILD = 8
const int SELFLAG_TAKEFOCUS = 1
const int SELFLAG_TAKESELECTION = 2
const int SELFLAG_EXTENDSELECTION = 4
const int SELFLAG_ADDSELECTION = 8
const int SELFLAG_REMOVESELECTION = 16
const int DISP_E_MEMBERNOTFOUND = 0x80020003
const int EVENT_OBJECT_REORDER = 0x8004
const int EVENT_OBJECT_FOCUS = 0x8005
const int EVENT_OBJECT_SELECTION = 0x8006
const int EVENT_OBJECT_STATECHANGE = 0x800A
const int EVENT_OBJECT_NAMECHANGE = 0x800C
const int EVENT_OBJECT_VALUECHANGE = 0x800E


struct ui_uia_iface:
	int vtbl
	int element                 # the ui_uia_element this interface belongs to


struct ui_uia_element:
	ui_uia_iface[15] ifaces
	int refs                    # COM references held by clients
	int id
	int dead                    # the node is gone (or the bridge closed)
	int bridge                  # ui_uia_bridge*, valid while !dead


struct ui_uia_request:
	int id
	int action
	char* value
	int length


struct ui_uia_bridge:
	int hwnd                    # host window, 0 for an unhosted tree
	ui_access_tree* published   # owned copy of the last publication
	map[int, ui_uia_element*] elements
	int options                 # ProviderOptions reported to UIA
	int origin_x                # screen position of the tree's (0, 0)
	int origin_y                # when there is no hwnd
	ui_uia_request[64] queue
	int queued


/* Plumbing: vtables, GUIDs, strings, VARIANTs. */

int[15] ui_uia_vtables
char[272] ui_uia_iids           # IUnknown, one IID per interface kind, IDispatch
int ui_uia_ready
ui_uia_bridge* ui_uia_active    # the bridge ui_access_uia_wm_getobject serves


# The low 32 bits of a register argument, sign-extended (UINT/LONG/
# HRESULT arrive with undefined upper halves).
int ui_uia_lo32(int v):
	return (v << 32) >> 32


void ui_uia_guid(int slot, int d1, int d2, int d3, int b0, int b1, int b2, int b3, int b4, int b5, int b6, int b7):
	char* g = &ui_uia_iids[slot * 16]
	save_int32(g, d1)
	g[4] = d2 & 255
	g[5] = (d2 >> 8) & 255
	g[6] = d3 & 255
	g[7] = (d3 >> 8) & 255
	g[8] = b0
	g[9] = b1
	g[10] = b2
	g[11] = b3
	g[12] = b4
	g[13] = b5
	g[14] = b6
	g[15] = b7


int ui_uia_guid_is(int riid, int slot):
	char* a = cast(char*, riid)
	char* g = &ui_uia_iids[slot * 16]
	for i in range(16):
		if (a[i] != g[i]): return 0
	return 1


ui_uia_element* ui_uia_self(int self):
	ui_uia_iface* me = cast(ui_uia_iface*, self)
	return cast(ui_uia_element*, me.element)


int ui_uia_iface_ptr(ui_uia_element* e, int kind):
	return cast(int, &e.ifaces[kind])


# A BSTR holding UTF-8 data[0..length) as UTF-16 (invalid bytes become
# U+FFFD). The caller (UIA) frees it.
int ui_uia_bstr(char* data, int length):
	char* units = cast(char*, malloc(length * 4 + 2))
	int n = 0
	int i = 0
	while (i < length):
		int cp = 0
		int used = utf8_scan(&data[i], length - i, &cp)
		if (used <= 0):
			cp = 65533
			used = 1
		if (cp >= 65536):
			int v = cp - 65536
			save_int16(&units[n * 2], 55296 + (v >> 10))
			save_int16(&units[n * 2 + 2], 56320 + (v & 1023))
			n = n + 2
		else:
			save_int16(&units[n * 2], cp)
			n = n + 1
		i = i + used
	int b = SysAllocStringLen(units, n)
	free(units)
	return b


# UTF-8 copy of a NUL-terminated UTF-16 string (lone surrogates become
# U+FFFD); *length receives its byte count.
char* ui_uia_utf8(int wide, int* length):
	char* w = cast(char*, wide)
	int count = 0
	while ((load_int16(&w[count * 2]) & 65535) != 0): count = count + 1
	char* out = cast(char*, malloc(count * 3 + 1))
	int n = 0
	int i = 0
	while (i < count):
		int u = load_int16(&w[i * 2]) & 65535
		int cp = u
		if ((u >= 55296) && (u < 56320) && (i + 1 < count)):
			int low = load_int16(&w[i * 2 + 2]) & 65535
			if ((low >= 56320) && (low < 57344)):
				cp = 65536 + ((u - 55296) << 10) + (low - 56320)
				i = i + 1
			else: cp = 65533
		else if ((u >= 55296) && (u < 57344)): cp = 65533
		n = n + utf8_encode(&out[n], cp)
		i = i + 1
	out[n] = 0
	length[0] = n
	return out


void ui_uia_variant_clear(char* v):
	for i in range(24): v[i] = 0


void ui_uia_variant_i4(char* v, int x):
	save_int16(v, VT_I4)
	save_int32(&v[8], x)


void ui_uia_variant_bool(char* v, int x):
	save_int16(v, VT_BOOL)
	if x: save_int16(&v[8], 0 - 1)
	else: save_int16(&v[8], 0)


void ui_uia_variant_text(char* v, ui_access_text* t):
	save_int16(v, VT_BSTR)
	save_int64(&v[8], ui_uia_bstr(t.data, t.length))


void ui_uia_variant_string(char* v, char* s):
	save_int16(v, VT_BSTR)
	save_int64(&v[8], ui_uia_bstr(s, strlen(s)))


void ui_uia_put_double(int out, float64 x):
	float64* p = cast(float64*, out)
	p[0] = x


float64 ui_uia_double_from_bits(int bits):
	char[8] raw
	save_int64(&raw[0], bits)
	float64* p = cast(float64*, &raw[0])
	return p[0]


/* Nodes behind elements. */

ui_uia_bridge* ui_uia_bridge_of(ui_uia_element* e):
	return cast(ui_uia_bridge*, e.bridge)


# The element's current node, or 0 when it is gone.
ui_access_node* ui_uia_node(ui_uia_element* e):
	if (e.dead): return 0
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	if (b.published == 0): return 0
	return ui_access_find(b.published, e.id)


int ui_uia_is_root(ui_uia_bridge* b, ui_access_node* n):
	return (b.published != 0) && (b.published.root == n)


int ui_uia_hidden(ui_access_node* n):
	ui_access_node* p = n
	while (p != 0):
		if ((p.states & UI_ACCESS_HIDDEN) != 0): return 1
		p = p.parent
	return 0


int ui_uia_control_type(ui_uia_bridge* b, ui_access_node* n):
	int r = n.role
	if (r == UI_ACCESS_DOCUMENT):
		if (ui_uia_is_root(b, n)): return UIA_PaneControlTypeId
		return UIA_DocumentControlTypeId
	if (r == UI_ACCESS_GROUP): return UIA_GroupControlTypeId
	if ((r == UI_ACCESS_CELL) && ui_access_is_header_cell(n)): return UIA_HeaderItemControlTypeId
	if ((r == UI_ACCESS_TEXT) || (r == UI_ACCESS_HEADING) || (r == UI_ACCESS_CELL)): return UIA_TextControlTypeId
	if (r == UI_ACCESS_LINK): return UIA_HyperlinkControlTypeId
	# A switch is a button with the Toggle pattern (the UIA guidance for
	# toggle switches); its localized type says "toggle switch".
	if ((r == UI_ACCESS_BUTTON) || (r == UI_ACCESS_SWITCH)): return UIA_ButtonControlTypeId
	if (r == UI_ACCESS_CHECKBOX): return UIA_CheckBoxControlTypeId
	if (r == UI_ACCESS_TEXTBOX): return UIA_EditControlTypeId
	if (r == UI_ACCESS_IMAGE): return UIA_ImageControlTypeId
	if (r == UI_ACCESS_LIST): return UIA_ListControlTypeId
	if (r == UI_ACCESS_LIST_ITEM): return UIA_ListItemControlTypeId
	if (r == UI_ACCESS_TABLE): return UIA_TableControlTypeId
	# The column-header row is a Header of HeaderItems.
	if (r == UI_ACCESS_ROW):
		if (ui_access_is_header_row(n)): return UIA_HeaderControlTypeId
		return UIA_DataItemControlTypeId
	if (r == UI_ACCESS_RADIO): return UIA_RadioButtonControlTypeId
	if (r == UI_ACCESS_COMBOBOX): return UIA_ComboBoxControlTypeId
	if (r == UI_ACCESS_TAB_LIST): return UIA_TabControlTypeId
	if (r == UI_ACCESS_TAB): return UIA_TabItemControlTypeId
	if (r == UI_ACCESS_PROGRESS): return UIA_ProgressBarControlTypeId
	# Dialogs are windows with IsDialog set.
	if (r == UI_ACCESS_DIALOG): return UIA_WindowControlTypeId
	return UIA_GroupControlTypeId


# 1 when the node's element offers interface kind.
int ui_uia_supports(ui_uia_bridge* b, ui_access_node* n, int kind):
	int r = n.role
	if ((kind == UI_UIA_SIMPLE) || (kind == UI_UIA_FRAGMENT)): return 1
	if (kind == UI_UIA_ROOT): return ui_uia_is_root(b, n)
	if (kind == UI_UIA_TOGGLE): return (r == UI_ACCESS_CHECKBOX) || (r == UI_ACCESS_SWITCH)
	if (kind == UI_UIA_VALUE): return (r == UI_ACCESS_TEXTBOX) || (r == UI_ACCESS_COMBOBOX)
	if (kind == UI_UIA_SELECTION_ITEM):
		if (r == UI_ACCESS_ROW): return !ui_access_is_header_row(n)
		return (r == UI_ACCESS_TAB) || (r == UI_ACCESS_LIST_ITEM) || (r == UI_ACCESS_RADIO)
	if (kind == UI_UIA_SELECTION): return ui_access_is_selection_container(n)
	if ((kind == UI_UIA_GRID) || (kind == UI_UIA_TABLE)): return r == UI_ACCESS_TABLE
	if ((kind == UI_UIA_GRID_ITEM) || (kind == UI_UIA_TABLE_ITEM)):
		int row = 0
		int col = 0
		return ui_access_cell_position(n, &row, &col)
	if (kind == UI_UIA_ACCESSIBLE): return 1
	if (kind == UI_UIA_EXPAND):
		if (r == UI_ACCESS_COMBOBOX): return 1
		return ((n.states & UI_ACCESS_EXPANDED) != 0) && ((n.actions & UI_ACCESS_ACTIVATE) != 0)
	if (kind == UI_UIA_RANGE): return r == UI_ACCESS_PROGRESS
	if (kind == UI_UIA_INVOKE):
		if ((n.actions & UI_ACCESS_ACTIVATE) == 0): return 0
		for k in range(UI_UIA_TOGGLE, UI_UIA_RANGE):
			if (ui_uia_supports(b, n, k)): return 0
		return 1
	return 0


ui_uia_element* ui_uia_element_for(ui_uia_bridge* b, int id):
	if (id in b.elements): return b.elements[id]
	ui_uia_element* e = new ui_uia_element()
	for k in range(UI_UIA_IFACES):
		e.ifaces[k].vtbl = ui_uia_vtables[k]
		e.ifaces[k].element = cast(int, e)
	e.refs = 0
	e.id = id
	e.dead = 0
	e.bridge = cast(int, b)
	b.elements[id] = e
	return e


# Hand out interface kind of node id through out (AddRef'd), or null.
int ui_uia_hand_out(ui_uia_bridge* b, int id, int kind, int out):
	if (out == 0): return UIA_E_POINTER
	if (id == 0):
		save_int64(cast(char*, out), 0)
		return UIA_S_OK
	ui_uia_element* e = ui_uia_element_for(b, id)
	e.refs = e.refs + 1
	save_int64(cast(char*, out), ui_uia_iface_ptr(e, kind))
	return UIA_S_OK


int ui_uia_simple_of(ui_uia_bridge* b, int id):
	return ui_uia_iface_ptr(ui_uia_element_for(b, id), UI_UIA_SIMPLE)


# A SAFEARRAY of VT_UNKNOWN holding the Simple providers of nodes ids
# (SafeArrayPutElement AddRefs each), as element-array answers are.
int ui_uia_element_array(ui_uia_bridge* b, list[int] ids):
	int array = SafeArrayCreateVector(VT_UNKNOWN, 0, ids.length)
	if (array == 0): return 0
	int32[1] index
	for i in range(ids.length):
		index[0] = i
		SafeArrayPutElement(array, &index[0], cast(char*, ui_uia_simple_of(b, ids[i])))
	return array


# The selected children of a selection container, in child order.
list[int] ui_uia_selection_ids(ui_access_node* n):
	list[int] ids = new list[int]
	for i in range(ui_access_selected_count(n)): ids.push(ui_access_selected_at(n, i).id)
	return ids


# A table's column headers: the cells of its header row.
list[int] ui_uia_column_header_ids(ui_access_node* table):
	list[int] ids = new list[int]
	ui_access_node* header = ui_access_header_row(table)
	if (header == 0): return ids
	ui_access_node* c = header.first_child
	while (c != 0):
		if (c.role == UI_ACCESS_CELL): ids.push(c.id)
		c = c.next_sibling
	return ids


# The selection container of a selectable node: its parent, when that
# offers the Selection pattern.
ui_access_node* ui_uia_container_of(ui_access_node* n):
	if ((n.parent != 0) && ui_access_is_selection_container(n.parent)): return n.parent
	return 0


/* Action queue. */

int ui_uia_enqueue(ui_uia_bridge* b, ui_access_node* n, int action, char* value, int length):
	if (((n.actions & action) == 0) || ui_access_inert(n)): return 0
	if ((action == UI_ACCESS_SET_VALUE) && ((n.states & UI_ACCESS_READONLY) != 0)): return 0
	if ((b.queued >= ui_uia_max_requests) || (length < 0) || (length > b.published.max_text_bytes)): return 0
	ui_uia_request* r = &b.queue[b.queued]
	r.id = n.id
	r.action = action
	r.length = length
	r.value = cast(char*, malloc(length + 1))
	for i in range(length): r.value[i] = value[i]
	r.value[length] = 0
	b.queued = b.queued + 1
	return 1


void ui_uia_clear_queue(ui_uia_bridge* b):
	for i in range(b.queued): free(b.queue[i].value)
	b.queued = 0


# HRESULT for queuing action on the element: not available, not
# enabled (inert, unsupported or the queue is full), or S_OK.
int ui_uia_request_action(int self, int action):
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if (ui_uia_enqueue(ui_uia_bridge_of(e), n, action, c"", 0)): return UIA_S_OK
	return UIA_E_ELEMENTNOTENABLED


# Toggles, selections and expansions fall back to activation when the
# node only offers ACTIVATE.
int ui_uia_request_toggle(int self):
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if ((n.actions & UI_ACCESS_TOGGLE) != 0): return ui_uia_request_action(self, UI_ACCESS_TOGGLE)
	return ui_uia_request_action(self, UI_ACCESS_ACTIVATE)


/* IUnknown. */

int ui_uia_query_interface(int self, int riid, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	if (riid == 0): return UIA_E_INVALIDARG
	ui_uia_element* e = ui_uia_self(self)
	int kind = 0 - 1
	if (ui_uia_guid_is(riid, 0)): kind = UI_UIA_SIMPLE
	else if (ui_uia_guid_is(riid, UI_UIA_IDISPATCH_SLOT)): kind = UI_UIA_ACCESSIBLE
	else:
		ui_access_node* n = ui_uia_node(e)
		for k in range(UI_UIA_IFACES):
			if ((kind < 0) && ui_uia_guid_is(riid, k + 1)):
				if ((k == UI_UIA_SIMPLE) || (k == UI_UIA_FRAGMENT)): kind = k
				else if ((n != 0) && ui_uia_supports(ui_uia_bridge_of(e), n, k)): kind = k
	if (kind < 0): return UIA_E_NOINTERFACE
	e.refs = e.refs + 1
	save_int64(cast(char*, out), ui_uia_iface_ptr(e, kind))
	return UIA_S_OK


int ui_uia_add_ref(int self):
	ui_uia_element* e = ui_uia_self(self)
	e.refs = e.refs + 1
	return e.refs


# Elements of live nodes stay cached for the bridge; a dead one is
# freed with its last reference.
int ui_uia_release(int self):
	ui_uia_element* e = ui_uia_self(self)
	if (e.refs > 0): e.refs = e.refs - 1
	int left = e.refs
	if ((left == 0) && e.dead): free(e)
	return left


/* IRawElementProviderSimple. */

int ui_uia_provider_options(int self, int out):
	if (out == 0): return UIA_E_POINTER
	ui_uia_element* e = ui_uia_self(self)
	int options = ProviderOptions_ServerSideProvider
	if (e.dead == 0): options = ui_uia_bridge_of(e).options
	save_int32(cast(char*, out), options)
	return UIA_S_OK


int ui_uia_pattern_kind(int pattern):
	if (pattern == UIA_InvokePatternId): return UI_UIA_INVOKE
	if (pattern == UIA_TogglePatternId): return UI_UIA_TOGGLE
	if (pattern == UIA_ValuePatternId): return UI_UIA_VALUE
	if (pattern == UIA_SelectionItemPatternId): return UI_UIA_SELECTION_ITEM
	if (pattern == UIA_ExpandCollapsePatternId): return UI_UIA_EXPAND
	if (pattern == UIA_RangeValuePatternId): return UI_UIA_RANGE
	if (pattern == UIA_SelectionPatternId): return UI_UIA_SELECTION
	if (pattern == UIA_GridPatternId): return UI_UIA_GRID
	if (pattern == UIA_GridItemPatternId): return UI_UIA_GRID_ITEM
	if (pattern == UIA_TablePatternId): return UI_UIA_TABLE
	if (pattern == UIA_TableItemPatternId): return UI_UIA_TABLE_ITEM
	return 0 - 1


int ui_uia_get_pattern(int self, int pattern, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int kind = ui_uia_pattern_kind(ui_uia_lo32(pattern))
	if ((kind < 0) || !ui_uia_supports(ui_uia_bridge_of(e), n, kind)): return UIA_S_OK
	e.refs = e.refs + 1
	save_int64(cast(char*, out), ui_uia_iface_ptr(e, kind))
	return UIA_S_OK


int ui_uia_checked(ui_access_node* n):
	return (n.states & UI_ACCESS_CHECKED) != 0


int ui_uia_selected(ui_access_node* n):
	if (n.role == UI_ACCESS_RADIO): return ui_uia_checked(n)
	return (n.states & UI_ACCESS_SELECTED) != 0


int ui_uia_expanded(ui_access_node* n):
	return (n.states & UI_ACCESS_EXPANDED) != 0


int ui_uia_get_property(int self, int property, int out):
	if (out == 0): return UIA_E_POINTER
	char* v = cast(char*, out)
	ui_uia_variant_clear(v)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	int p = ui_uia_lo32(property)
	int inert = ui_access_inert(n)
	if (p == UIA_ControlTypePropertyId): ui_uia_variant_i4(v, ui_uia_control_type(b, n))
	else if (p == UIA_LocalizedControlTypePropertyId):
		if (n.role == UI_ACCESS_SWITCH): ui_uia_variant_string(v, c"toggle switch")
		else if (n.role == UI_ACCESS_HEADING): ui_uia_variant_string(v, c"heading")
		else if (n.role == UI_ACCESS_DIALOG): ui_uia_variant_string(v, c"dialog")
	else if (p == UIA_NamePropertyId):
		if (n.name.length > 0): ui_uia_variant_text(v, &n.name)
	else if ((p == UIA_HelpTextPropertyId) || (p == UIA_FullDescriptionPropertyId)):
		if (n.description.length > 0): ui_uia_variant_text(v, &n.description)
	else if (p == UIA_AutomationIdPropertyId):
		char* id = itoa(n.id)
		ui_uia_variant_string(v, id)
	else if (p == UIA_FrameworkIdPropertyId): ui_uia_variant_string(v, c"W")
	else if (p == UIA_IsEnabledPropertyId): ui_uia_variant_bool(v, inert == 0)
	else if (p == UIA_IsKeyboardFocusablePropertyId): ui_uia_variant_bool(v, ((n.states & UI_ACCESS_FOCUSABLE) != 0) && (inert == 0))
	else if (p == UIA_HasKeyboardFocusPropertyId): ui_uia_variant_bool(v, (b.published.focused_id == n.id) && (inert == 0))
	else if (p == UIA_IsOffscreenPropertyId): ui_uia_variant_bool(v, ui_uia_hidden(n))
	else if ((p == UIA_IsControlElementPropertyId) || (p == UIA_IsContentElementPropertyId)): ui_uia_variant_bool(v, 1)
	else if (p == UIA_IsDialogPropertyId): ui_uia_variant_bool(v, n.role == UI_ACCESS_DIALOG)
	else if (p == UIA_HeadingLevelPropertyId):
		int level = HeadingLevel_None
		if ((n.role == UI_ACCESS_HEADING) && (n.heading_level >= 1) && (n.heading_level <= 9)): level = HeadingLevel_None + n.heading_level
		ui_uia_variant_i4(v, level)
	# Pattern properties too, for clients that ask the element directly.
	else if ((p == UIA_ToggleToggleStatePropertyId) && ui_uia_supports(b, n, UI_UIA_TOGGLE)): ui_uia_variant_i4(v, ui_uia_checked(n))
	else if ((p == UIA_ValueValuePropertyId) && ui_uia_supports(b, n, UI_UIA_VALUE)): ui_uia_variant_text(v, &n.value)
	else if ((p == UIA_SelectionItemIsSelectedPropertyId) && ui_uia_supports(b, n, UI_UIA_SELECTION_ITEM)): ui_uia_variant_bool(v, ui_uia_selected(n))
	else if ((p == UIA_ExpandCollapseExpandCollapseStatePropertyId) && ui_uia_supports(b, n, UI_UIA_EXPAND)): ui_uia_variant_i4(v, ui_uia_expanded(n))
	else if ((p == UIA_SelectionItemSelectionContainerPropertyId) && ui_uia_supports(b, n, UI_UIA_SELECTION_ITEM)):
		ui_access_node* container = ui_uia_container_of(n)
		if (container != 0):
			save_int16(v, VT_UNKNOWN)
			ui_uia_hand_out(b, container.id, UI_UIA_SIMPLE, cast(int, &v[8]))
	else if (ui_uia_supports(b, n, UI_UIA_SELECTION) && ((p == UIA_SelectionSelectionPropertyId) || (p == UIA_SelectionCanSelectMultiplePropertyId) || (p == UIA_SelectionIsSelectionRequiredPropertyId))):
		if (p == UIA_SelectionCanSelectMultiplePropertyId): ui_uia_variant_bool(v, 0)
		else if (p == UIA_SelectionIsSelectionRequiredPropertyId): ui_uia_variant_bool(v, n.role == UI_ACCESS_TAB_LIST)
		else:
			list[int] ids = ui_uia_selection_ids(n)
			int array = ui_uia_element_array(b, ids)
			list_free[int](ids)
			if (array != 0):
				save_int16(v, VT_UNKNOWN | VT_ARRAY)
				save_int64(&v[8], array)
	else if (((p == UIA_GridRowCountPropertyId) || (p == UIA_GridColumnCountPropertyId)) && ui_uia_supports(b, n, UI_UIA_GRID)):
		if (p == UIA_GridRowCountPropertyId): ui_uia_variant_i4(v, ui_access_table_rows(n))
		else: ui_uia_variant_i4(v, ui_access_table_columns(n))
	else if ((p == UIA_TableRowOrColumnMajorPropertyId) && ui_uia_supports(b, n, UI_UIA_TABLE)): ui_uia_variant_i4(v, 0)
	else if ((p >= UIA_GridItemRowPropertyId) && (p <= UIA_GridItemContainingGridPropertyId) && ui_uia_supports(b, n, UI_UIA_GRID_ITEM)):
		int row = 0
		int col = 0
		ui_access_cell_position(n, &row, &col)
		if (p == UIA_GridItemRowPropertyId): ui_uia_variant_i4(v, row)
		else if (p == UIA_GridItemColumnPropertyId): ui_uia_variant_i4(v, col)
		else if (p == UIA_GridItemContainingGridPropertyId):
			save_int16(v, VT_UNKNOWN)
			ui_uia_hand_out(b, n.parent.parent.id, UI_UIA_SIMPLE, cast(int, &v[8]))
		else: ui_uia_variant_i4(v, 1)
	return UIA_S_OK


int ui_uia_host_provider(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	if ((b.hwnd != 0) && ui_uia_is_root(b, n)): return UiaHostProviderFromHwnd(b.hwnd, cast(int*, out))
	return UIA_S_OK


/* IRawElementProviderFragment. */

int ui_uia_navigate(int self, int direction, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	int d = ui_uia_lo32(direction)
	ui_access_node* to = 0
	# The root's parent and siblings belong to the host window.
	if (ui_uia_is_root(b, n) && (d != NavigateDirection_FirstChild) && (d != NavigateDirection_LastChild)): return UIA_S_OK
	if (d == NavigateDirection_Parent): to = n.parent
	else if (d == NavigateDirection_NextSibling): to = n.next_sibling
	else if (d == NavigateDirection_FirstChild): to = n.first_child
	else if (d == NavigateDirection_LastChild): to = n.last_child
	else if ((d == NavigateDirection_PreviousSibling) && (n.parent != 0)):
		ui_access_node* c = n.parent.first_child
		while ((c != 0) && (c.next_sibling != n)): c = c.next_sibling
		to = c
	if (to == 0): return UIA_S_OK
	return ui_uia_hand_out(b, to.id, UI_UIA_FRAGMENT, out)


# The runtime id [UiaAppendRuntimeId, id], which UIA prefixes with the
# host window's; a hosted root has none (the window's id is used). An
# unhosted tree has no window to append to (UIA fails the request), so
# its ids are [process id, id] instead.
int ui_uia_runtime_id(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	if ((b.hwnd != 0) && ui_uia_is_root(b, n)): return UIA_S_OK
	int array = SafeArrayCreateVector(VT_I4, 0, 2)
	if (array == 0): return UIA_E_INVALIDARG
	int32[1] index
	int32[1] value
	index[0] = 0
	value[0] = UiaAppendRuntimeId
	if (b.hwnd == 0): value[0] = GetCurrentProcessId()
	SafeArrayPutElement(array, &index[0], cast(char*, &value[0]))
	index[0] = 1
	value[0] = n.id
	SafeArrayPutElement(array, &index[0], cast(char*, &value[0]))
	save_int64(cast(char*, out), array)
	return UIA_S_OK


# Screen coordinates of the tree's (0, 0): the host window's client
# origin, else the configured origin.
void ui_uia_origin(ui_uia_bridge* b, int* x, int* y):
	x[0] = b.origin_x
	y[0] = b.origin_y
	if (b.hwnd == 0): return
	int32[2] point
	point[0] = 0
	point[1] = 0
	if (ClientToScreen(b.hwnd, &point[0]) & 255):
		x[0] = point[0]
		y[0] = point[1]


int ui_uia_bounds(int self, int out):
	if (out == 0): return UIA_E_POINTER
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	for i in range(4): ui_uia_put_double(out + i * 8, 0.0)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if (ui_uia_hidden(n)): return UIA_S_OK
	int ox = 0
	int oy = 0
	ui_uia_origin(ui_uia_bridge_of(e), &ox, &oy)
	ui_uia_put_double(out, cast(float64, n.bounds.x) + cast(float64, ox))
	ui_uia_put_double(out + 8, cast(float64, n.bounds.y) + cast(float64, oy))
	ui_uia_put_double(out + 16, cast(float64, n.bounds.w))
	ui_uia_put_double(out + 24, cast(float64, n.bounds.h))
	return UIA_S_OK


int ui_uia_embedded_roots(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	return UIA_S_OK


int ui_uia_set_focus(int self):
	return ui_uia_request_action(self, UI_ACCESS_FOCUS)


int ui_uia_fragment_root(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	return ui_uia_hand_out(b, b.published.root.id, UI_UIA_ROOT, out)


/* IRawElementProviderFragmentRoot. */

# The deepest visible node containing (x, y), in tree coordinates.
ui_access_node* ui_uia_hit(ui_access_node* n, float64 x, float64 y):
	if ((n.states & UI_ACCESS_HIDDEN) != 0): return 0
	ui_rect r = n.bounds
	if ((x < cast(float64, r.x)) || (y < cast(float64, r.y)) || (x >= cast(float64, r.x + r.w)) || (y >= cast(float64, r.y + r.h))): return 0
	ui_access_node* c = n.first_child
	ui_access_node* best = n
	while (c != 0):
		ui_access_node* hit = ui_uia_hit(c, x, y)
		if (hit != 0): best = hit
		c = c.next_sibling
	return best


# Entered through the xmm stub: x and y arrive as raw double bits.
int ui_uia_from_point(int self, int x_bits, int y_bits, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	int ox = 0
	int oy = 0
	ui_uia_origin(b, &ox, &oy)
	float64 x = ui_uia_double_from_bits(x_bits) - cast(float64, ox)
	float64 y = ui_uia_double_from_bits(y_bits) - cast(float64, oy)
	ui_access_node* hit = ui_uia_hit(b.published.root, x, y)
	if (hit == 0): return UIA_S_OK
	return ui_uia_hand_out(b, hit.id, UI_UIA_FRAGMENT, out)


int ui_uia_get_focus(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	ui_access_node* f = ui_access_find(b.published, b.published.focused_id)
	if ((f == 0) || (f == b.published.root) || ui_access_inert(f)): return UIA_S_OK
	return ui_uia_hand_out(b, f.id, UI_UIA_FRAGMENT, out)


/* Control patterns. */

int ui_uia_invoke(int self):
	return ui_uia_request_action(self, UI_ACCESS_ACTIVATE)


int ui_uia_toggle(int self):
	return ui_uia_request_toggle(self)


# Writes a 32-bit answer computed from the node; not available once the
# node is gone.
int ui_uia_answer32(int self, int out, int which):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int v = 0
	if (which == 0): v = ui_uia_checked(n)
	else if (which == 1):
		# Value.IsReadOnly
		v = ((n.states & UI_ACCESS_READONLY) != 0) || ((n.actions & UI_ACCESS_SET_VALUE) == 0) || ui_access_inert(n)
	else if (which == 2): v = ui_uia_selected(n)
	else if (which == 3): v = ui_uia_expanded(n)
	else if (which == 4): v = 1
	else if (which == 6): v = n.role == UI_ACCESS_TAB_LIST
	else if (which == 7): v = ui_access_table_rows(n)
	else if (which == 8): v = ui_access_table_columns(n)
	else if ((which == 10) || (which == 11)):
		int row = 0
		int col = 0
		ui_access_cell_position(n, &row, &col)
		if (which == 10): v = row
		else: v = col
	# 5: CanSelectMultiple and 9: RowOrColumnMajor_RowMajor are 0.
	save_int32(cast(char*, out), v)
	return UIA_S_OK


int ui_uia_toggle_state(int self, int out):
	return ui_uia_answer32(self, out, 0)


int ui_uia_value_set(int self, int text):
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if (text == 0): return UIA_E_INVALIDARG
	int length = 0
	char* value = ui_uia_utf8(text, &length)
	int ok = ui_uia_enqueue(ui_uia_bridge_of(e), n, UI_ACCESS_SET_VALUE, value, length)
	free(value)
	if ok: return UIA_S_OK
	return UIA_E_ELEMENTNOTENABLED


int ui_uia_value_get(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	save_int64(cast(char*, out), ui_uia_bstr(n.value.data, n.value.length))
	return UIA_S_OK


int ui_uia_value_read_only(int self, int out):
	return ui_uia_answer32(self, out, 1)


int ui_uia_select(int self):
	return ui_uia_request_action(self, UI_ACCESS_ACTIVATE)


# Single selection: adding the selected item, or removing an unselected
# one, is a no-op; anything else would need multiple selection.
int ui_uia_add_to_selection(int self):
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if (ui_uia_selected(n)): return UIA_S_OK
	return UIA_E_INVALIDOPERATION


int ui_uia_remove_from_selection(int self):
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if (ui_uia_selected(n)): return UIA_E_INVALIDOPERATION
	return UIA_S_OK


int ui_uia_is_selected(int self, int out):
	return ui_uia_answer32(self, out, 2)


int ui_uia_selection_container(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_access_node* container = ui_uia_container_of(n)
	if (container == 0): return UIA_S_OK
	return ui_uia_hand_out(ui_uia_bridge_of(e), container.id, UI_UIA_SIMPLE, out)


int ui_uia_expand_to(int self, int expanded):
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if (ui_uia_expanded(n) == expanded): return UIA_S_OK
	return ui_uia_request_action(self, UI_ACCESS_ACTIVATE)


int ui_uia_expand(int self):
	return ui_uia_expand_to(self, 1)


int ui_uia_collapse(int self):
	return ui_uia_expand_to(self, 0)


int ui_uia_expand_state(int self, int out):
	return ui_uia_answer32(self, out, 3)


# Progress bars are read-only ranges 0..100 whose value is the leading
# number of the node's value text ("40%").
int ui_uia_range_set(int self, int bits):
	ui_uia_element* e = ui_uia_self(self)
	if (ui_uia_node(e) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	return UIA_E_ELEMENTNOTENABLED


int ui_uia_range_number(ui_access_node* n):
	int v = 0
	int i = 0
	while ((i < n.value.length) && (n.value.data[i] >= '0') && (n.value.data[i] <= '9')):
		v = v * 10 + (n.value.data[i] - '0')
		i = i + 1
	return v


int ui_uia_range_answer(int self, int out, int which):
	if (out == 0): return UIA_E_POINTER
	ui_uia_put_double(out, 0.0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int v = 0
	if (which == 0): v = ui_uia_range_number(n)
	else if (which == 1): v = 100
	else if (which == 3): v = 10
	else if (which == 4): v = 1
	ui_uia_put_double(out, cast(float64, v))
	return UIA_S_OK


int ui_uia_range_value(int self, int out):
	return ui_uia_range_answer(self, out, 0)


int ui_uia_range_read_only(int self, int out):
	return ui_uia_answer32(self, out, 4)


int ui_uia_range_maximum(int self, int out):
	return ui_uia_range_answer(self, out, 1)


int ui_uia_range_minimum(int self, int out):
	return ui_uia_range_answer(self, out, 2)


int ui_uia_range_large_change(int self, int out):
	return ui_uia_range_answer(self, out, 3)


int ui_uia_range_small_change(int self, int out):
	return ui_uia_range_answer(self, out, 4)


# Selection: lists, tab lists and tables over their items, tabs and data
# rows; single selection, required in tab lists. The element arrays
# (which: 0 the selection, 1 column headers, 2 a cell's column header,
# 3 row headers, which the snapshot model has none of).
int ui_uia_answer_array(int self, int out, int which):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	list[int] ids = 0
	if (which == 0): ids = ui_uia_selection_ids(n)
	else if (which == 1): ids = ui_uia_column_header_ids(n)
	else:
		ids = new list[int]
		if (which == 2):
			int row = 0
			int col = 0
			ui_access_cell_position(n, &row, &col)
			ui_access_node* header = ui_access_row_cell(ui_access_header_row(n.parent.parent), col)
			if (header != 0): ids.push(header.id)
	int array = ui_uia_element_array(b, ids)
	list_free[int](ids)
	if (array == 0): return UIA_E_FAIL
	save_int64(cast(char*, out), array)
	return UIA_S_OK


int ui_uia_selection_get(int self, int out):
	return ui_uia_answer_array(self, out, 0)


int ui_uia_selection_multiple(int self, int out):
	return ui_uia_answer32(self, out, 5)


int ui_uia_selection_required(int self, int out):
	return ui_uia_answer32(self, out, 6)


# Grid and Table on tables: data rows by cell columns, row major, the
# header row's cells as column headers.
int ui_uia_grid_item(int self, int row, int col, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_access_node* cell = ui_access_row_cell(ui_access_table_row(n, ui_uia_lo32(row)), ui_uia_lo32(col))
	if (cell == 0): return UIA_E_INVALIDARG
	return ui_uia_hand_out(ui_uia_bridge_of(e), cell.id, UI_UIA_SIMPLE, out)


int ui_uia_grid_rows(int self, int out):
	return ui_uia_answer32(self, out, 7)


int ui_uia_grid_columns(int self, int out):
	return ui_uia_answer32(self, out, 8)


int ui_uia_table_row_headers(int self, int out):
	return ui_uia_answer_array(self, out, 3)


int ui_uia_table_column_headers(int self, int out):
	return ui_uia_answer_array(self, out, 1)


int ui_uia_table_major(int self, int out):
	return ui_uia_answer32(self, out, 9)


# GridItem and TableItem on data cells.
int ui_uia_grid_item_row(int self, int out):
	return ui_uia_answer32(self, out, 10)


int ui_uia_grid_item_column(int self, int out):
	return ui_uia_answer32(self, out, 11)


int ui_uia_grid_item_span(int self, int out):
	return ui_uia_answer32(self, out, 4)


int ui_uia_grid_item_grid(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	return ui_uia_hand_out(ui_uia_bridge_of(e), n.parent.parent.id, UI_UIA_SIMPLE, out)


int ui_uia_table_item_row_headers(int self, int out):
	return ui_uia_answer_array(self, out, 3)


int ui_uia_table_item_column_headers(int self, int out):
	return ui_uia_answer_array(self, out, 2)


/* MSAA: IAccessible over the same elements. Every method takes the
child it is about as a VARIANT (by value, which the x64 ABI passes as a
pointer to a copy): CHILDID_SELF, a 1-based child index, or -id for any
node of the tree. A gone node answers E_FAIL. */

# The node a child-id VARIANT names relative to self's node, or 0 with
# *status the HRESULT to fail with.
ui_access_node* ui_msaa_target(int self, int variant, int* status):
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	status[0] = UIA_E_FAIL
	if (n == 0): return 0
	status[0] = UIA_E_INVALIDARG
	if (variant == 0): return 0
	char* v = cast(char*, variant)
	int vt = load_int16(v) & 65535
	if (vt == VT_EMPTY): return n
	if (vt != VT_I4): return 0
	int child = ui_uia_lo32(load_int32(&v[8]))
	if (child == CHILDID_SELF): return n
	ui_access_node* to = 0
	if (child < 0): to = ui_access_find(ui_uia_bridge_of(e).published, 0 - child)
	else:
		ui_access_node* c = n.first_child
		int k = 1
		while ((c != 0) && (k < child)):
			c = c.next_sibling
			k = k + 1
		to = c
	if (to != 0): status[0] = UIA_S_OK
	return to


ui_uia_bridge* ui_msaa_bridge(int self):
	return ui_uia_bridge_of(ui_uia_self(self))


int ui_msaa_role(ui_uia_bridge* b, ui_access_node* n):
	int r = n.role
	if (r == UI_ACCESS_DOCUMENT):
		if (ui_uia_is_root(b, n)): return ROLE_SYSTEM_CLIENT
		return ROLE_SYSTEM_DOCUMENT
	if ((r == UI_ACCESS_TEXT) || (r == UI_ACCESS_HEADING)): return ROLE_SYSTEM_STATICTEXT
	if (r == UI_ACCESS_LINK): return ROLE_SYSTEM_LINK
	if (r == UI_ACCESS_BUTTON): return ROLE_SYSTEM_PUSHBUTTON
	if ((r == UI_ACCESS_CHECKBOX) || (r == UI_ACCESS_SWITCH)): return ROLE_SYSTEM_CHECKBUTTON
	if (r == UI_ACCESS_TEXTBOX): return ROLE_SYSTEM_TEXT
	if (r == UI_ACCESS_IMAGE): return ROLE_SYSTEM_GRAPHIC
	if (r == UI_ACCESS_LIST): return ROLE_SYSTEM_LIST
	if (r == UI_ACCESS_LIST_ITEM): return ROLE_SYSTEM_LISTITEM
	if (r == UI_ACCESS_TABLE): return ROLE_SYSTEM_TABLE
	if (r == UI_ACCESS_ROW): return ROLE_SYSTEM_ROW
	if (r == UI_ACCESS_CELL):
		if (ui_access_is_header_cell(n)): return ROLE_SYSTEM_COLUMNHEADER
		return ROLE_SYSTEM_CELL
	if (r == UI_ACCESS_RADIO): return ROLE_SYSTEM_RADIOBUTTON
	if (r == UI_ACCESS_COMBOBOX): return ROLE_SYSTEM_COMBOBOX
	if (r == UI_ACCESS_TAB_LIST): return ROLE_SYSTEM_PAGETABLIST
	if (r == UI_ACCESS_TAB): return ROLE_SYSTEM_PAGETAB
	if (r == UI_ACCESS_PROGRESS): return ROLE_SYSTEM_PROGRESSBAR
	if (r == UI_ACCESS_DIALOG): return ROLE_SYSTEM_DIALOG
	return ROLE_SYSTEM_GROUPING


int ui_msaa_disabled(ui_access_node* n):
	ui_access_node* p = n
	while (p != 0):
		if ((p.states & UI_ACCESS_DISABLED) != 0): return 1
		p = p.parent
	return 0


int ui_msaa_state(ui_uia_bridge* b, ui_access_node* n):
	int s = 0
	int inert = ui_access_inert(n)
	if (ui_msaa_disabled(n)): s = s | STATE_SYSTEM_UNAVAILABLE
	if (ui_uia_hidden(n)): s = s | STATE_SYSTEM_INVISIBLE | STATE_SYSTEM_OFFSCREEN
	if (((n.states & UI_ACCESS_FOCUSABLE) != 0) && !inert): s = s | STATE_SYSTEM_FOCUSABLE
	if ((b.published.focused_id == n.id) && !inert): s = s | STATE_SYSTEM_FOCUSED
	if (ui_uia_supports(b, n, UI_UIA_SELECTION_ITEM)):
		s = s | STATE_SYSTEM_SELECTABLE
		if ((n.role != UI_ACCESS_RADIO) && ui_uia_selected(n)): s = s | STATE_SYSTEM_SELECTED
	if (((n.role == UI_ACCESS_CHECKBOX) || (n.role == UI_ACCESS_SWITCH) || (n.role == UI_ACCESS_RADIO)) && ui_uia_checked(n)): s = s | STATE_SYSTEM_CHECKED
	if ((n.states & UI_ACCESS_READONLY) != 0): s = s | STATE_SYSTEM_READONLY
	else if ((n.role == UI_ACCESS_TEXTBOX) && ((n.actions & UI_ACCESS_SET_VALUE) == 0)): s = s | STATE_SYSTEM_READONLY
	if (ui_uia_expanded(n)): s = s | STATE_SYSTEM_EXPANDED
	else if (ui_uia_supports(b, n, UI_UIA_EXPAND)): s = s | STATE_SYSTEM_COLLAPSED
	if (n.role == UI_ACCESS_COMBOBOX): s = s | STATE_SYSTEM_HASPOPUP
	if (n.role == UI_ACCESS_LINK): s = s | STATE_SYSTEM_LINKED
	return s


# The default action: toggle where the node toggles, else activation;
# 0 when it has neither.
int ui_msaa_default_action(ui_access_node* n):
	if ((n.actions & UI_ACCESS_TOGGLE) != 0): return UI_ACCESS_TOGGLE
	if ((n.actions & UI_ACCESS_ACTIVATE) != 0): return UI_ACCESS_ACTIVATE
	return 0


char* ui_msaa_default_action_name(ui_uia_bridge* b, ui_access_node* n):
	if (ui_msaa_default_action(n) == 0): return 0
	int r = n.role
	if ((r == UI_ACCESS_CHECKBOX) || (r == UI_ACCESS_SWITCH)):
		if (ui_uia_checked(n)): return c"Uncheck"
		return c"Check"
	if (r == UI_ACCESS_RADIO): return c"Check"
	if (r == UI_ACCESS_LINK): return c"Jump"
	if (r == UI_ACCESS_TAB): return c"Switch"
	if ((r == UI_ACCESS_LIST_ITEM) || (r == UI_ACCESS_ROW)): return c"Select"
	if (r == UI_ACCESS_COMBOBOX):
		if (ui_uia_expanded(n)): return c"Close"
		return c"Open"
	if (ui_uia_supports(b, n, UI_UIA_EXPAND)):
		if (ui_uia_expanded(n)): return c"Collapse"
		return c"Expand"
	return c"Press"


# Hand out node id's IAccessible as a VT_DISPATCH VARIANT.
int ui_msaa_variant_object(ui_uia_bridge* b, char* v, int id):
	save_int16(v, VT_DISPATCH)
	return ui_uia_hand_out(b, id, UI_UIA_ACCESSIBLE, cast(int, &v[8]))


# A VARIANT naming target as seen from self's node n: CHILDID_SELF for n
# itself, else the target's own object; S_FALSE (VT_EMPTY) for none.
int ui_msaa_variant_node(ui_uia_bridge* b, char* v, ui_access_node* n, ui_access_node* target):
	if (target == 0): return UIA_S_FALSE
	if (target == n):
		ui_uia_variant_i4(v, CHILDID_SELF)
		return UIA_S_OK
	return ui_msaa_variant_object(b, v, target.id)


# Writes a BSTR answer (S_FALSE and null for an empty one).
int ui_msaa_bstr_answer(int out, ui_access_text* t):
	if (t.length == 0): return UIA_S_FALSE
	save_int64(cast(char*, out), ui_uia_bstr(t.data, t.length))
	return UIA_S_OK


# IDispatch: no type information; the IAccessible methods are called
# through the vtable.
int ui_msaa_type_info_count(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	return UIA_S_OK


int ui_msaa_not_implemented(int self):
	return UIA_E_NOTIMPL


int ui_msaa_parent(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_FAIL
	ui_uia_bridge* b = ui_uia_bridge_of(e)
	if (n.parent != 0): return ui_uia_hand_out(b, n.parent.id, UI_UIA_ACCESSIBLE, out)
	# The client area's parent is the window's own (system) object.
	if (b.hwnd == 0): return UIA_S_FALSE
	int r = ui_uia_lo32(AccessibleObjectFromWindow(b.hwnd, OBJID_WINDOW, &ui_uia_iids[(UI_UIA_ACCESSIBLE + 1) * 16], cast(int*, out)))
	if (r < 0): return UIA_S_FALSE
	return UIA_S_OK


int ui_msaa_child_count(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	if (n == 0): return UIA_E_FAIL
	int count = 0
	ui_access_node* c = n.first_child
	while (c != 0):
		count = count + 1
		c = c.next_sibling
	save_int32(cast(char*, out), count)
	return UIA_S_OK


int ui_msaa_child(int self, int variant, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	int status = 0
	ui_access_node* t = ui_msaa_target(self, variant, &status)
	if (t == 0): return status
	return ui_uia_hand_out(ui_msaa_bridge(self), t.id, UI_UIA_ACCESSIBLE, out)


# Name, value, description, help, keyboard shortcut and default action
# (which: 0..5) as BSTRs.
int ui_msaa_text(int self, int variant, int out, int which):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	int status = 0
	ui_access_node* t = ui_msaa_target(self, variant, &status)
	if (t == 0): return status
	if (which == 0): return ui_msaa_bstr_answer(out, &t.name)
	if (which == 1):
		if ((t.role == UI_ACCESS_TEXTBOX) || (t.role == UI_ACCESS_COMBOBOX)):
			save_int64(cast(char*, out), ui_uia_bstr(t.value.data, t.value.length))
			return UIA_S_OK
		return ui_msaa_bstr_answer(out, &t.value)
	if (which == 2): return ui_msaa_bstr_answer(out, &t.description)
	if (which == 5):
		char* name = ui_msaa_default_action_name(ui_msaa_bridge(self), t)
		if (name == 0): return UIA_S_FALSE
		save_int64(cast(char*, out), ui_uia_bstr(name, strlen(name)))
		return UIA_S_OK
	return UIA_S_FALSE


int ui_msaa_name(int self, int variant, int out):
	return ui_msaa_text(self, variant, out, 0)


int ui_msaa_value(int self, int variant, int out):
	return ui_msaa_text(self, variant, out, 1)


int ui_msaa_description(int self, int variant, int out):
	return ui_msaa_text(self, variant, out, 2)


int ui_msaa_help(int self, int variant, int out):
	return ui_msaa_text(self, variant, out, 3)


int ui_msaa_shortcut(int self, int variant, int out):
	return ui_msaa_text(self, variant, out, 4)


int ui_msaa_default_action_get(int self, int variant, int out):
	return ui_msaa_text(self, variant, out, 5)


int ui_msaa_help_topic(int self, int file, int variant, int topic):
	if (file != 0): save_int64(cast(char*, file), 0)
	if (topic != 0): save_int32(cast(char*, topic), 0 - 1)
	return UIA_S_FALSE


int ui_msaa_role_get(int self, int variant, int out):
	if (out == 0): return UIA_E_POINTER
	ui_uia_variant_clear(cast(char*, out))
	int status = 0
	ui_access_node* t = ui_msaa_target(self, variant, &status)
	if (t == 0): return status
	ui_uia_variant_i4(cast(char*, out), ui_msaa_role(ui_msaa_bridge(self), t))
	return UIA_S_OK


int ui_msaa_state_get(int self, int variant, int out):
	if (out == 0): return UIA_E_POINTER
	ui_uia_variant_clear(cast(char*, out))
	int status = 0
	ui_access_node* t = ui_msaa_target(self, variant, &status)
	if (t == 0): return status
	ui_uia_variant_i4(cast(char*, out), ui_msaa_state(ui_msaa_bridge(self), t))
	return UIA_S_OK


int ui_msaa_is_ancestor(ui_access_node* a, ui_access_node* n):
	while (n != 0):
		if (n == a): return 1
		n = n.parent
	return 0


# The focused node when it is self or inside self.
int ui_msaa_focus(int self, int out):
	if (out == 0): return UIA_E_POINTER
	char* v = cast(char*, out)
	ui_uia_variant_clear(v)
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	if (n == 0): return UIA_E_FAIL
	ui_uia_bridge* b = ui_msaa_bridge(self)
	ui_access_node* f = ui_access_find(b.published, b.published.focused_id)
	if ((f == 0) || ui_access_inert(f) || !ui_msaa_is_ancestor(n, f)): return UIA_S_FALSE
	return ui_msaa_variant_node(b, v, n, f)


# Single selection: the selected child's object, VT_EMPTY for none.
int ui_msaa_selection(int self, int out):
	if (out == 0): return UIA_E_POINTER
	char* v = cast(char*, out)
	ui_uia_variant_clear(v)
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	if (n == 0): return UIA_E_FAIL
	ui_access_node* s = ui_access_selected_at(n, 0)
	if (s == 0): return UIA_S_FALSE
	return ui_msaa_variant_object(ui_msaa_bridge(self), v, s.id)


# Queue action on t; S_OK, or E_FAIL when it is refused.
int ui_msaa_request(int self, ui_access_node* t, int action, char* value, int length):
	if (ui_uia_enqueue(ui_msaa_bridge(self), t, action, value, length)): return UIA_S_OK
	return UIA_E_FAIL


# Single selection driven by activation: taking or adding the selection
# activates an unselected item; removing a selected one, or extending,
# is refused.
int ui_msaa_select(int self, int flags, int variant):
	int status = 0
	ui_access_node* t = ui_msaa_target(self, variant, &status)
	if (t == 0): return status
	int f = ui_uia_lo32(flags)
	if ((f & SELFLAG_EXTENDSELECTION) != 0): return UIA_E_INVALIDARG
	if ((f & (SELFLAG_TAKESELECTION | SELFLAG_ADDSELECTION | SELFLAG_REMOVESELECTION)) != 0):
		if (!ui_uia_supports(ui_msaa_bridge(self), t, UI_UIA_SELECTION_ITEM)): return UIA_E_INVALIDARG
		int selected = ui_uia_selected(t)
		if (((f & SELFLAG_REMOVESELECTION) != 0) && selected): return UIA_E_FAIL
		if (((f & (SELFLAG_TAKESELECTION | SELFLAG_ADDSELECTION)) != 0) && !selected):
			if (ui_msaa_request(self, t, UI_ACCESS_ACTIVATE, c"", 0) != UIA_S_OK): return UIA_E_FAIL
	if ((f & SELFLAG_TAKEFOCUS) != 0): return ui_msaa_request(self, t, UI_ACCESS_FOCUS, c"", 0)
	return UIA_S_OK


# Screen bounds (all 0 while hidden).
int ui_msaa_location(int self, int x, int y, int w, int h, int variant):
	if ((x == 0) || (y == 0) || (w == 0) || (h == 0)): return UIA_E_POINTER
	save_int32(cast(char*, x), 0)
	save_int32(cast(char*, y), 0)
	save_int32(cast(char*, w), 0)
	save_int32(cast(char*, h), 0)
	int status = 0
	ui_access_node* t = ui_msaa_target(self, variant, &status)
	if (t == 0): return status
	if (ui_uia_hidden(t)): return UIA_S_OK
	int ox = 0
	int oy = 0
	ui_uia_origin(ui_msaa_bridge(self), &ox, &oy)
	save_int32(cast(char*, x), cast(int, t.bounds.x) + ox)
	save_int32(cast(char*, y), cast(int, t.bounds.y) + oy)
	save_int32(cast(char*, w), cast(int, t.bounds.w))
	save_int32(cast(char*, h), cast(int, t.bounds.h))
	return UIA_S_OK


# Logical navigation (siblings, first and last child); the spatial
# directions are not supported.
int ui_msaa_navigate(int self, int direction, int variant, int out):
	if (out == 0): return UIA_E_POINTER
	char* v = cast(char*, out)
	ui_uia_variant_clear(v)
	int status = 0
	ui_access_node* s = ui_msaa_target(self, variant, &status)
	if (s == 0): return status
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	int d = ui_uia_lo32(direction)
	ui_access_node* to = 0
	if ((d == NAVDIR_FIRSTCHILD) || (d == NAVDIR_LASTCHILD)):
		if (s != n): return UIA_E_INVALIDARG
		if (d == NAVDIR_FIRSTCHILD): to = s.first_child
		else: to = s.last_child
	else if (d == NAVDIR_NEXT): to = s.next_sibling
	else if (d == NAVDIR_PREVIOUS):
		if (s.parent != 0):
			ui_access_node* c = s.parent.first_child
			while ((c != 0) && (c.next_sibling != s)): c = c.next_sibling
			to = c
	else: return DISP_E_MEMBERNOTFOUND
	if (to == 0): return UIA_S_FALSE
	return ui_msaa_variant_object(ui_msaa_bridge(self), v, to.id)


# The deepest visible node at screen (x, y) inside self.
int ui_msaa_hit_test(int self, int x, int y, int out):
	if (out == 0): return UIA_E_POINTER
	char* v = cast(char*, out)
	ui_uia_variant_clear(v)
	ui_access_node* n = ui_uia_node(ui_uia_self(self))
	if (n == 0): return UIA_E_FAIL
	ui_uia_bridge* b = ui_msaa_bridge(self)
	int ox = 0
	int oy = 0
	ui_uia_origin(b, &ox, &oy)
	ui_access_node* hit = ui_uia_hit(n, cast(float64, ui_uia_lo32(x) - ox), cast(float64, ui_uia_lo32(y) - oy))
	return ui_msaa_variant_node(b, v, n, hit)


int ui_msaa_do_default_action(int self, int variant):
	int status = 0
	ui_access_node* t = ui_msaa_target(self, variant, &status)
	if (t == 0): return status
	int action = ui_msaa_default_action(t)
	if (action == 0): return DISP_E_MEMBERNOTFOUND
	return ui_msaa_request(self, t, action, c"", 0)


int ui_msaa_put_name(int self, int variant, int text):
	return UIA_E_NOTIMPL


int ui_msaa_put_value(int self, int variant, int text):
	int status = 0
	ui_access_node* t = ui_msaa_target(self, variant, &status)
	if (t == 0): return status
	if ((t.actions & UI_ACCESS_SET_VALUE) == 0): return DISP_E_MEMBERNOTFOUND
	int length = 0
	char* value = c""
	if (text != 0): value = ui_uia_utf8(text, &length)
	int r = ui_msaa_request(self, t, UI_ACCESS_SET_VALUE, value, length)
	if (text != 0): free(value)
	return r


/* Vtables. */

int ui_uia_thunk(int fn, int nargs):
	return win_callback(fn, nargs)


# A thunk for a method whose second and third arguments are doubles
# (in xmm1/xmm2 under the x64 convention): copy their bits into
# rdx/r8, then continue in an ordinary win_callback thunk.
int ui_uia_xmm_thunk(int fn, int nargs):
	int inner = win_callback(fn, nargs)
	if (inner == 0): return 0
	int page = VirtualAlloc(0, 4096, 12288, 64)  /* commit, PAGE_EXECUTE_READWRITE */
	if (page == 0): return 0
	char* p = cast(char*, page)
	p[0] = 102                  /* movq rdx,xmm1 (66 48 0F 7E CA) */
	p[1] = 72
	p[2] = 15
	p[3] = 126
	p[4] = 202
	p[5] = 102                  /* movq r8,xmm2 (66 49 0F 7E D0) */
	p[6] = 73
	p[7] = 15
	p[8] = 126
	p[9] = 208
	p[10] = 72                  /* mov rax,imm64 */
	p[11] = 184
	save_int64(&p[12], inner)
	p[20] = 255                 /* jmp rax */
	p[21] = 224
	return page


int* ui_uia_vtable(int methods):
	int* vt = cast(int*, malloc((3 + methods) * 8))
	vt[0] = ui_uia_thunk(cast(int, ui_uia_query_interface), 3)
	vt[1] = ui_uia_thunk(cast(int, ui_uia_add_ref), 1)
	vt[2] = ui_uia_thunk(cast(int, ui_uia_release), 1)
	return vt


void ui_uia_init():
	if ui_uia_ready: return
	ui_uia_ready = 1
	# IUnknown                     {00000000-0000-0000-C000-000000000046}
	ui_uia_guid(0, 0, 0, 0, 192, 0, 0, 0, 0, 0, 0, 70)
	# IRawElementProviderSimple    {d6dd68d1-86fd-4332-8666-9abedea2d24c}
	ui_uia_guid(1, cast(int, 0xd6dd68d1), 0x86fd, 0x4332, 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c)
	# IRawElementProviderFragment  {f7063da8-8359-439c-9297-bbc5299a7d87}
	ui_uia_guid(2, cast(int, 0xf7063da8), 0x8359, 0x439c, 0x92, 0x97, 0xbb, 0xc5, 0x29, 0x9a, 0x7d, 0x87)
	# IRawElementProviderFragmentRoot {620ce2a5-ab8f-40a9-86cb-de3c75599b58}
	ui_uia_guid(3, cast(int, 0x620ce2a5), 0xab8f, 0x40a9, 0x86, 0xcb, 0xde, 0x3c, 0x75, 0x59, 0x9b, 0x58)
	# IInvokeProvider              {54fcb24b-e18e-47a2-b4d3-eccbe77599a2}
	ui_uia_guid(4, cast(int, 0x54fcb24b), 0xe18e, 0x47a2, 0xb4, 0xd3, 0xec, 0xcb, 0xe7, 0x75, 0x99, 0xa2)
	# IToggleProvider              {56d00bd0-c4f4-433c-a836-1a52a57e0892}
	ui_uia_guid(5, cast(int, 0x56d00bd0), 0xc4f4, 0x433c, 0xa8, 0x36, 0x1a, 0x52, 0xa5, 0x7e, 0x08, 0x92)
	# IValueProvider               {c7935180-6fb3-4201-b174-7df73adbf64a}
	ui_uia_guid(6, cast(int, 0xc7935180), 0x6fb3, 0x4201, 0xb1, 0x74, 0x7d, 0xf7, 0x3a, 0xdb, 0xf6, 0x4a)
	# ISelectionItemProvider       {2acad808-b2d4-452d-a407-91ff1ad167b2}
	ui_uia_guid(7, cast(int, 0x2acad808), 0xb2d4, 0x452d, 0xa4, 0x07, 0x91, 0xff, 0x1a, 0xd1, 0x67, 0xb2)
	# IExpandCollapseProvider      {d847d3a5-cab0-4a98-8c32-ecb45c59ad24}
	ui_uia_guid(8, cast(int, 0xd847d3a5), 0xcab0, 0x4a98, 0x8c, 0x32, 0xec, 0xb4, 0x5c, 0x59, 0xad, 0x24)
	# IRangeValueProvider          {36dc7aef-33e6-4691-afe1-2be7274b3d33}
	ui_uia_guid(9, cast(int, 0x36dc7aef), 0x33e6, 0x4691, 0xaf, 0xe1, 0x2b, 0xe7, 0x27, 0x4b, 0x3d, 0x33)
	# ISelectionProvider           {fb8b03af-3bdf-48d4-bd36-1a65793be168}
	ui_uia_guid(10, cast(int, 0xfb8b03af), 0x3bdf, 0x48d4, 0xbd, 0x36, 0x1a, 0x65, 0x79, 0x3b, 0xe1, 0x68)
	# IGridProvider                {b17d6187-0907-464b-a168-0ef17a1572b1}
	ui_uia_guid(11, cast(int, 0xb17d6187), 0x0907, 0x464b, 0xa1, 0x68, 0x0e, 0xf1, 0x7a, 0x15, 0x72, 0xb1)
	# IGridItemProvider            {d02541f1-fb81-4d64-ae32-f520f8a6dbd1}
	ui_uia_guid(12, cast(int, 0xd02541f1), 0xfb81, 0x4d64, 0xae, 0x32, 0xf5, 0x20, 0xf8, 0xa6, 0xdb, 0xd1)
	# ITableProvider               {9c860395-97b3-490a-b52a-858cc22af166}
	ui_uia_guid(13, cast(int, 0x9c860395), 0x97b3, 0x490a, 0xb5, 0x2a, 0x85, 0x8c, 0xc2, 0x2a, 0xf1, 0x66)
	# ITableItemProvider           {b9734fa6-771f-4d78-9c90-2517999349cd}
	ui_uia_guid(14, cast(int, 0xb9734fa6), 0x771f, 0x4d78, 0x9c, 0x90, 0x25, 0x17, 0x99, 0x93, 0x49, 0xcd)
	# IAccessible                  {618736e0-3c3d-11cf-810c-00aa00389b71}
	ui_uia_guid(15, cast(int, 0x618736e0), 0x3c3d, 0x11cf, 0x81, 0x0c, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71)
	# IDispatch                    {00020400-0000-0000-C000-000000000046}
	ui_uia_guid(UI_UIA_IDISPATCH_SLOT, 0x00020400, 0, 0, 192, 0, 0, 0, 0, 0, 0, 70)

	int* vt = ui_uia_vtable(4)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_provider_options), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_get_pattern), 3)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_get_property), 3)
	vt[6] = ui_uia_thunk(cast(int, ui_uia_host_provider), 2)
	ui_uia_vtables[UI_UIA_SIMPLE] = cast(int, vt)

	vt = ui_uia_vtable(6)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_navigate), 3)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_runtime_id), 2)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_bounds), 2)
	vt[6] = ui_uia_thunk(cast(int, ui_uia_embedded_roots), 2)
	vt[7] = ui_uia_thunk(cast(int, ui_uia_set_focus), 1)
	vt[8] = ui_uia_thunk(cast(int, ui_uia_fragment_root), 2)
	ui_uia_vtables[UI_UIA_FRAGMENT] = cast(int, vt)

	vt = ui_uia_vtable(2)
	vt[3] = ui_uia_xmm_thunk(cast(int, ui_uia_from_point), 4)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_get_focus), 2)
	ui_uia_vtables[UI_UIA_ROOT] = cast(int, vt)

	vt = ui_uia_vtable(1)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_invoke), 1)
	ui_uia_vtables[UI_UIA_INVOKE] = cast(int, vt)

	vt = ui_uia_vtable(2)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_toggle), 1)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_toggle_state), 2)
	ui_uia_vtables[UI_UIA_TOGGLE] = cast(int, vt)

	vt = ui_uia_vtable(3)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_value_set), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_value_get), 2)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_value_read_only), 2)
	ui_uia_vtables[UI_UIA_VALUE] = cast(int, vt)

	vt = ui_uia_vtable(5)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_select), 1)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_add_to_selection), 1)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_remove_from_selection), 1)
	vt[6] = ui_uia_thunk(cast(int, ui_uia_is_selected), 2)
	vt[7] = ui_uia_thunk(cast(int, ui_uia_selection_container), 2)
	ui_uia_vtables[UI_UIA_SELECTION_ITEM] = cast(int, vt)

	vt = ui_uia_vtable(3)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_expand), 1)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_collapse), 1)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_expand_state), 2)
	ui_uia_vtables[UI_UIA_EXPAND] = cast(int, vt)

	vt = ui_uia_vtable(7)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_range_set), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_range_value), 2)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_range_read_only), 2)
	vt[6] = ui_uia_thunk(cast(int, ui_uia_range_maximum), 2)
	vt[7] = ui_uia_thunk(cast(int, ui_uia_range_minimum), 2)
	vt[8] = ui_uia_thunk(cast(int, ui_uia_range_large_change), 2)
	vt[9] = ui_uia_thunk(cast(int, ui_uia_range_small_change), 2)
	ui_uia_vtables[UI_UIA_RANGE] = cast(int, vt)

	vt = ui_uia_vtable(3)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_selection_get), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_selection_multiple), 2)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_selection_required), 2)
	ui_uia_vtables[UI_UIA_SELECTION] = cast(int, vt)

	vt = ui_uia_vtable(3)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_grid_item), 4)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_grid_rows), 2)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_grid_columns), 2)
	ui_uia_vtables[UI_UIA_GRID] = cast(int, vt)

	vt = ui_uia_vtable(5)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_grid_item_row), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_grid_item_column), 2)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_grid_item_span), 2)
	vt[6] = ui_uia_thunk(cast(int, ui_uia_grid_item_span), 2)
	vt[7] = ui_uia_thunk(cast(int, ui_uia_grid_item_grid), 2)
	ui_uia_vtables[UI_UIA_GRID_ITEM] = cast(int, vt)

	vt = ui_uia_vtable(3)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_table_row_headers), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_table_column_headers), 2)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_table_major), 2)
	ui_uia_vtables[UI_UIA_TABLE] = cast(int, vt)

	vt = ui_uia_vtable(2)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_table_item_row_headers), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_table_item_column_headers), 2)
	ui_uia_vtables[UI_UIA_TABLE_ITEM] = cast(int, vt)

	# IAccessible: IDispatch (no type information), then its 21 methods.
	vt = ui_uia_vtable(25)
	vt[3] = ui_uia_thunk(cast(int, ui_msaa_type_info_count), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_msaa_not_implemented), 1)
	vt[5] = ui_uia_thunk(cast(int, ui_msaa_not_implemented), 1)
	vt[6] = ui_uia_thunk(cast(int, ui_msaa_not_implemented), 1)
	vt[7] = ui_uia_thunk(cast(int, ui_msaa_parent), 2)
	vt[8] = ui_uia_thunk(cast(int, ui_msaa_child_count), 2)
	vt[9] = ui_uia_thunk(cast(int, ui_msaa_child), 3)
	vt[10] = ui_uia_thunk(cast(int, ui_msaa_name), 3)
	vt[11] = ui_uia_thunk(cast(int, ui_msaa_value), 3)
	vt[12] = ui_uia_thunk(cast(int, ui_msaa_description), 3)
	vt[13] = ui_uia_thunk(cast(int, ui_msaa_role_get), 3)
	vt[14] = ui_uia_thunk(cast(int, ui_msaa_state_get), 3)
	vt[15] = ui_uia_thunk(cast(int, ui_msaa_help), 3)
	vt[16] = ui_uia_thunk(cast(int, ui_msaa_help_topic), 4)
	vt[17] = ui_uia_thunk(cast(int, ui_msaa_shortcut), 3)
	vt[18] = ui_uia_thunk(cast(int, ui_msaa_focus), 2)
	vt[19] = ui_uia_thunk(cast(int, ui_msaa_selection), 2)
	vt[20] = ui_uia_thunk(cast(int, ui_msaa_default_action_get), 3)
	vt[21] = ui_uia_thunk(cast(int, ui_msaa_select), 3)
	vt[22] = ui_uia_thunk(cast(int, ui_msaa_location), 6)
	vt[23] = ui_uia_thunk(cast(int, ui_msaa_navigate), 4)
	vt[24] = ui_uia_thunk(cast(int, ui_msaa_hit_test), 4)
	vt[25] = ui_uia_thunk(cast(int, ui_msaa_do_default_action), 2)
	vt[26] = ui_uia_thunk(cast(int, ui_msaa_put_name), 3)
	vt[27] = ui_uia_thunk(cast(int, ui_msaa_put_value), 3)
	ui_uia_vtables[UI_UIA_ACCESSIBLE] = cast(int, vt)


/* Events. */

void ui_uia_raise_property(ui_uia_bridge* b, int id, int property, char* old_value, char* new_value):
	UiaRaiseAutomationPropertyChangedEvent(ui_uia_simple_of(b, id), property, old_value, new_value)


void ui_uia_raise_bool(ui_uia_bridge* b, int id, int property, int was, int now):
	char[24] old_value
	char[24] new_value
	ui_uia_variant_clear(&old_value[0])
	ui_uia_variant_clear(&new_value[0])
	ui_uia_variant_bool(&old_value[0], was)
	ui_uia_variant_bool(&new_value[0], now)
	ui_uia_raise_property(b, id, property, &old_value[0], &new_value[0])


void ui_uia_raise_i4(ui_uia_bridge* b, int id, int property, int was, int now):
	char[24] old_value
	char[24] new_value
	ui_uia_variant_clear(&old_value[0])
	ui_uia_variant_clear(&new_value[0])
	ui_uia_variant_i4(&old_value[0], was)
	ui_uia_variant_i4(&new_value[0], now)
	ui_uia_raise_property(b, id, property, &old_value[0], &new_value[0])


void ui_uia_raise_text(ui_uia_bridge* b, int id, int property, ui_access_text* was, ui_access_text* now):
	char[24] old_value
	char[24] new_value
	ui_uia_variant_clear(&old_value[0])
	ui_uia_variant_clear(&new_value[0])
	ui_uia_variant_text(&old_value[0], was)
	ui_uia_variant_text(&new_value[0], now)
	ui_uia_raise_property(b, id, property, &old_value[0], &new_value[0])
	SysFreeString(load_int64(&old_value[8]))
	SysFreeString(load_int64(&new_value[8]))


int ui_uia_text_same(ui_access_text* a, ui_access_text* b):
	if (a.length != b.length): return 0
	for i in range(a.length):
		if (a.data[i] != b.data[i]): return 0
	return 1


int ui_uia_children_same(ui_access_node* a, ui_access_node* b):
	ui_access_node* x = a.first_child
	ui_access_node* y = b.first_child
	while ((x != 0) && (y != 0)):
		if (x.id != y.id): return 0
		x = x.next_sibling
		y = y.next_sibling
	return (x == 0) && (y == 0)


void ui_uia_raise_children(ui_uia_bridge* b, ui_access_node* parent):
	int32[2] runtime
	runtime[0] = UiaAppendRuntimeId
	if (b.hwnd == 0): runtime[0] = GetCurrentProcessId()
	runtime[1] = parent.id
	UiaRaiseStructureChangedEvent(ui_uia_simple_of(b, parent.id), StructureChangeType_ChildrenInvalidated, &runtime[0], 2)


# MSAA WinEvent for node id of a hosted tree: OBJID_CLIENT with the
# child id -id (CHILDID_SELF for the root), which the root IAccessible
# resolves.
void ui_uia_win_event(ui_uia_bridge* b, int event, int id):
	int child = 0 - id
	if (id == b.published.root.id): child = CHILDID_SELF
	NotifyWinEvent(event, b.hwnd, OBJID_CLIENT, child)


# MSAA state bits that changed, focus aside (announced on its own).
int ui_uia_msaa_state_changed(ui_uia_bridge* b, ui_access_node* n, ui_access_node* was):
	int mask = 0 - 1 - STATE_SYSTEM_FOCUSED
	return (ui_msaa_state(b, n) & mask) != (ui_msaa_state(b, was) & mask)


# Announce what changed from old to fresh (fresh is already published):
# UIA property and structure events for elements clients have seen and
# ElementSelected and focus events, when a UIA client listens; the
# matching MSAA WinEvents (name, value, state, reorder, selection and
# focus) for a tree hosted by a window.
void ui_uia_raise_changes(ui_uia_bridge* b, ui_access_tree* old, ui_access_tree* fresh):
	if (old == 0): return
	int uia = (UiaClientsAreListening() & 255) != 0
	int msaa = b.hwnd != 0
	if (!uia && !msaa): return
	for int id in fresh.nodes:
		ui_access_node* n = fresh.nodes[id]
		ui_access_node* was = ui_access_find(old, id)
		if (was == 0): continue
		int seen = uia && (id in b.elements)
		int name_changed = !ui_uia_text_same(&n.name, &was.name)
		int value_changed = !ui_uia_text_same(&n.value, &was.value)
		int selected = ui_uia_supports(b, n, UI_UIA_SELECTION_ITEM) && (ui_uia_selected(n) != ui_uia_selected(was))
		if seen:
			if name_changed: ui_uia_raise_text(b, id, UIA_NamePropertyId, &was.name, &n.name)
			if (ui_uia_supports(b, n, UI_UIA_VALUE) && value_changed): ui_uia_raise_text(b, id, UIA_ValueValuePropertyId, &was.value, &n.value)
			if (ui_uia_supports(b, n, UI_UIA_TOGGLE) && (ui_uia_checked(n) != ui_uia_checked(was))): ui_uia_raise_i4(b, id, UIA_ToggleToggleStatePropertyId, ui_uia_checked(was), ui_uia_checked(n))
			if selected: ui_uia_raise_bool(b, id, UIA_SelectionItemIsSelectedPropertyId, ui_uia_selected(was), ui_uia_selected(n))
			if (ui_uia_supports(b, n, UI_UIA_EXPAND) && (ui_uia_expanded(n) != ui_uia_expanded(was))): ui_uia_raise_i4(b, id, UIA_ExpandCollapseExpandCollapseStatePropertyId, ui_uia_expanded(was), ui_uia_expanded(n))
			if (ui_access_inert(n) != ui_access_inert(was)): ui_uia_raise_bool(b, id, UIA_IsEnabledPropertyId, ui_access_inert(was) == 0, ui_access_inert(n) == 0)
			if (!ui_uia_children_same(n, was)): ui_uia_raise_children(b, n)
		# The selection moved to n: the event a screen reader announces.
		if (uia && selected && ui_uia_selected(n)): UiaRaiseAutomationEvent(ui_uia_simple_of(b, id), UIA_SelectionItem_ElementSelectedEventId)
		if msaa:
			if name_changed: ui_uia_win_event(b, EVENT_OBJECT_NAMECHANGE, id)
			if value_changed: ui_uia_win_event(b, EVENT_OBJECT_VALUECHANGE, id)
			if (ui_uia_msaa_state_changed(b, n, was)): ui_uia_win_event(b, EVENT_OBJECT_STATECHANGE, id)
			if (!ui_uia_children_same(n, was)): ui_uia_win_event(b, EVENT_OBJECT_REORDER, id)
			if (selected && ui_uia_selected(n)): ui_uia_win_event(b, EVENT_OBJECT_SELECTION, id)
	if ((fresh.focused_id != old.focused_id) && (fresh.focused_id != 0)):
		ui_access_node* f = ui_access_find(fresh, fresh.focused_id)
		if ((f != 0) && (f != fresh.root) && !ui_access_inert(f)):
			if uia: UiaRaiseAutomationEvent(ui_uia_simple_of(b, f.id), UIA_AutomationFocusChangedEventId)
			if msaa: ui_uia_win_event(b, EVENT_OBJECT_FOCUS, f.id)


# Elements whose node is gone stop answering; clients holding them are
# disconnected, unreferenced ones are freed.
void ui_uia_retire(ui_uia_bridge* b, ui_access_tree* fresh):
	list[int] gone = new list[int]
	for int id in b.elements:
		if ((fresh == 0) || (ui_access_find(fresh, id) == 0)): gone.push(id)
	for i in range(gone.length):
		int id = gone[i]
		ui_uia_element* e = b.elements[id]
		b.elements.remove(id)
		e.dead = 1
		if (e.refs > 0): UiaDisconnectProvider(ui_uia_iface_ptr(e, UI_UIA_SIMPLE))
		if (e.refs == 0): free(e)
	list_free[int](gone)


/* Public API. */

# Bridge for the window hwnd (0: a tree hosted nowhere, for tests and
# embedding; set its screen origin with ui_access_uia_set_origin).
# Initialises COM on this thread as a single-threaded apartment.
ui_uia_bridge* ui_access_uia_open(int hwnd):
	ui_uia_init()
	CoInitializeEx(0, 2)        /* COINIT_APARTMENTTHREADED; S_FALSE when already */
	ui_uia_bridge* b = new ui_uia_bridge()
	b.hwnd = hwnd
	b.published = 0
	b.elements = new map[int, ui_uia_element*]
	b.options = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading
	b.origin_x = 0
	b.origin_y = 0
	b.queued = 0
	ui_uia_active = b
	return b


void ui_access_uia_set_origin(ui_uia_bridge* b, int x, int y):
	if (b == 0): return
	b.origin_x = x
	b.origin_y = y


# The root provider (IRawElementProviderSimple*, AddRef'd), 0 before the
# first publication. UIA clients normally reach it via WM_GETOBJECT.
int ui_access_uia_root(ui_uia_bridge* b):
	if ((b == 0) || (b.published == 0) || (b.published.root == 0)): return 0
	int out = 0
	ui_uia_hand_out(b, b.published.root.id, UI_UIA_SIMPLE, cast(int, &out))
	return out


# Copy tree into the bridge and announce changes. Queued actions against
# the old snapshot are dropped. Returns 0 for an unusable tree.
int ui_access_uia_publish(ui_uia_bridge* b, ui_access_tree* tree):
	if ((b == 0) || (tree == 0) || (tree.root == 0)): return 0
	ui_access_tree* old = b.published
	ui_access_tree* fresh = ui_access_tree_clone(tree)
	if (fresh == 0): return 0
	ui_uia_retire(b, fresh)
	b.published = fresh
	ui_uia_clear_queue(b)
	ui_uia_raise_changes(b, old, fresh)
	ui_access_tree_free(old)
	return 1


# Apply queued actions to tree through ui_access_dispatch (accepted
# focus requests also move tree.focused_id). Call once per frame after
# pumping messages, before replacing tree. Returns the number consumed.
int ui_access_uia_dispatch(ui_uia_bridge* b, ui_access_tree* tree):
	if (b == 0): return 0
	int count = b.queued
	for i in range(b.queued):
		ui_uia_request* r = &b.queue[i]
		if (tree != 0):
			int accepted = ui_access_dispatch(tree, r.id, r.action, r.value, r.length)
			if (accepted && (r.action == UI_ACCESS_FOCUS)): tree.focused_id = r.id
	ui_uia_clear_queue(b)
	return count


# WM_GETOBJECT for b's window: the UIA root for UiaRootObjectId, the
# root's IAccessible for OBJID_CLIENT (LresultFromObject), else 0 (pass
# the message to DefWindowProc).
int ui_access_uia_getobject(ui_uia_bridge* b, int hwnd, int wparam, int lparam):
	if ((b == 0) || (b.published == 0) || (b.published.root == 0)): return 0
	int object_id = ui_uia_lo32(lparam)
	ui_uia_element* e = ui_uia_element_for(b, b.published.root.id)
	if (object_id == UiaRootObjectId): return UiaReturnRawElementProvider(hwnd, wparam, lparam, ui_uia_iface_ptr(e, UI_UIA_SIMPLE))
	if (object_id != OBJID_CLIENT): return 0
	int answer = LresultFromObject(&ui_uia_iids[(UI_UIA_ACCESSIBLE + 1) * 16], wparam, ui_uia_iface_ptr(e, UI_UIA_ACCESSIBLE))
	if (answer <= 0): return 0
	return answer


# The same for the most recently opened bridge, in the shape of
# graphics.window_win32's gfx_win32_getobject hook.
int ui_access_uia_wm_getobject(int hwnd, int wparam, int lparam):
	return ui_access_uia_getobject(ui_uia_active, hwnd, wparam, lparam)


void ui_access_uia_close(ui_uia_bridge* b):
	if (b == 0): return
	# Release UIA's references to the window's providers.
	if (b.hwnd != 0): UiaReturnRawElementProvider(b.hwnd, 0, 0, 0)
	ui_uia_retire(b, 0)
	ui_uia_clear_queue(b)
	ui_access_tree_free(b.published)
	map_free[int, ui_uia_element*](b.elements)
	if (ui_uia_active == b): ui_uia_active = 0
	free(b)
