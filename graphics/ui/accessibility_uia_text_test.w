# wbuild: name=graphics_ui_accessibility_uia_text_test arch_only=win64
# UI Automation text depth (#912), under wine's uiautomationcore in CI:
# TextUnit_Format in ExpandToEnclosingUnit / Move / MoveEndpointByUnit
# from the snapshot's attribute runs; ITextEditProvider's
# GetActiveComposition / GetConversionTarget over an IME composition
# and the TextEdit_TextChanged / ConversionTargetChanged events its
# changes raise (to a UiaAddEvent client; wine 9 stubs the former's
# delivery, so that one is reported); GetVisibleRanges
# on a scrolled field whose hidden line lies outside its bounds; and
# ScrollIntoView queuing SCROLL_TO requests.
import lib.lib
import lib.assert
import graphics.ui.accessibility_uia
import graphics.ui.accessibility_uia_testing

c_lib "uiautomationcore.dll"
extern int UiaNodeFromProvider(int provider, int* node)
extern int UiaNodeRelease(int node)
extern int UiaAddEvent(int node, int event_id, int callback, int scope, int32* properties, int count, char* cache, int* event)
extern int UiaRemoveEvent(int event)

c_lib "user32.dll"
extern int PeekMessageW(char* msg, int hwnd, int filter_min, int filter_max, int remove)
extern int DispatchMessageW(char* msg)


# ITextProvider / ITextEditProvider slots.
const int TEXT_SELECTION = 3
const int TEXT_VISIBLE = 4
const int TEXT_DOCUMENT = 7
const int EDIT_COMPOSITION = 9
const int EDIT_CONVERSION = 10
# ITextRangeProvider slots.
const int RANGE_CLONE = 3
const int RANGE_EXPAND = 6
const int RANGE_TEXT = 12
const int RANGE_MOVE = 13
const int RANGE_MOVE_ENDPOINT = 14
const int RANGE_MOVE_TO_RANGE = 15
const int RANGE_SCROLL = 19


# "ab cd\nef gh\nij" in a scrolled editor: its first line sits above
# the field's bounds; "cd" is bold and "gh" italic. With composing, an
# IME composition "xyz" is shown at the end, "y" being converted.
ui_access_tree* build(int composing, int target):
	ui_access_tree* tree = ui_access_tree_new(16, 512)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, ui_rect_new(0.0, 0.0, 300.0, 200.0))
	ui_access_set_text(tree, 1, UI_ACCESS_NAME, c"Text", 4)
	ui_access_node* editor = ui_access_add(tree, 2, 1, UI_ACCESS_TEXTBOX, ui_rect_new(0.0, 20.0, 200.0, 40.0))
	editor.states = UI_ACCESS_FOCUSABLE
	editor.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_SET_SELECTION | UI_ACCESS_SCROLL_TO
	uiat_text(tree, 2, UI_ACCESS_NAME, c"Editor")
	uiat_text(tree, 2, UI_ACCESS_VALUE, c"ab cd\nef gh\nij")
	ui_rect[14] boxes
	for k in range(14):
		float32 w = 10.0
		if ((k == 5) || (k == 11)): w = 0.0
		boxes[k] = ui_rect_new(cast(float32, k % 6) * 10.0, cast(float32, k / 6) * 20.0, w, 20.0)
	ui_access_set_char_boxes(tree, 2, &boxes[0], 14)
	ui_access_text_attrs* base = ui_access_default_attrs(tree, 2)
	ui_access_attrs_set_family(base, c"Liberation Sans", 15)
	base.size = 12
	base.weight = 400
	ui_access_text_attrs* bold = ui_access_add_attr_run(tree, 2, 3, 5)
	bold.weight = 700
	ui_access_text_attrs* italic = ui_access_add_attr_run(tree, 2, 9, 11)
	italic.italic = 1
	ui_access_set_selection(tree, 2, 14, 14)
	if composing:
		ui_rect[3] more
		for k in range(3): more[k] = ui_rect_new(20.0 + cast(float32, k) * 10.0, 40.0, 10.0, 20.0)
		assert_equal(1, ui_access_insert_composition(tree, 2, 14, c"xyz", 3, &more[0], 2, target, 1))
	# A read-only label that does not scroll.
	ui_access_add(tree, 3, 1, UI_ACCESS_TEXTBOX, ui_rect_new(0.0, 80.0, 200.0, 20.0))
	uiat_text(tree, 3, UI_ACCESS_VALUE, c"fixed")
	ui_access_find(tree, 3).states = UI_ACCESS_READONLY
	tree.focused_id = 2
	tree.action = uiat_record
	return tree


void assert_range(int range, char* expect):
	int text = 0
	assert_equal(0, uiat_call3(range, RANGE_TEXT, 0 - 1, cast(int, &text)))
	uiat_assert_bstr(expect, text)
	SysFreeString(text)


int move(int range, int unit, int count):
	int32[1] moved
	assert_equal(0, uiat_call4(range, RANGE_MOVE, unit, count, cast(int, &moved[0])))
	return moved[0]


int move_endpoint(int range, int endpoint, int unit, int count):
	int32[1] moved
	assert_equal(0, uiat_call5(range, RANGE_MOVE_ENDPOINT, endpoint, unit, count, cast(int, &moved[0])))
	return moved[0]


# A degenerate range at character k of the document range doc.
int caret_at(int doc, int k):
	int r = 0
	assert_equal(0, uiat_call2(doc, RANGE_CLONE, cast(int, &r)))
	assert_equal(0, uiat_call4(r, RANGE_MOVE_TO_RANGE, TextPatternRangeEndpoint_End, r, TextPatternRangeEndpoint_Start))
	if (k > 0): assert_equal(k, move(r, TextUnit_Character, k))
	return r


int pattern_of(int simple, int id):
	int out = 0
	assert_equal(0, uiat_call3(simple, 4, id, cast(int, &out)))
	return out


void check_format(int text):
	int doc = uiat_get_ptr(text, TEXT_DOCUMENT, 0)
	int r = caret_at(doc, 0)
	# The plain text before the bold run, the run, then the plain
	# stretch up to the italic one.
	assert_equal(0, uiat_call2(r, RANGE_EXPAND, TextUnit_Format))
	assert_range(r, c"ab ")
	assert_equal(1, move(r, TextUnit_Format, 1))
	assert_range(r, c"cd")
	assert_equal(1, move(r, TextUnit_Format, 1))
	assert_range(r, c"\nef ")
	assert_equal(1, move_endpoint(r, TextPatternRangeEndpoint_End, TextUnit_Format, 1))
	assert_range(r, c"\nef gh")
	assert_equal(0 - 1, move_endpoint(r, TextPatternRangeEndpoint_Start, TextUnit_Format, 0 - 1))
	assert_range(r, c"cd\nef gh")
	uiat_release(r)
	# Inside the italic run, and two format units back from it.
	r = caret_at(doc, 10)
	assert_equal(0, uiat_call2(r, RANGE_EXPAND, TextUnit_Format))
	assert_range(r, c"gh")
	assert_equal(0 - 2, move(r, TextUnit_Format, 0 - 2))
	assert_range(r, c"cd")
	# Past the last run the rest of the text is one unit.
	assert_equal(3, move(r, TextUnit_Format, 5))
	assert_range(r, c"\nij")
	uiat_release(r)
	uiat_release(doc)


# The visible ranges: the two lines inside the field's bounds.
void check_visible(int text):
	int array = uiat_get_ptr(text, TEXT_VISIBLE, 0)
	assert_equal(1, uiat_array_count(array))
	int visible = uiat_array_unknown(array, 0)
	SafeArrayDestroy(array)
	assert_range(visible, c"ef gh\nij")
	uiat_release(visible)


# ScrollIntoView queues SCROLL_TO with the alignment asked for; a field
# that does not scroll has nothing to do.
void check_scroll(ui_uia_bridge* bridge, ui_access_tree* app, int text, int fixed_text):
	int doc = uiat_get_ptr(text, TEXT_DOCUMENT, 0)
	int r = caret_at(doc, 0)
	assert_equal(0, uiat_call2(r, RANGE_EXPAND, TextUnit_Line))
	assert_range(r, c"ab cd\n")
	assert_equal(0, uiat_call2(r, RANGE_SCROLL, 1))
	uiat_expect_request(bridge, app, 2, UI_ACCESS_SCROLL_TO, c"0 6 0")
	assert_equal(0, uiat_call2(r, RANGE_SCROLL, 0))
	uiat_expect_request(bridge, app, 2, UI_ACCESS_SCROLL_TO, c"0 6 1")
	uiat_release(r)
	uiat_release(doc)
	int fixed = uiat_get_ptr(fixed_text, TEXT_DOCUMENT, 0)
	assert_equal(0, uiat_call2(fixed, RANGE_SCROLL, 1))
	uiat_expect_nothing(bridge, app)
	uiat_release(fixed)


int text_edit_events
int conversion_events


# UiaEventCallback(UiaEventArgs* args, SAFEARRAY* requested, BSTR tree).
void on_event(int args, int requested, int tree):
	int event_id = load_int32(cast(char*, args + 4))
	if (event_id == UIA_TextEdit_TextChangedEventId): text_edit_events = text_edit_events + 1
	if (event_id == UIA_TextEdit_ConversionTargetChangedEventId): conversion_events = conversion_events + 1


void pump(int* counter):
	char[64] msg
	int tries = 0
	while ((counter[0] == 0) && (tries < 20)):
		while (PeekMessageW(&msg[0], 0, 0, 0, 1) & 255): DispatchMessageW(&msg[0])
		if (counter[0] == 0): Sleep(50)
		tries = tries + 1


void print_number(char* label, int v):
	write(1, label, strlen(label))
	char* digits = itoa(v)
	write(1, digits, strlen(digits))
	free(digits)


# The composition and its events: none, then one composing "xyz" with
# "y" converted, then "z", then committed.
void check_composition(ui_uia_bridge* bridge, ui_access_tree* app, int root):
	int editor = uiat_find(root, 2)
	int edit = pattern_of(editor, UIA_TextEditPatternId)
	asserts(c"text edit pattern", edit != 0)
	assert_equal(0, uiat_get_ptr(edit, EDIT_COMPOSITION, 0))
	assert_equal(0, uiat_get_ptr(edit, EDIT_CONVERSION, 0))
	int fixed = uiat_find(root, 3)
	assert_equal(0, pattern_of(fixed, UIA_TextEditPatternId))
	uiat_release(fixed)

	int root_node = 0
	assert_equal(0, uiat_hr(UiaNodeFromProvider(root, &root_node)))
	char[8] condition
	save_int64(&condition[0], 0)
	char[48] cache
	for i in range(48): cache[i] = 0
	save_int64(&cache[0], cast(int, &condition[0]))
	save_int32(&cache[8], 1)
	save_int32(&cache[44], 1)
	int callback = win_callback(cast(int, on_event), 3)
	int edit_event = 0
	int edit_hr = uiat_hr(UiaAddEvent(root_node, UIA_TextEdit_TextChangedEventId, callback, 7, cast(int32*, 0), 0, &cache[0], &edit_event))
	int conversion_event = 0
	int conversion_hr = uiat_hr(UiaAddEvent(root_node, UIA_TextEdit_ConversionTargetChangedEventId, callback, 7, cast(int32*, 0), 0, &cache[0], &conversion_event))

	ui_access_tree* composing = build(1, 1)
	assert_equal(1, ui_access_uia_publish(bridge, composing))
	int range = uiat_get_ptr(edit, EDIT_COMPOSITION, 0)
	asserts(c"composition", range != 0)
	assert_range(range, c"xyz")
	uiat_release(range)
	range = uiat_get_ptr(edit, EDIT_CONVERSION, 0)
	asserts(c"conversion target", range != 0)
	assert_range(range, c"y")
	uiat_release(range)
	# The caret sits after the target, inside the composition.
	int array = uiat_get_ptr(edit, TEXT_SELECTION, 0)
	int caret = uiat_array_unknown(array, 0)
	SafeArrayDestroy(array)
	assert_equal(0, uiat_call2(caret, RANGE_EXPAND, TextUnit_Character))
	assert_range(caret, c"z")
	uiat_release(caret)
	# UiaRaiseTextEditTextChangedEvent is found at run time and answers
	# S_OK. Wine 9's is a stub that delivers nothing, so its delivery is
	# reported, not required; ConversionTargetChanged goes through
	# UiaRaiseAutomationEvent, which wine's client does deliver.
	assert_equal(0, ui_uia_last_text_edit)
	if (edit_hr == 0): pump(&text_edit_events)
	if (conversion_hr == 0):
		pump(&conversion_events)
		asserts(c"conversion target event delivered", conversion_events >= 1)
	int composed_events = text_edit_events

	# The target moves to "z": a conversion-target change, the text
	# unchanged raises no new text event.
	ui_access_tree* moved = build(1, 2)
	ui_access_uia_publish(bridge, moved)
	ui_access_tree_free(composing)
	range = uiat_get_ptr(edit, EDIT_CONVERSION, 0)
	assert_range(range, c"z")
	uiat_release(range)
	if (conversion_hr == 0): pump(&text_edit_events)

	# Committed: no composition, and CompositionFinalized went out.
	ui_access_tree* committed = build(0, 0)
	ui_access_uia_publish(bridge, committed)
	ui_access_tree_free(moved)
	assert_equal(0, uiat_get_ptr(edit, EDIT_COMPOSITION, 0))
	assert_equal(0, ui_uia_last_text_edit)
	print_number(c"text edit events: registration hr ", edit_hr)
	print_number(c", delivered ", text_edit_events)
	print_number(c" (composing ", composed_events)
	print_number(c"); conversion target: registration hr ", conversion_hr)
	print_number(c", delivered ", conversion_events)
	write(1, c"\n", 1)
	if (edit_event != 0): UiaRemoveEvent(edit_event)
	if (conversion_event != 0): UiaRemoveEvent(conversion_event)
	UiaNodeRelease(root_node)
	uiat_release(edit)
	uiat_release(editor)
	ui_access_tree_free(committed)


int main():
	ui_uia_bridge* bridge = ui_access_uia_open(0)
	ui_access_tree* app = build(0, 0)
	assert_equal(1, ui_access_uia_publish(bridge, app))
	int root = ui_access_uia_root(bridge)
	int editor = uiat_find(root, 2)
	int text = pattern_of(editor, UIA_TextPatternId)
	asserts(c"text pattern", text != 0)
	int fixed = uiat_find(root, 3)
	int fixed_text = pattern_of(fixed, UIA_TextPatternId)
	check_format(text)
	check_visible(text)
	check_scroll(bridge, app, text, fixed_text)
	uiat_release(fixed_text)
	uiat_release(fixed)
	uiat_release(text)
	uiat_release(editor)
	check_composition(bridge, app, root)
	uiat_release(root)
	ui_access_uia_close(bridge)
	ui_access_tree_free(app)
	println(c"UI Automation text depth OK")
	return 0
