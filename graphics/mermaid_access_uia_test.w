# wbuild: name=mermaid_canvas_uia_test arch_only=win64
# The Mermaid canvas semantics through the UI Automation bridge, under wine
# in CI (as graphics_ui_accessibility_uia_test): a frame of the editor's
# shape (headless widgets, then mm_access_canvas) is published unhosted;
# wine's uiautomationcore client reads the canvas and its items, a
# SelectionItem.Select on an edge reaches the canvas selection on the next
# frame, and the republication raises the focus-changed event a screen
# reader announces. Narrator/NVDA on real Windows remain a manual check
# (docs/projects/mermaid_desktop_qualification.md).
import lib.lib
import lib.assert
import graphics.mermaid_access
import graphics.ui.accessibility_uia
import graphics.ui.testing

c_lib "uiautomationcore.dll"
extern int UiaNodeFromProvider(int provider, int* node)
extern int UiaNodeRelease(int node)
extern int UiaGetPropertyValue(int node, int property_id, char* out)
extern int UiaAddEvent(int node, int event_id, int callback, int scope, int32* properties, int count, char* cache, int* event)
extern int UiaRemoveEvent(int event)

# PeekMessageW / DispatchMessageW come with graphics.window_win32.
c_lib "oleaut32.dll"
extern int VariantClear(char* value)

type mu_m1 = fn(int) -> int
type mu_m2 = fn(int, int) -> int
type mu_m3 = fn(int, int, int) -> int

const int MU_CANVAS = 900001
int mu_focus_events

void mu_on_event(int args, int requested, int tree):
	if (load_int32(cast(char*, args + 4)) == UIA_AutomationFocusChangedEventId): mu_focus_events = mu_focus_events + 1

int mu_hr(int v):
	return (v << 32) >> 32

int mu_method(int object, int slot, int nargs):
	int vtbl = load_int64(cast(char*, object))
	return win_c_function(load_int64(cast(char*, vtbl + slot * 8)), nargs, 1)

int mu_call1(int object, int slot):
	mu_m1* f = cast(mu_m1*, mu_method(object, slot, 1))
	return mu_hr(f(object))

int mu_call2(int object, int slot, int a):
	mu_m2* f = cast(mu_m2*, mu_method(object, slot, 2))
	return mu_hr(f(object, a))

int mu_call3(int object, int slot, int a, int b):
	mu_m3* f = cast(mu_m3*, mu_method(object, slot, 3))
	return mu_hr(f(object, a, b))

void mu_release(int object):
	if (object != 0): mu_call1(object, 2)

int mu_query(int object, int slot):
	int out = 0
	if (mu_call3(object, 0, cast(int, &ui_uia_iids[slot * 16]), cast(int, &out)) != 0): return 0
	return out

int mu_navigate(int simple, int direction):
	int fragment = mu_query(simple, 2)
	int out = 0
	assert_equal(0, mu_call3(fragment, 3, direction, cast(int, &out)))
	mu_release(fragment)
	if (out == 0): return 0
	int simple_out = mu_query(out, 1)
	mu_release(out)
	return simple_out

void mu_text(int node, int property, char* expect):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, mu_hr(UiaGetPropertyValue(node, property, &v[0])))
	assert_equal(VT_BSTR, load_int16(&v[0]) & 65535)
	int length = 0
	char* text = ui_uia_utf8(load_int64(&v[8]), &length)
	assert_equal(strlen(expect), length)
	for i in range(length): assert_equal(expect[i], text[i])
	free(text)
	VariantClear(&v[0])

void mu_int(int node, int property, int expect):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, mu_hr(UiaGetPropertyValue(node, property, &v[0])))
	if ((load_int16(&v[0]) & 65535) == VT_BOOL): assert_equal(expect, (load_int16(&v[8]) & 65535) != 0)
	else: assert_equal(expect, load_int32(&v[8]))
	VariantClear(&v[0])

int mu_node(int simple):
	int node = 0
	assert_equal(0, mu_hr(UiaNodeFromProvider(simple, &node)))
	return node

void mu_pump():
	char[64] msg
	for tries in range(40):
		while (PeekMessageW(&msg[0], 0, 0, 0, 1) & 255): DispatchMessageW(&msg[0])
		if (mu_focus_events > 0): return
		Sleep(50)

ui_access_tree* mu_frame(ui_context* ctx, mm_canvas* c, mm_editor* e):
	ui_access_tree* tree = ui_access_tree_new(256, 65536)
	ui_access_capture(ctx, tree)
	ui_begin(ctx, 800, 600)
	mm_access_apply(ctx, MU_CANVAS, c, e)
	ui_button(ctx, c"Save")
	ui_end(ctx)
	mm_access_canvas(tree, ui_access_root_id, MU_CANVAS, c, e, ui_rect_new(100.0, 50.0, 600.0, 400.0), ctx.focus == MU_CANVAS)
	ui_access_capture(ctx, 0)
	return tree

int main():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	mm_editor* e = mm_editor_new(c"unused_uia.mmd", c"flowchart LR\nA[Alpha] -->|pays| B[Beta]\n")
	mm_canvas c
	mm_canvas_init(&c)
	ctx.focus = MU_CANVAS
	ui_uia_bridge* bridge = ui_access_uia_open(0)
	ui_access_tree* tree = mu_frame(ctx, &c, e)
	assert_equal(1, ui_access_uia_publish(bridge, tree))
	int root = ui_access_uia_root(bridge)
	asserts(c"root provider", root != 0)
	# Root -> Save button -> canvas list, in snapshot order.
	int save = mu_navigate(root, NavigateDirection_FirstChild)
	int canvas = mu_navigate(save, NavigateDirection_NextSibling)
	asserts(c"canvas provider", canvas != 0)
	int canvas_node = mu_node(canvas)
	mu_int(canvas_node, UIA_ControlTypePropertyId, UIA_ListControlTypeId)
	mu_text(canvas_node, UIA_NamePropertyId, c"Diagram canvas")
	mu_int(canvas_node, UIA_HasKeyboardFocusPropertyId, 1)
	int alpha = mu_navigate(canvas, NavigateDirection_FirstChild)
	int beta = mu_navigate(alpha, NavigateDirection_NextSibling)
	int edge = mu_navigate(beta, NavigateDirection_NextSibling)
	asserts(c"items", alpha != 0 && beta != 0 && edge != 0)
	int alpha_node = mu_node(alpha)
	mu_int(alpha_node, UIA_ControlTypePropertyId, UIA_ListItemControlTypeId)
	mu_text(alpha_node, UIA_NamePropertyId, c"Alpha")
	mu_text(alpha_node, UIA_HelpTextPropertyId, c"node A, 1 outgoing, 0 incoming, movable")
	mu_int(alpha_node, UIA_IsKeyboardFocusablePropertyId, 1)
	int edge_node = mu_node(edge)
	mu_text(edge_node, UIA_NamePropertyId, c"Alpha to Beta: pays")
	mu_text(edge_node, UIA_HelpTextPropertyId, c"edge from Alpha to Beta, label pays")
	# Select the edge through its SelectionItem pattern (vtable: wine's
	# flat pattern functions are stubs). The request reaches the canvas on
	# the next frame and moves focus to the edge.
	int select = 0
	assert_equal(0, mu_call3(edge, 4, UIA_SelectionItemPatternId, cast(int, &select)))
	asserts(c"selection item pattern", select != 0)
	int32[1] state
	assert_equal(0, mu_call2(select, 6, cast(int, &state[0])))
	assert_equal(0, state[0])
	char[48] cache
	char[8] condition
	save_int64(&condition[0], 0)
	for i in range(48): cache[i] = 0
	save_int64(&cache[0], cast(int, &condition[0]))
	save_int32(&cache[8], 1)
	save_int32(&cache[44], 1)
	int root_node = mu_node(root)
	int focus_event = 0
	assert_equal(0, mu_hr(UiaAddEvent(root_node, UIA_AutomationFocusChangedEventId, win_callback(cast(int, mu_on_event), 3), 7, cast(int32*, 0), 0, &cache[0], &focus_event)))
	assert_equal(0, mu_call1(select, 3))
	assert_equal(1, ui_access_uia_dispatch(bridge, tree))
	ui_access_tree* next = mu_frame(ctx, &c, e)
	assert_equal(0, c.edge)
	assert_equal(-1, c.node)
	assert_equal(mm_access_edge_id(MU_CANVAS, 0), next.focused_id)
	assert_equal(1, ui_access_uia_publish(bridge, next))
	mu_pump()
	assert_equal(1, mu_focus_events)
	assert_equal(0, mu_call2(select, 6, cast(int, &state[0])))
	assert_equal(1, state[0])
	mu_int(edge_node, UIA_HasKeyboardFocusPropertyId, 1)
	assert_equal(0, mu_hr(UiaRemoveEvent(focus_event)))
	UiaNodeRelease(root_node)
	UiaNodeRelease(edge_node)
	UiaNodeRelease(alpha_node)
	UiaNodeRelease(canvas_node)
	mu_release(select)
	mu_release(edge)
	mu_release(beta)
	mu_release(alpha)
	mu_release(canvas)
	mu_release(save)
	ui_access_uia_close(bridge)
	ui_access_tree_free(tree)
	ui_access_tree_free(next)
	mm_editor_free(e)
	println(c"Mermaid canvas UI Automation OK")
	return 0
