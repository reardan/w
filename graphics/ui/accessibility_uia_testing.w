/*
graphics.ui.accessibility_uia_testing: what the win64 accessibility
tests share to drive graphics.ui.accessibility_uia's COM objects as a
client does (#911, #912): calls through vtable slots with the Microsoft
x64 ABI, QueryInterface by IID slot, BSTR and SAFEARRAY checks, and a
recorder that dispatches the bridge's one queued request.
*/
import lib.lib
import lib.assert
import graphics.ui.accessibility_uia

c_lib "oleaut32.dll"
extern int SafeArrayGetElement(int array, int32* index, char* value)
extern int SafeArrayGetUBound(int array, int dim, int32* bound)
extern int VariantClear(char* value)

c_lib "ole32.dll"
extern void CoTaskMemFree(int p)


type uiat_m1 = fn(int) -> int
type uiat_m2 = fn(int, int) -> int
type uiat_m3 = fn(int, int, int) -> int
type uiat_m4 = fn(int, int, int, int) -> int
type uiat_m5 = fn(int, int, int, int, int) -> int
type uiat_m6 = fn(int, int, int, int, int, int) -> int
type uiat_m7 = fn(int, int, int, int, int, int, int) -> int


int uiat_hr(int v):
	return (v << 32) >> 32


int uiat_method(int object, int slot, int nargs):
	int vtbl = load_int64(cast(char*, object))
	return win_c_function(load_int64(cast(char*, vtbl + slot * 8)), nargs, 1)


int uiat_call1(int object, int slot):
	uiat_m1* f = cast(uiat_m1*, uiat_method(object, slot, 1))
	return uiat_hr(f(object))


int uiat_call2(int object, int slot, int a):
	uiat_m2* f = cast(uiat_m2*, uiat_method(object, slot, 2))
	return uiat_hr(f(object, a))


int uiat_call3(int object, int slot, int a, int b):
	uiat_m3* f = cast(uiat_m3*, uiat_method(object, slot, 3))
	return uiat_hr(f(object, a, b))


int uiat_call4(int object, int slot, int a, int b, int c):
	uiat_m4* f = cast(uiat_m4*, uiat_method(object, slot, 4))
	return uiat_hr(f(object, a, b, c))


int uiat_call5(int object, int slot, int a, int b, int c, int d):
	uiat_m5* f = cast(uiat_m5*, uiat_method(object, slot, 5))
	return uiat_hr(f(object, a, b, c, d))


int uiat_call6(int object, int slot, int a, int b, int c, int d, int e):
	uiat_m6* f = cast(uiat_m6*, uiat_method(object, slot, 6))
	return uiat_hr(f(object, a, b, c, d, e))


int uiat_call7(int object, int slot, int a, int b, int c, int d, int e, int g):
	uiat_m7* f = cast(uiat_m7*, uiat_method(object, slot, 7))
	return uiat_hr(f(object, a, b, c, d, e, g))


void uiat_release(int object):
	if (object != 0): uiat_call1(object, 2)


char* uiat_iid(int slot):
	return &ui_uia_iids[slot * 16]


# QueryInterface for the IID in slot; 0 when refused.
int uiat_query(int object, int slot):
	int out = 0
	if (uiat_call3(object, 0, cast(int, uiat_iid(slot)), cast(int, &out)) != 0): return 0
	return out


# A 32-bit getter (slot) that must succeed.
int uiat_get32(int object, int slot):
	int32[1] out
	out[0] = 0 - 7
	assert_equal(0, uiat_call2(object, slot, cast(int, &out[0])))
	return out[0]


# A pointer getter (slot); its HRESULT must be expect.
int uiat_get_ptr(int object, int slot, int expect):
	int out = 0
	assert_equal(expect, uiat_call2(object, slot, cast(int, &out)))
	return out


void uiat_assert_bstr(char* expect, int bstr):
	asserts(c"BSTR present", bstr != 0)
	int length = 0
	char* text = ui_uia_utf8(bstr, &length)
	if (length != strlen(expect)):
		write(1, c"got: ", strlen(c"got: "))
		write(1, text, length)
		write(1, c"\n", strlen(c"\n"))
	assert_equal(strlen(expect), length)
	assert_bytes_equal(expect, text, length)
	free(text)


# A BSTR getter (slot) answering expect; the BSTR is freed.
void uiat_assert_text(int object, int slot, char* expect):
	int bstr = 0
	assert_equal(0, uiat_call2(object, slot, cast(int, &bstr)))
	uiat_assert_bstr(expect, bstr)
	SysFreeString(bstr)


# A provider's AutomationId (Simple slot 5) as a number.
int uiat_automation_id(int simple):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, uiat_call3(simple, 5, UIA_AutomationIdPropertyId, cast(int, &v[0])))
	assert_equal(VT_BSTR, load_int16(&v[0]) & 65535)
	int length = 0
	char* text = ui_uia_utf8(load_int64(&v[8]), &length)
	int id = atoi(text)
	free(text)
	VariantClear(&v[0])
	return id


# The IAccessible2 unique id (-node id) of an object's IAccessible2,
# which is released.
int uiat_unique_of(int object):
	int ia2 = uiat_query(object, ui_uia_kind_slot(UI_UIA_IA2))
	asserts(c"IAccessible2", ia2 != 0)
	int id = uiat_get32(ia2, 41)
	uiat_release(ia2)
	uiat_release(object)
	return id


# The node ids (-unique id) of a CoTaskMemAlloc'd array of count
# IUnknowns, which is freed with its references.
list[int] uiat_object_ids(int array, int count):
	list[int] ids = new list[int]
	for i in range(count): ids.push(0 - uiat_unique_of(load_int64(cast(char*, array + i * 8))))
	if (array != 0): CoTaskMemFree(array)
	return ids


# The AutomationIds of a SAFEARRAY of VT_UNKNOWN providers (destroyed).
list[int] uiat_array_ids(int array):
	list[int] ids = new list[int]
	if (array == 0): return ids
	int32[1] bound
	assert_equal(0, uiat_hr(SafeArrayGetUBound(array, 1, &bound[0])))
	int32[1] index
	for i in range(bound[0] + 1):
		index[0] = i
		int unknown = 0
		assert_equal(0, uiat_hr(SafeArrayGetElement(array, &index[0], cast(char*, &unknown))))
		int simple = uiat_query(unknown, 1)
		ids.push(uiat_automation_id(simple))
		uiat_release(simple)
		uiat_release(unknown)
	SafeArrayDestroy(array)
	return ids


int uiat_array_count(int array):
	int32[1] upper
	assert_equal(0, uiat_hr(SafeArrayGetUBound(array, 1, &upper[0])))
	return upper[0] + 1


int uiat_array_unknown(int array, int index):
	int32[1] at
	at[0] = index
	int out = 0
	assert_equal(0, uiat_hr(SafeArrayGetElement(array, &at[0], cast(char*, &out))))
	return out


/* The request recorder: install uiat_record as the tree's action. */

char[256] uiat_payload
int uiat_length
int uiat_action
int uiat_id


int uiat_record(void* context, int id, int action, char* data, int length):
	uiat_id = id
	uiat_action = action
	uiat_length = length
	for i in range(length):
		if (i < 255): uiat_payload[i] = data[i]
	return 1


# Dispatch the bridge's one queued request and check it.
void uiat_expect_request(ui_uia_bridge* bridge, ui_access_tree* tree, int id, int action, char* payload):
	uiat_action = 0
	assert_equal(1, ui_access_uia_dispatch(bridge, tree))
	assert_equal(id, uiat_id)
	assert_equal(action, uiat_action)
	if (uiat_length != strlen(payload)):
		write(1, c"payload: ", strlen(c"payload: "))
		write(1, &uiat_payload[0], uiat_length)
		write(1, c"\n", strlen(c"\n"))
	assert_equal(strlen(payload), uiat_length)
	assert_bytes_equal(payload, &uiat_payload[0], uiat_length)


void uiat_expect_nothing(ui_uia_bridge* bridge, ui_access_tree* tree):
	assert_equal(0, ui_access_uia_dispatch(bridge, tree))


void uiat_text(ui_access_tree* tree, int id, int field, char* text):
	assert_equal(1, ui_access_set_text(tree, id, field, text, strlen(text)))


# The Simple provider of node id under fragment, depth first.
int uiat_find_under(int fragment, int id):
	int child = 0
	assert_equal(0, uiat_call3(fragment, 3, NavigateDirection_FirstChild, cast(int, &child)))
	while (child != 0):
		int simple = uiat_query(child, 1)
		if (uiat_automation_id(simple) == id):
			uiat_release(child)
			return simple
		uiat_release(simple)
		int deeper = uiat_find_under(child, id)
		if (deeper != 0):
			uiat_release(child)
			return deeper
		int next = 0
		assert_equal(0, uiat_call3(child, 3, NavigateDirection_NextSibling, cast(int, &next)))
		uiat_release(child)
		child = next
	return 0


# The Simple provider of node id under root.
int uiat_find(int root, int id):
	int fragment = uiat_query(root, 2)
	int found = uiat_find_under(fragment, id)
	uiat_release(fragment)
	return found


# The IAccessible2 of node id (through its IAccessible's
# IServiceProvider, as screen readers reach it).
int uiat_ia2_of(int root, int id):
	int simple = uiat_find(root, id)
	asserts(c"node found", simple != 0)
	int acc = uiat_query(simple, UI_UIA_ACCESSIBLE + 1)
	int service = uiat_query(acc, ui_uia_kind_slot(UI_UIA_SERVICE))
	int ia2 = 0
	assert_equal(0, uiat_call4(service, 3, cast(int, uiat_iid(ui_uia_kind_slot(UI_UIA_ACCESSIBLE))), cast(int, uiat_iid(ui_uia_kind_slot(UI_UIA_IA2))), cast(int, &ia2)))
	uiat_release(service)
	uiat_release(acc)
	uiat_release(simple)
	return ia2
