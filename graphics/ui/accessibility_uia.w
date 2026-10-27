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
SelectionItem (tabs, list items, rows, radio buttons), ExpandCollapse
(comboboxes and expanded nodes), RangeValue (progress, read-only) and
Text (textboxes: the caret and selection as ITextRangeProvider ranges,
separate COM objects counting characters (code points) of the value).

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
extern int UiaGetReservedNotSupportedValue(int* value)

c_lib "oleaut32.dll"
extern int SysAllocStringLen(char* text, int length)
extern void SysFreeString(int bstr)
extern int SafeArrayCreateVector(int vt, int lower_bound, int count)
extern int SafeArrayPutElement(int array, int32* index, char* value)

c_lib "ole32.dll"
extern int CoInitializeEx(int reserved, int flags)

c_lib "user32.dll"
extern int ClientToScreen(int hwnd, int32* point)


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
const int UI_UIA_TEXT = 9
const int UI_UIA_IFACES = 10
# The iid slot of ITextRangeProvider (after IUnknown and the kinds).
const int UI_UIA_TEXT_RANGE_IID = 11

# Control pattern ids (UIA_*PatternId).
const int UIA_InvokePatternId = 10000
const int UIA_ValuePatternId = 10002
const int UIA_RangeValuePatternId = 10003
const int UIA_ExpandCollapsePatternId = 10005
const int UIA_SelectionItemPatternId = 10010
const int UIA_TextPatternId = 10014
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
const int UIA_ExpandCollapseExpandCollapseStatePropertyId = 30070
const int UIA_SelectionItemIsSelectedPropertyId = 30079
const int UIA_ToggleToggleStatePropertyId = 30086
const int UIA_FullDescriptionPropertyId = 30159
const int UIA_HeadingLevelPropertyId = 30173
const int UIA_IsDialogPropertyId = 30174
const int HeadingLevel_None = 80050

# Text attribute ids (UIA_*AttributeId), TextUnit,
# TextPatternRangeEndpoint and SupportedTextSelection.
const int UIA_IsReadOnlyAttributeId = 40015
const int TextUnit_Character = 0
const int TextUnit_Format = 1
const int TextUnit_Word = 2
const int TextUnit_Line = 3
const int TextUnit_Paragraph = 4
const int TextUnit_Page = 5
const int TextUnit_Document = 6
const int TextPatternRangeEndpoint_Start = 0
const int TextPatternRangeEndpoint_End = 1
const int SupportedTextSelection_Single = 1

# Event ids (UIA_*EventId) and StructureChangeType.
const int UIA_StructureChangedEventId = 20002
const int UIA_AutomationFocusChangedEventId = 20005
const int UIA_Text_TextSelectionChangedEventId = 20014
const int UIA_Text_TextChangedEventId = 20015
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
const int VT_R8 = 5
const int VT_BSTR = 8
const int VT_BOOL = 11
const int VT_UNKNOWN = 13


struct ui_uia_iface:
	int vtbl
	int element                 # the ui_uia_element this interface belongs to


struct ui_uia_element:
	ui_uia_iface[10] ifaces
	int refs                    # COM references held by clients
	int id
	int dead                    # the node is gone (or the bridge closed)
	int bridge                  # ui_uia_bridge*, valid while !dead


# An ITextRangeProvider: its own COM object, holding one reference to
# its element. Endpoints count characters (code points) of the node's
# value and are clamped to the current text on every call.
struct ui_uia_text_range:
	int vtbl
	int element                 # ui_uia_element*
	int start
	int end
	int refs


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

int[10] ui_uia_vtables
int ui_uia_range_vtable         # ITextRangeProvider
char[192] ui_uia_iids           # IUnknown, one IID per interface kind, ITextRangeProvider
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
	if (r == UI_ACCESS_ROW): return UIA_DataItemControlTypeId
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
	if (kind == UI_UIA_SELECTION_ITEM): return (r == UI_ACCESS_TAB) || (r == UI_ACCESS_LIST_ITEM) || (r == UI_ACCESS_ROW) || (r == UI_ACCESS_RADIO)
	if (kind == UI_UIA_EXPAND):
		if (r == UI_ACCESS_COMBOBOX): return 1
		return ((n.states & UI_ACCESS_EXPANDED) != 0) && ((n.actions & UI_ACCESS_ACTIVATE) != 0)
	if (kind == UI_UIA_RANGE): return r == UI_ACCESS_PROGRESS
	if (kind == UI_UIA_TEXT): return r == UI_ACCESS_TEXTBOX
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
	if (pattern == UIA_TextPatternId): return UI_UIA_TEXT
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
	if (n.parent == 0): return UIA_S_OK
	return ui_uia_hand_out(ui_uia_bridge_of(e), n.parent.id, UI_UIA_SIMPLE, out)


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


/* Text pattern: ITextProvider on textboxes, and its ranges. */

int ui_uia_space(int c):
	return (c == 32) || (c == 9) || (c == 10) || (c == 13)


# The node's value as code points (count of them in *count); the caller
# frees the array.
int* ui_uia_codes(ui_access_node* n, int* count):
	int total = ui_access_char_count(n.value.data, n.value.length)
	int* cp = cast(int*, malloc(total * 8 + 8))
	int i = 0
	int k = 0
	while ((i < n.value.length) && (k < total)):
		int c = 0
		int used = utf8_scan(&n.value.data[i], n.value.length - i, &c)
		if (used <= 0):
			c = 65533
			used = 1
		cp[k] = c
		k = k + 1
		i = i + used
	count[0] = k
	return cp


# The units this provider distinguishes: Paragraph is Line (a field has
# no paragraph styling); Format and Page are the whole document (one
# uniform run, one page).
int ui_uia_unit(int unit):
	int u = ui_uia_lo32(unit)
	if (u == TextUnit_Paragraph): return TextUnit_Line
	if ((u == TextUnit_Character) || (u == TextUnit_Word) || (u == TextUnit_Line)): return u
	return TextUnit_Document


# 1 when a unit starts at character p. A word is a run of non-space
# characters with the spaces after it; a line ends after its newline.
int ui_uia_boundary(int* cp, int count, int unit, int p):
	if ((p <= 0) || (p >= count)): return 1
	if (unit == TextUnit_Character): return 1
	if (unit == TextUnit_Document): return 0
	if (cp[p - 1] == 10): return 1
	if (unit == TextUnit_Line): return 0
	return ui_uia_space(cp[p - 1]) && !ui_uia_space(cp[p])


int ui_uia_next_boundary(int* cp, int count, int unit, int p):
	if (p >= count): return count
	int q = p + 1
	while ((q < count) && !ui_uia_boundary(cp, count, unit, q)): q = q + 1
	return q


int ui_uia_prev_boundary(int* cp, int count, int unit, int p):
	if (p <= 0): return 0
	int q = p - 1
	while ((q > 0) && !ui_uia_boundary(cp, count, unit, q)): q = q - 1
	return q


int ui_uia_floor_boundary(int* cp, int count, int unit, int p):
	if (ui_uia_boundary(cp, count, unit, p)): return p
	return ui_uia_prev_boundary(cp, count, unit, p)


int ui_uia_text_range_new(ui_uia_element* e, int start, int end):
	ui_uia_text_range* r = new ui_uia_text_range()
	r.vtbl = ui_uia_range_vtable
	r.element = cast(int, e)
	e.refs = e.refs + 1
	r.start = start
	r.end = end
	r.refs = 1
	return cast(int, r)


# A range argument from a client: one of ours, else 0.
ui_uia_text_range* ui_uia_range_arg(int p):
	if (p == 0): return 0
	if (load_int64(cast(char*, p)) != ui_uia_range_vtable): return 0
	return cast(ui_uia_text_range*, p)


# The range's node with its endpoints clamped to the current text, or 0
# once the element is gone.
ui_access_node* ui_uia_range_node(ui_uia_text_range* r):
	ui_access_node* n = ui_uia_node(cast(ui_uia_element*, r.element))
	if (n == 0): return 0
	int count = ui_access_char_count(n.value.data, n.value.length)
	if (r.start < 0): r.start = 0
	if (r.end > count): r.end = count
	if (r.start > count): r.start = count
	if (r.end < r.start): r.end = r.start
	return n


int ui_uia_range_query(int self, int riid, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	if (riid == 0): return UIA_E_INVALIDARG
	if (!ui_uia_guid_is(riid, 0) && !ui_uia_guid_is(riid, UI_UIA_TEXT_RANGE_IID)): return UIA_E_NOINTERFACE
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	r.refs = r.refs + 1
	save_int64(cast(char*, out), self)
	return UIA_S_OK


int ui_uia_range_add_ref(int self):
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	r.refs = r.refs + 1
	return r.refs


# The last reference frees the range and drops its element reference.
int ui_uia_range_release(int self):
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	if (r.refs > 0): r.refs = r.refs - 1
	int left = r.refs
	if (left == 0):
		ui_uia_element* e = cast(ui_uia_element*, r.element)
		ui_uia_release(ui_uia_iface_ptr(e, UI_UIA_SIMPLE))
		free(r)
	return left


# Store range in a VT_UNKNOWN SAFEARRAY (which takes its own reference;
# ours is released).
void ui_uia_put_range(int array, int index, int range):
	int32[1] at
	at[0] = index
	SafeArrayPutElement(array, &at[0], cast(char*, range))
	ui_uia_range_release(range)


# ITextProvider::GetSelection: the caret, or the selection with the
# caret at one end, as one range; none when the node shows no caret.
int ui_uia_text_selection(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int count = 0
	if (n.caret >= 0): count = 1
	int array = SafeArrayCreateVector(VT_UNKNOWN, 0, count)
	if (array == 0): return UIA_E_INVALIDARG
	if (count == 1):
		int start = n.selection_start
		int end = n.selection_end
		if ((start < 0) || (end < start)):
			start = n.caret
			end = n.caret
		ui_uia_put_range(array, 0, ui_uia_text_range_new(e, start, end))
	save_int64(cast(char*, out), array)
	return UIA_S_OK


# GetVisibleRanges: the whole text (the bridge knows no scroll state).
int ui_uia_text_visible(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int array = SafeArrayCreateVector(VT_UNKNOWN, 0, 1)
	if (array == 0): return UIA_E_INVALIDARG
	ui_uia_put_range(array, 0, ui_uia_text_range_new(e, 0, ui_access_char_count(n.value.data, n.value.length)))
	save_int64(cast(char*, out), array)
	return UIA_S_OK


# RangeFromChild: a textbox has no embedded children.
int ui_uia_text_from_child(int self, int child, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	if (ui_uia_node(ui_uia_self(self)) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	return UIA_E_INVALIDARG


# RangeFromPoint (the 16-byte UiaPoint arrives by reference): a
# degenerate range, placed proportionally along the field's width since
# the snapshot has no glyph geometry; above or left of the field is its
# start, below or right of it its end.
int ui_uia_text_from_point(int self, int point, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	if (point == 0): return UIA_E_INVALIDARG
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	float64* xy = cast(float64*, point)
	int ox = 0
	int oy = 0
	ui_uia_origin(ui_uia_bridge_of(e), &ox, &oy)
	float64 x = xy[0] - cast(float64, ox) - cast(float64, n.bounds.x)
	float64 y = xy[1] - cast(float64, oy) - cast(float64, n.bounds.y)
	float64 w = cast(float64, n.bounds.w)
	int count = ui_access_char_count(n.value.data, n.value.length)
	int at = 0
	if ((y >= cast(float64, n.bounds.h)) || (x >= w)): at = count
	else if ((y >= 0.0) && (x > 0.0) && (w > 0.0)): at = cast(int, x / w * cast(float64, count) + 0.5)
	if (at > count): at = count
	save_int64(cast(char*, out), ui_uia_text_range_new(e, at, at))
	return UIA_S_OK


int ui_uia_text_document(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_element* e = ui_uia_self(self)
	ui_access_node* n = ui_uia_node(e)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	save_int64(cast(char*, out), ui_uia_text_range_new(e, 0, ui_access_char_count(n.value.data, n.value.length)))
	return UIA_S_OK


int ui_uia_text_supported_selection(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	if (ui_uia_node(ui_uia_self(self)) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	save_int32(cast(char*, out), SupportedTextSelection_Single)
	return UIA_S_OK


/* ITextRangeProvider. */

int ui_uia_range_clone(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	if (ui_uia_range_node(r) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	save_int64(cast(char*, out), ui_uia_text_range_new(cast(ui_uia_element*, r.element), r.start, r.end))
	return UIA_S_OK


int ui_uia_range_compare(int self, int other, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	ui_uia_text_range* t = ui_uia_range_arg(other)
	if (ui_uia_range_node(r) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if (t == 0): return UIA_E_INVALIDARG
	if (ui_uia_range_node(t) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	save_int32(cast(char*, out), (t.element == r.element) && (t.start == r.start) && (t.end == r.end))
	return UIA_S_OK


int ui_uia_range_endpoint(ui_uia_text_range* r, int endpoint):
	if (ui_uia_lo32(endpoint) == TextPatternRangeEndpoint_Start): return r.start
	return r.end


# Move one endpoint to character p; the other follows when they cross.
void ui_uia_range_set_endpoint(ui_uia_text_range* r, int endpoint, int p):
	if (ui_uia_lo32(endpoint) == TextPatternRangeEndpoint_Start):
		r.start = p
		if (r.end < p): r.end = p
	else:
		r.end = p
		if (r.start > p): r.start = p


# CompareEndpoints: negative, zero or positive as this range's endpoint
# lies before, at or after the target's.
int ui_uia_range_compare_endpoints(int self, int endpoint, int other, int other_endpoint, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	ui_uia_text_range* t = ui_uia_range_arg(other)
	if (ui_uia_range_node(r) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if ((t == 0) || (t.element != r.element)): return UIA_E_INVALIDARG
	ui_uia_range_node(t)
	save_int32(cast(char*, out), ui_uia_range_endpoint(r, endpoint) - ui_uia_range_endpoint(t, other_endpoint))
	return UIA_S_OK


# ExpandToEnclosingUnit: the unit containing the start (the last unit
# for a range at the end of the text).
int ui_uia_range_expand(int self, int unit):
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	ui_access_node* n = ui_uia_range_node(r)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int count = 0
	int* cp = ui_uia_codes(n, &count)
	int u = ui_uia_unit(unit)
	int start = r.start
	if ((start >= count) && (count > 0)): start = ui_uia_prev_boundary(cp, count, u, count)
	start = ui_uia_floor_boundary(cp, count, u, start)
	r.start = start
	r.end = ui_uia_next_boundary(cp, count, u, start)
	free(cast(char*, cp))
	return UIA_S_OK


# FindAttribute: the text has uniform (unreported) formatting, so no
# run is ever found.
int ui_uia_range_find_attribute(int self, int attribute, int value, int backward, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	if (ui_uia_range_node(cast(ui_uia_text_range*, self)) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	return UIA_S_OK


int ui_uia_fold(int c, int ignore_case):
	if (ignore_case && (c >= 'A') && (c <= 'Z')): return c + 32
	return c


# FindText: the first (or last, backward) occurrence inside the range,
# with ASCII case folding when asked; no match is a null range.
int ui_uia_range_find_text(int self, int text, int backward, int ignore_case, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	ui_access_node* n = ui_uia_range_node(r)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if (text == 0): return UIA_E_INVALIDARG
	ui_access_node probe
	probe.value.length = 0
	probe.value.data = ui_uia_utf8(text, &probe.value.length)
	int needle_count = 0
	int* needle = ui_uia_codes(&probe, &needle_count)
	int count = 0
	int* cp = ui_uia_codes(n, &count)
	int fold = ui_uia_lo32(ignore_case) != 0
	int found = 0 - 1
	if (needle_count > 0):
		int at = r.start
		while (at + needle_count <= r.end):
			int same = 1
			for k in range(needle_count):
				if (ui_uia_fold(cp[at + k], fold) != ui_uia_fold(needle[k], fold)): same = 0
			if same:
				found = at
				if (ui_uia_lo32(backward) == 0): break
			at = at + 1
	if (found >= 0): save_int64(cast(char*, out), ui_uia_text_range_new(cast(ui_uia_element*, r.element), found, found + needle_count))
	free(cast(char*, cp))
	free(cast(char*, needle))
	free(probe.value.data)
	return UIA_S_OK


# GetAttributeValue: IsReadOnly; every other attribute answers the
# reserved not-supported value.
int ui_uia_range_attribute(int self, int attribute, int out):
	if (out == 0): return UIA_E_POINTER
	char* v = cast(char*, out)
	ui_uia_variant_clear(v)
	ui_access_node* n = ui_uia_range_node(cast(ui_uia_text_range*, self))
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if (ui_uia_lo32(attribute) == UIA_IsReadOnlyAttributeId):
		ui_uia_variant_bool(v, ((n.states & UI_ACCESS_READONLY) != 0) || ((n.actions & UI_ACCESS_SET_VALUE) == 0) || ui_access_inert(n))
		return UIA_S_OK
	int unsupported = 0
	UiaGetReservedNotSupportedValue(&unsupported)
	save_int16(v, VT_UNKNOWN)
	save_int64(&v[8], unsupported)
	return UIA_S_OK


# GetBoundingRectangles: the field's screen rectangle (no glyph
# geometry) as [left, top, width, height] doubles; none when hidden.
int ui_uia_range_rectangles(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	ui_access_node* n = ui_uia_range_node(r)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int shown = ui_uia_hidden(n) == 0
	int array = SafeArrayCreateVector(VT_R8, 0, 4 * shown)
	if (array == 0): return UIA_E_INVALIDARG
	if shown:
		int ox = 0
		int oy = 0
		ui_uia_origin(ui_uia_bridge_of(cast(ui_uia_element*, r.element)), &ox, &oy)
		float64[4] rect
		rect[0] = cast(float64, n.bounds.x) + cast(float64, ox)
		rect[1] = cast(float64, n.bounds.y) + cast(float64, oy)
		rect[2] = cast(float64, n.bounds.w)
		rect[3] = cast(float64, n.bounds.h)
		int32[1] at
		for i in range(4):
			at[0] = i
			SafeArrayPutElement(array, &at[0], cast(char*, &rect[i]))
	save_int64(cast(char*, out), array)
	return UIA_S_OK


int ui_uia_range_enclosing(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	if (ui_uia_range_node(r) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	ui_uia_element* e = cast(ui_uia_element*, r.element)
	return ui_uia_hand_out(ui_uia_bridge_of(e), e.id, UI_UIA_SIMPLE, out)


# GetText: at most max_length characters (-1: all) of the range.
int ui_uia_range_text(int self, int max_length, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	ui_access_node* n = ui_uia_range_node(r)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int limit = ui_uia_lo32(max_length)
	if (limit < (0 - 1)): return UIA_E_INVALIDARG
	int end = r.end
	if ((limit >= 0) && (r.start + limit < end)): end = r.start + limit
	int from = ui_access_char_byte(n.value.data, n.value.length, r.start)
	int to = ui_access_char_byte(n.value.data, n.value.length, end)
	save_int64(cast(char*, out), ui_uia_bstr(&n.value.data[from], to - from))
	return UIA_S_OK


# Move: a degenerate range moves its position by count units; any other
# range becomes the whole unit count units away from the one at its
# start. Writes the number of units actually moved.
int ui_uia_range_move(int self, int unit, int count, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	ui_access_node* n = ui_uia_range_node(r)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int want = ui_uia_lo32(count)
	if (want == 0): return UIA_S_OK
	int total = 0
	int* cp = ui_uia_codes(n, &total)
	int u = ui_uia_unit(unit)
	int degenerate = r.start == r.end
	int p = r.start
	if (!degenerate):
		if ((p >= total) && (total > 0)): p = ui_uia_prev_boundary(cp, total, u, total)
		p = ui_uia_floor_boundary(cp, total, u, p)
	int moved = 0
	while ((moved < want) && (p < total)):
		int q = ui_uia_next_boundary(cp, total, u, p)
		# A whole unit has to follow a non-degenerate range's new start.
		if (!degenerate && (q >= total)): break
		p = q
		moved = moved + 1
	while ((moved > want) && (p > 0)):
		p = ui_uia_prev_boundary(cp, total, u, p)
		moved = moved - 1
	r.start = p
	r.end = p
	if (!degenerate): r.end = ui_uia_next_boundary(cp, total, u, p)
	free(cast(char*, cp))
	save_int32(cast(char*, out), moved)
	return UIA_S_OK


int ui_uia_range_move_endpoint(int self, int endpoint, int unit, int count, int out):
	if (out == 0): return UIA_E_POINTER
	save_int32(cast(char*, out), 0)
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	ui_access_node* n = ui_uia_range_node(r)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int want = ui_uia_lo32(count)
	int total = 0
	int* cp = ui_uia_codes(n, &total)
	int u = ui_uia_unit(unit)
	int p = ui_uia_range_endpoint(r, endpoint)
	int moved = 0
	while ((moved < want) && (p < total)):
		p = ui_uia_next_boundary(cp, total, u, p)
		moved = moved + 1
	while ((moved > want) && (p > 0)):
		p = ui_uia_prev_boundary(cp, total, u, p)
		moved = moved - 1
	ui_uia_range_set_endpoint(r, endpoint, p)
	free(cast(char*, cp))
	save_int32(cast(char*, out), moved)
	return UIA_S_OK


int ui_uia_range_move_to_range(int self, int endpoint, int other, int other_endpoint):
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	ui_uia_text_range* t = ui_uia_range_arg(other)
	if (ui_uia_range_node(r) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	if ((t == 0) || (t.element != r.element)): return UIA_E_INVALIDARG
	ui_uia_range_node(t)
	ui_uia_range_set_endpoint(r, endpoint, ui_uia_range_endpoint(t, other_endpoint))
	return UIA_S_OK


# Select: queue a SET_SELECTION of the range with the caret at its end,
# revalidated by ui_access_uia_dispatch like every other action.
int ui_uia_range_select(int self):
	ui_uia_text_range* r = cast(ui_uia_text_range*, self)
	ui_access_node* n = ui_uia_range_node(r)
	if (n == 0): return UIA_E_ELEMENTNOTAVAILABLE
	char[32] payload
	int length = ui_access_selection_format(&payload[0], r.start, r.end)
	ui_uia_element* e = cast(ui_uia_element*, r.element)
	if (ui_uia_enqueue(ui_uia_bridge_of(e), n, UI_ACCESS_SET_SELECTION, &payload[0], length)): return UIA_S_OK
	return UIA_E_ELEMENTNOTENABLED


# AddToSelection / RemoveFromSelection: a single-selection field cannot
# hold further ranges.
int ui_uia_range_add_selection(int self):
	if (ui_uia_range_node(cast(ui_uia_text_range*, self)) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	return UIA_E_INVALIDOPERATION


int ui_uia_range_scroll(int self, int align_to_top):
	if (ui_uia_range_node(cast(ui_uia_text_range*, self)) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	return UIA_S_OK


int ui_uia_range_children(int self, int out):
	if (out == 0): return UIA_E_POINTER
	save_int64(cast(char*, out), 0)
	if (ui_uia_range_node(cast(ui_uia_text_range*, self)) == 0): return UIA_E_ELEMENTNOTAVAILABLE
	int array = SafeArrayCreateVector(VT_UNKNOWN, 0, 0)
	if (array == 0): return UIA_E_INVALIDARG
	save_int64(cast(char*, out), array)
	return UIA_S_OK


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
	# ITextProvider                {3589c92c-63f3-4367-99bb-ada653b77cf2}
	ui_uia_guid(10, cast(int, 0x3589c92c), 0x63f3, 0x4367, 0x99, 0xbb, 0xad, 0xa6, 0x53, 0xb7, 0x7c, 0xf2)
	# ITextRangeProvider           {5347ad7b-c355-46f8-aff5-909033582f63}
	ui_uia_guid(UI_UIA_TEXT_RANGE_IID, cast(int, 0x5347ad7b), 0xc355, 0x46f8, 0xaf, 0xf5, 0x90, 0x90, 0x33, 0x58, 0x2f, 0x63)

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

	# ITextProvider, in UIAutomationCore.h's method order.
	vt = ui_uia_vtable(6)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_text_selection), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_text_visible), 2)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_text_from_child), 3)
	vt[6] = ui_uia_thunk(cast(int, ui_uia_text_from_point), 3)
	vt[7] = ui_uia_thunk(cast(int, ui_uia_text_document), 2)
	vt[8] = ui_uia_thunk(cast(int, ui_uia_text_supported_selection), 2)
	ui_uia_vtables[UI_UIA_TEXT] = cast(int, vt)

	# ITextRangeProvider, with its own IUnknown (a range is not an
	# element). VARIANT arguments (FindAttribute) arrive by reference.
	vt = cast(int*, malloc(21 * 8))
	vt[0] = ui_uia_thunk(cast(int, ui_uia_range_query), 3)
	vt[1] = ui_uia_thunk(cast(int, ui_uia_range_add_ref), 1)
	vt[2] = ui_uia_thunk(cast(int, ui_uia_range_release), 1)
	vt[3] = ui_uia_thunk(cast(int, ui_uia_range_clone), 2)
	vt[4] = ui_uia_thunk(cast(int, ui_uia_range_compare), 3)
	vt[5] = ui_uia_thunk(cast(int, ui_uia_range_compare_endpoints), 5)
	vt[6] = ui_uia_thunk(cast(int, ui_uia_range_expand), 2)
	vt[7] = ui_uia_thunk(cast(int, ui_uia_range_find_attribute), 5)
	vt[8] = ui_uia_thunk(cast(int, ui_uia_range_find_text), 5)
	vt[9] = ui_uia_thunk(cast(int, ui_uia_range_attribute), 3)
	vt[10] = ui_uia_thunk(cast(int, ui_uia_range_rectangles), 2)
	vt[11] = ui_uia_thunk(cast(int, ui_uia_range_enclosing), 2)
	vt[12] = ui_uia_thunk(cast(int, ui_uia_range_text), 3)
	vt[13] = ui_uia_thunk(cast(int, ui_uia_range_move), 4)
	vt[14] = ui_uia_thunk(cast(int, ui_uia_range_move_endpoint), 5)
	vt[15] = ui_uia_thunk(cast(int, ui_uia_range_move_to_range), 4)
	vt[16] = ui_uia_thunk(cast(int, ui_uia_range_select), 1)
	vt[17] = ui_uia_thunk(cast(int, ui_uia_range_add_selection), 1)
	vt[18] = ui_uia_thunk(cast(int, ui_uia_range_add_selection), 1)
	vt[19] = ui_uia_thunk(cast(int, ui_uia_range_scroll), 2)
	vt[20] = ui_uia_thunk(cast(int, ui_uia_range_children), 2)
	ui_uia_range_vtable = cast(int, vt)


/* Events. */

int ui_uia_simple_of(ui_uia_bridge* b, int id):
	return ui_uia_iface_ptr(ui_uia_element_for(b, id), UI_UIA_SIMPLE)


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


# Announce what changed from old to fresh (fresh is already published),
# for elements clients have seen. Only when a client listens.
void ui_uia_raise_changes(ui_uia_bridge* b, ui_access_tree* old, ui_access_tree* fresh):
	if ((old == 0) || ((UiaClientsAreListening() & 255) == 0)): return
	for int id in fresh.nodes:
		ui_access_node* n = fresh.nodes[id]
		ui_access_node* was = ui_access_find(old, id)
		if ((was == 0) || !(id in b.elements)): continue
		if (!ui_uia_text_same(&n.name, &was.name)): ui_uia_raise_text(b, id, UIA_NamePropertyId, &was.name, &n.name)
		if (ui_uia_supports(b, n, UI_UIA_VALUE) && !ui_uia_text_same(&n.value, &was.value)): ui_uia_raise_text(b, id, UIA_ValueValuePropertyId, &was.value, &n.value)
		if (ui_uia_supports(b, n, UI_UIA_TOGGLE) && (ui_uia_checked(n) != ui_uia_checked(was))): ui_uia_raise_i4(b, id, UIA_ToggleToggleStatePropertyId, ui_uia_checked(was), ui_uia_checked(n))
		if (ui_uia_supports(b, n, UI_UIA_SELECTION_ITEM) && (ui_uia_selected(n) != ui_uia_selected(was))): ui_uia_raise_bool(b, id, UIA_SelectionItemIsSelectedPropertyId, ui_uia_selected(was), ui_uia_selected(n))
		if (ui_uia_supports(b, n, UI_UIA_EXPAND) && (ui_uia_expanded(n) != ui_uia_expanded(was))): ui_uia_raise_i4(b, id, UIA_ExpandCollapseExpandCollapseStatePropertyId, ui_uia_expanded(was), ui_uia_expanded(n))
		if (ui_access_inert(n) != ui_access_inert(was)): ui_uia_raise_bool(b, id, UIA_IsEnabledPropertyId, ui_access_inert(was) == 0, ui_access_inert(n) == 0)
		if (!ui_uia_children_same(n, was)): ui_uia_raise_children(b, n)
		if (ui_uia_supports(b, n, UI_UIA_TEXT)):
			if (!ui_uia_text_same(&n.value, &was.value)): UiaRaiseAutomationEvent(ui_uia_simple_of(b, id), UIA_Text_TextChangedEventId)
			if ((n.caret != was.caret) || (n.selection_start != was.selection_start) || (n.selection_end != was.selection_end)):
				UiaRaiseAutomationEvent(ui_uia_simple_of(b, id), UIA_Text_TextSelectionChangedEventId)
	if ((fresh.focused_id != old.focused_id) && (fresh.focused_id != 0)):
		ui_access_node* f = ui_access_find(fresh, fresh.focused_id)
		if ((f != 0) && (f != fresh.root) && !ui_access_inert(f)): UiaRaiseAutomationEvent(ui_uia_simple_of(b, f.id), UIA_AutomationFocusChangedEventId)


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


# WM_GETOBJECT for b's window: the UIA root for UiaRootObjectId, else 0
# (pass the message to DefWindowProc).
int ui_access_uia_getobject(ui_uia_bridge* b, int hwnd, int wparam, int lparam):
	if ((b == 0) || (b.published == 0) || (b.published.root == 0)): return 0
	if (ui_uia_lo32(lparam) != UiaRootObjectId): return 0
	ui_uia_element* e = ui_uia_element_for(b, b.published.root.id)
	return UiaReturnRawElementProvider(hwnd, wparam, lparam, ui_uia_iface_ptr(e, UI_UIA_SIMPLE))


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
