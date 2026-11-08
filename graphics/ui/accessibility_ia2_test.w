# wbuild: name=graphics_ui_accessibility_ia2_test arch_only=win64
# IAccessible2's depth (#911), under wine in CI: relations
# (get_relations, IAccessibleRelation, get_relationTargetsOfType),
# IAccessibleText / IAccessibleEditableText over glyph boxes, attribute
# runs and selections, IAccessibleTable2 / IAccessibleTableCell with
# header rows, row headers and spans, and IAccessibleValue on a
# progress bar and a slider. Every interface is reached the way NVDA
# and JAWS reach it: IAccessible -> IServiceProvider -> IAccessible2,
# then QueryInterface, and called through its vtable (wine ships no
# IAccessible2 proxy, so this exercises the provider side in process).
import lib.lib
import lib.assert
import graphics.ui.accessibility_uia
import graphics.ui.accessibility_uia_testing


# IAccessible2 slots past IAccessible's 28.
const int IA2_N_RELATIONS = 28
const int IA2_RELATION = 29
const int IA2_RELATIONS = 30
const int IA2_UNIQUE_ID = 41
const int IA2_ATTRIBUTE = 46
const int IA2_WITH_CARET = 47
const int IA2_TARGETS_OF_TYPE = 48
const int IA2_SELECTION_RANGES = 49
# IAccessibleText slots.
const int TEXT_ADD_SELECTION = 3
const int TEXT_ATTRIBUTES = 4
const int TEXT_CARET = 5
const int TEXT_EXTENTS = 6
const int TEXT_N_SELECTIONS = 7
const int TEXT_OFFSET_AT_POINT = 8
const int TEXT_SELECTION = 9
const int TEXT_GET = 10
const int TEXT_BEFORE = 11
const int TEXT_AFTER = 12
const int TEXT_AT = 13
const int TEXT_REMOVE_SELECTION = 14
const int TEXT_SET_CARET = 15
const int TEXT_SET_SELECTION = 16
const int TEXT_COUNT = 17
const int TEXT_SCROLL = 18
const int TEXT_SCROLL_POINT = 19
const int TEXT_NEW = 20
const int TEXT_OLD = 21


ui_access_tree* build(int edited):
	ui_access_tree* tree = ui_access_tree_new(64, 1024)
	tree.action = uiat_record
	ui_rect r = ui_rect_new(0.0, 0.0, 400.0, 400.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	uiat_text(tree, 1, UI_ACCESS_NAME, c"Depth")
	ui_access_add(tree, 2, 1, UI_ACCESS_TEXT, ui_rect_new(10.0, 0.0, 60.0, 10.0))
	uiat_text(tree, 2, UI_ACCESS_NAME, c"Notes:")
	# The editor: "ab\ncd" on two lines (glyph boxes), "cd" bold, the
	# selections "a" and "cd"; labelled by 2, described by 4.
	ui_access_node* editor = ui_access_add(tree, 3, 1, UI_ACCESS_TEXTBOX, ui_rect_new(10.0, 10.0, 200.0, 40.0))
	editor.states = UI_ACCESS_FOCUSABLE
	editor.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_SET_SELECTION | UI_ACCESS_SET_SELECTIONS | UI_ACCESS_SCROLL_TO
	uiat_text(tree, 3, UI_ACCESS_NAME, c"Notes")
	if edited: uiat_text(tree, 3, UI_ACCESS_VALUE, c"ab\ncxd")
	else: uiat_text(tree, 3, UI_ACCESS_VALUE, c"ab\ncd")
	ui_rect[6] boxes
	boxes[0] = ui_rect_new(14.0, 12.0, 10.0, 16.0)
	boxes[1] = ui_rect_new(24.0, 12.0, 10.0, 16.0)
	boxes[2] = ui_rect_new(34.0, 12.0, 0.0, 16.0)
	boxes[3] = ui_rect_new(14.0, 30.0, 10.0, 16.0)
	boxes[4] = ui_rect_new(24.0, 30.0, 12.0, 16.0)
	boxes[5] = ui_rect_new(36.0, 30.0, 10.0, 16.0)
	assert_equal(1, ui_access_set_char_boxes(tree, 3, &boxes[0], 5 + edited))
	ui_access_text_attrs* base = ui_access_default_attrs(tree, 3)
	ui_access_attrs_set_family(base, c"Liberation Sans", 15)
	base.size = 12
	base.weight = 400
	base.fg = 0x102030
	base.bg = 0xffffff
	ui_access_text_attrs* bold = ui_access_add_attr_run(tree, 3, 3, 5)
	bold.weight = 700
	bold.underline = 1
	assert_equal(1, ui_access_set_selection(tree, 3, 0, 1))
	assert_equal(1, ui_access_add_selection(tree, 3, 3, 5))
	assert_equal(1, ui_access_add_relation(tree, 3, UI_ACCESS_REL_LABELLED_BY, 2))
	assert_equal(1, ui_access_add_relation(tree, 3, UI_ACCESS_REL_DESCRIBED_BY, 4))
	assert_equal(0, ui_access_add_relation(tree, 3, UI_ACCESS_REL_DESCRIBED_BY, 4))
	assert_equal(0, ui_access_add_relation(tree, 3, 9, 4))
	ui_access_add(tree, 4, 1, UI_ACCESS_TEXT, ui_rect_new(10.0, 50.0, 60.0, 10.0))
	uiat_text(tree, 4, UI_ACCESS_NAME, c"Plain text")
	# A combobox controlling its list.
	ui_access_node* combo = ui_access_add(tree, 5, 1, UI_ACCESS_COMBOBOX, ui_rect_new(10.0, 60.0, 80.0, 20.0))
	combo.actions = UI_ACCESS_ACTIVATE
	uiat_text(tree, 5, UI_ACCESS_NAME, c"Size")
	ui_access_add(tree, 6, 1, UI_ACCESS_LIST, ui_rect_new(10.0, 80.0, 80.0, 40.0))
	uiat_text(tree, 6, UI_ACCESS_NAME, c"Sizes")
	assert_equal(1, ui_access_add_relation(tree, 5, UI_ACCESS_REL_CONTROLLER_FOR, 6))
	# A progress bar with range values and one without (its text), and
	# a slider taking values.
	ui_access_add(tree, 7, 1, UI_ACCESS_PROGRESS, ui_rect_new(10.0, 130.0, 80.0, 10.0))
	uiat_text(tree, 7, UI_ACCESS_VALUE, c"40%")
	assert_equal(1, ui_access_set_range(tree, 7, 40.0, 0.0, 100.0, 0.0))
	ui_access_add(tree, 8, 1, UI_ACCESS_PROGRESS, ui_rect_new(10.0, 140.0, 80.0, 10.0))
	uiat_text(tree, 8, UI_ACCESS_VALUE, c"25%")
	ui_access_node* slider = ui_access_add(tree, 9, 1, UI_ACCESS_SLIDER, ui_rect_new(10.0, 150.0, 80.0, 10.0))
	slider.actions = UI_ACCESS_SET_VALUE
	uiat_text(tree, 9, UI_ACCESS_NAME, c"Volume")
	assert_equal(1, ui_access_set_range(tree, 9, 3.0, 0.0, 10.0, 0.5))
	assert_equal(0, ui_access_set_range(tree, 9, 3.0, 10.0, 0.0, 0.5))
	# The table: an explicit header row (Kind, Item spanning two
	# columns), the row header Fruit spanning two rows, Cherry spanning
	# two columns; the first data row selected, rows multi-selectable.
	ui_access_node* grid = ui_access_add(tree, 10, 1, UI_ACCESS_TABLE, ui_rect_new(10.0, 170.0, 200.0, 80.0))
	grid.states = UI_ACCESS_MULTISELECTABLE
	uiat_text(tree, 10, UI_ACCESS_NAME, c"Fruit table")
	ui_access_node* head = ui_access_add(tree, 11, 10, UI_ACCESS_ROW, r)
	head.states = UI_ACCESS_HEADER
	ui_access_add(tree, 12, 11, UI_ACCESS_CELL, r)
	uiat_text(tree, 12, UI_ACCESS_NAME, c"Kind")
	ui_access_node* item_head = ui_access_add(tree, 13, 11, UI_ACCESS_CELL, r)
	item_head.col_span = 2
	uiat_text(tree, 13, UI_ACCESS_NAME, c"Item")
	ui_access_node* first = ui_access_add(tree, 20, 10, UI_ACCESS_ROW, r)
	first.states = UI_ACCESS_SELECTED
	first.actions = UI_ACCESS_SELECT
	ui_access_node* fruit = ui_access_add(tree, 21, 20, UI_ACCESS_CELL, r)
	fruit.states = UI_ACCESS_HEADER
	fruit.row_span = 2
	uiat_text(tree, 21, UI_ACCESS_NAME, c"Fruit")
	ui_access_add(tree, 22, 20, UI_ACCESS_CELL, r)
	uiat_text(tree, 22, UI_ACCESS_NAME, c"Apple")
	ui_access_add(tree, 23, 20, UI_ACCESS_CELL, r)
	uiat_text(tree, 23, UI_ACCESS_NAME, c"Red")
	ui_access_node* second = ui_access_add(tree, 30, 10, UI_ACCESS_ROW, r)
	second.actions = UI_ACCESS_SELECT
	ui_access_node* cherry = ui_access_add(tree, 31, 30, UI_ACCESS_CELL, r)
	cherry.col_span = 2
	uiat_text(tree, 31, UI_ACCESS_NAME, c"Cherry")
	# A radio group whose buttons are its members.
	ui_access_add(tree, 40, 1, UI_ACCESS_GROUP, ui_rect_new(10.0, 260.0, 100.0, 40.0))
	uiat_text(tree, 40, UI_ACCESS_NAME, c"Colour")
	ui_access_add(tree, 41, 40, UI_ACCESS_RADIO, ui_rect_new(10.0, 260.0, 100.0, 20.0))
	uiat_text(tree, 41, UI_ACCESS_NAME, c"Red")
	assert_equal(1, ui_access_add_relation(tree, 41, UI_ACCESS_REL_MEMBER_OF, 40))
	# A relation to a node that does not exist is left out.
	assert_equal(1, ui_access_add_relation(tree, 41, UI_ACCESS_REL_LABELLED_BY, 99))
	tree.focused_id = 3
	return tree


int ia2_query(int ia2, int kind):
	int out = uiat_query(ia2, ui_uia_kind_slot(kind))
	asserts(c"IA2 interface", out != 0)
	return out


# A relation object's type string and its target ids.
void assert_relation(int relation, char* type, int count, int target):
	uiat_assert_text(relation, 3, type)
	assert_equal(count, uiat_get32(relation, 5))
	int t = 0
	assert_equal(0, uiat_call3(relation, 6, 0, cast(int, &t)))
	assert_equal(0 - target, uiat_unique_of(t))
	assert_equal(cast(int, UIA_E_INVALIDARG), uiat_call3(relation, 6, count, cast(int, &t)))
	int[4] targets
	int32[1] got
	assert_equal(0, uiat_call4(relation, 7, 4, cast(int, &targets[0]), cast(int, &got[0])))
	assert_equal(count, got[0])
	assert_equal(0 - target, uiat_unique_of(targets[0]))


# get_relationTargetsOfType: the target ids of type.
list[int] targets_of(int ia2, char* type):
	int bstr = ui_uia_bstr(type, strlen(type))
	int array = 0
	int32[1] count
	count[0] = 0 - 1
	int r = uiat_call5(ia2, IA2_TARGETS_OF_TYPE, bstr, 0, cast(int, &array), cast(int, &count[0]))
	SysFreeString(bstr)
	asserts(c"targets of type", (r == 0) || (r == 1))
	return uiat_object_ids(array, count[0])


void check_relations(int root):
	int editor = uiat_ia2_of(root, 3)
	assert_equal(2, uiat_get32(editor, IA2_N_RELATIONS))
	int relation = 0
	assert_equal(0, uiat_call3(editor, IA2_RELATION, 0, cast(int, &relation)))
	assert_relation(relation, c"labelledBy", 1, 2)
	asserts(c"IAccessibleRelation", uiat_query(relation, UI_UIA_RELATION_IID) == relation)
	uiat_release(relation)
	uiat_release(relation)
	assert_equal(cast(int, UIA_E_INVALIDARG), uiat_call3(editor, IA2_RELATION, 2, cast(int, &relation)))
	int[4] items
	int32[1] count
	assert_equal(0, uiat_call4(editor, IA2_RELATIONS, 4, cast(int, &items[0]), cast(int, &count[0])))
	assert_equal(2, count[0])
	assert_relation(items[1], c"describedBy", 1, 4)
	uiat_release(items[0])
	uiat_release(items[1])
	list[int] ids = targets_of(editor, c"describedBy")
	assert_equal(1, ids.length)
	assert_equal(4, ids[0])
	list_free[int](ids)
	ids = targets_of(editor, c"flowsTo")
	assert_equal(0, ids.length)
	list_free[int](ids)
	# The reverse relations, derived.
	int label = uiat_ia2_of(root, 2)
	assert_equal(1, uiat_get32(label, IA2_N_RELATIONS))
	assert_equal(0, uiat_call3(label, IA2_RELATION, 0, cast(int, &relation)))
	assert_relation(relation, c"labelFor", 1, 3)
	uiat_release(relation)
	int help = uiat_ia2_of(root, 4)
	ids = targets_of(help, c"descriptionFor")
	assert_equal(1, ids.length)
	assert_equal(3, ids[0])
	list_free[int](ids)
	int combo = uiat_ia2_of(root, 5)
	ids = targets_of(combo, c"controllerFor")
	assert_equal(6, ids[0])
	list_free[int](ids)
	int list = uiat_ia2_of(root, 6)
	ids = targets_of(list, c"controlledBy")
	assert_equal(1, ids.length)
	assert_equal(5, ids[0])
	list_free[int](ids)
	int radio = uiat_ia2_of(root, 41)
	assert_equal(1, uiat_get32(radio, IA2_N_RELATIONS))
	ids = targets_of(radio, c"memberOf")
	assert_equal(40, ids[0])
	list_free[int](ids)
	ids = targets_of(radio, c"labelledBy")
	assert_equal(0, ids.length)
	list_free[int](ids)
	# A node without relations: S_FALSE and no objects.
	int doc = uiat_ia2_of(root, 10)
	assert_equal(0, uiat_get32(doc, IA2_N_RELATIONS))
	assert_equal(UIA_S_FALSE, uiat_call4(doc, IA2_RELATIONS, 4, cast(int, &items[0]), cast(int, &count[0])))
	assert_equal(0, count[0])
	# UIA's LabeledBy / DescribedBy / ControllerFor from the same model.
	int editor_simple = uiat_find(root, 3)
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, uiat_call3(editor_simple, 5, UIA_LabeledByPropertyId, cast(int, &v[0])))
	assert_equal(VT_UNKNOWN, load_int16(&v[0]) & 65535)
	int labeled = uiat_query(load_int64(&v[8]), 1)
	assert_equal(2, uiat_automation_id(labeled))
	uiat_release(labeled)
	VariantClear(&v[0])
	assert_equal(0, uiat_call3(editor_simple, 5, UIA_DescribedByPropertyId, cast(int, &v[0])))
	assert_equal(VT_UNKNOWN | VT_ARRAY, load_int16(&v[0]) & 65535)
	ids = uiat_array_ids(load_int64(&v[8]))
	assert_equal(1, ids.length)
	assert_equal(4, ids[0])
	list_free[int](ids)
	int combo_simple = uiat_find(root, 5)
	assert_equal(0, uiat_call3(combo_simple, 5, UIA_ControllerForPropertyId, cast(int, &v[0])))
	ids = uiat_array_ids(load_int64(&v[8]))
	assert_equal(6, ids[0])
	list_free[int](ids)
	uiat_release(combo_simple)
	uiat_release(editor_simple)
	# get_attribute and IAccessible2_2 / _3 by QueryInterface.
	asserts(c"IAccessible2_2", uiat_query(editor, UI_UIA_IA2_2_IID) != 0)
	uiat_release(editor)
	asserts(c"IAccessible2_3", uiat_query(editor, UI_UIA_IA2_3_IID) != 0)
	uiat_release(editor)
	int name = ui_uia_bstr(c"level", 5)
	ui_uia_variant_clear(&v[0])
	assert_equal(UIA_S_FALSE, uiat_call3(editor, IA2_ATTRIBUTE, name, cast(int, &v[0])))
	SysFreeString(name)
	# The caret is in the focused editor, under the document root.
	int doc_root = uiat_ia2_of(root, 3)
	int with = 0
	int32[1] caret
	assert_equal(0, uiat_call3(doc_root, IA2_WITH_CARET, cast(int, &with), cast(int, &caret[0])))
	assert_equal(1, caret[0])
	assert_equal(0 - 3, uiat_unique_of(with))
	assert_equal(UIA_S_FALSE, uiat_call3(combo, IA2_WITH_CARET, cast(int, &with), cast(int, &caret[0])))
	# get_selectionRanges: both selections, the primary forward.
	int ranges = 0
	assert_equal(0, uiat_call3(editor, IA2_SELECTION_RANGES, cast(int, &ranges), cast(int, &count[0])))
	assert_equal(2, count[0])
	char* rec = cast(char*, ranges)
	assert_equal(0, load_int32(&rec[8]))
	assert_equal(1, load_int32(&rec[24]))
	assert_equal(3, load_int32(&rec[40]))
	assert_equal(5, load_int32(&rec[56]))
	for i in range(4): uiat_release(load_int64(&rec[i * 16]))
	CoTaskMemFree(ranges)
	uiat_release(doc_root)
	uiat_release(doc)
	uiat_release(radio)
	uiat_release(list)
	uiat_release(combo)
	uiat_release(help)
	uiat_release(label)
	uiat_release(editor)


# get_textAtOffset (and before / after): the segment and its offsets.
void assert_unit(int text, int slot, int offset, int boundary, int start, int end, char* expect, int status):
	int32[2] range
	int bstr = 0
	assert_equal(status, uiat_call6(text, slot, offset, boundary, cast(int, &range[0]), cast(int, &range[1]), cast(int, &bstr)))
	assert_equal(start, range[0])
	assert_equal(end, range[1])
	# An unimplemented boundary (sentences) answers no text at all.
	if ((bstr == 0) && (strlen(expect) == 0) && (status == UIA_S_FALSE)): return
	uiat_assert_bstr(expect, bstr)
	SysFreeString(bstr)


void check_text(ui_uia_bridge* bridge, ui_access_tree* app, int root):
	int ia2 = uiat_ia2_of(root, 3)
	int text = ia2_query(ia2, UI_UIA_IA2_TEXT)
	assert_equal(5, uiat_get32(text, TEXT_COUNT))
	assert_equal(1, uiat_get32(text, TEXT_CARET))
	int bstr = 0
	assert_equal(0, uiat_call4(text, TEXT_GET, 0, IA2_TEXT_OFFSET_LENGTH, cast(int, &bstr)))
	uiat_assert_bstr(c"ab\ncd", bstr)
	SysFreeString(bstr)
	assert_equal(0, uiat_call4(text, TEXT_GET, 5, 3, cast(int, &bstr)))
	uiat_assert_bstr(c"cd", bstr)
	SysFreeString(bstr)
	assert_equal(cast(int, UIA_E_INVALIDARG), uiat_call4(text, TEXT_GET, 0, 9, cast(int, &bstr)))
	# Glyph geometry: screen pixels (origin 100, 200) and relative to
	# the parent (the document at 0, 0).
	int32[4] box
	assert_equal(0, uiat_call7(text, TEXT_EXTENTS, 4, IA2_COORDTYPE_SCREEN_RELATIVE, cast(int, &box[0]), cast(int, &box[1]), cast(int, &box[2]), cast(int, &box[3])))
	assert_equal(124, box[0])
	assert_equal(230, box[1])
	assert_equal(12, box[2])
	assert_equal(16, box[3])
	assert_equal(0, uiat_call7(text, TEXT_EXTENTS, 0, IA2_COORDTYPE_PARENT_RELATIVE, cast(int, &box[0]), cast(int, &box[1]), cast(int, &box[2]), cast(int, &box[3])))
	assert_equal(14, box[0])
	assert_equal(12, box[1])
	int32[1] at
	assert_equal(0, uiat_call5(text, TEXT_OFFSET_AT_POINT, 128, 235, IA2_COORDTYPE_SCREEN_RELATIVE, cast(int, &at[0])))
	assert_equal(4, at[0])
	assert_equal(UIA_S_FALSE, uiat_call5(text, TEXT_OFFSET_AT_POINT, 0, 0, IA2_COORDTYPE_SCREEN_RELATIVE, cast(int, &at[0])))
	assert_equal(0 - 1, at[0])
	# Attribute runs: the defaults over "ab\n", the bold underlined run.
	int32[2] run
	assert_equal(0, uiat_call5(text, TEXT_ATTRIBUTES, 0, cast(int, &run[0]), cast(int, &run[1]), cast(int, &bstr)))
	assert_equal(0, run[0])
	assert_equal(3, run[1])
	uiat_assert_bstr(c"font-family:Liberation Sans;font-size:12pt;font-weight:400;font-style:normal;color:rgb(16,32,48);background-color:rgb(255,255,255);", bstr)
	SysFreeString(bstr)
	assert_equal(0, uiat_call5(text, TEXT_ATTRIBUTES, 4, cast(int, &run[0]), cast(int, &run[1]), cast(int, &bstr)))
	assert_equal(3, run[0])
	assert_equal(5, run[1])
	uiat_assert_bstr(c"font-family:Liberation Sans;font-size:12pt;font-weight:700;font-style:normal;text-underline-style:solid;text-underline-type:single;color:rgb(16,32,48);background-color:rgb(255,255,255);", bstr)
	SysFreeString(bstr)
	# Units: lines from newlines and glyph rows, words, characters, all.
	assert_unit(text, TEXT_AT, 1, IA2_TEXT_BOUNDARY_LINE, 0, 3, c"ab\n", 0)
	assert_unit(text, TEXT_AT, 5, IA2_TEXT_BOUNDARY_LINE, 3, 5, c"cd", 0)
	assert_unit(text, TEXT_BEFORE, 4, IA2_TEXT_BOUNDARY_LINE, 0, 3, c"ab\n", 0)
	assert_unit(text, TEXT_AFTER, 1, IA2_TEXT_BOUNDARY_LINE, 3, 5, c"cd", 0)
	assert_unit(text, TEXT_AFTER, 4, IA2_TEXT_BOUNDARY_LINE, 5, 5, c"", UIA_S_FALSE)
	assert_unit(text, TEXT_AT, 1, IA2_TEXT_BOUNDARY_CHAR, 1, 2, c"b", 0)
	assert_unit(text, TEXT_AT, IA2_TEXT_OFFSET_CARET, IA2_TEXT_BOUNDARY_WORD, 0, 3, c"ab\n", 0)
	assert_unit(text, TEXT_AT, 2, IA2_TEXT_BOUNDARY_ALL, 0, 5, c"ab\ncd", 0)
	assert_unit(text, TEXT_AT, 2, IA2_TEXT_BOUNDARY_SENTENCE, 0, 0, c"", UIA_S_FALSE)
	assert_unit(text, TEXT_AT, 3, IA2_TEXT_BOUNDARY_PARAGRAPH, 3, 5, c"cd", 0)
	# Selections, and the requests that edit them.
	assert_equal(2, uiat_get32(text, TEXT_N_SELECTIONS))
	int32[2] sel
	assert_equal(0, uiat_call4(text, TEXT_SELECTION, 1, cast(int, &sel[0]), cast(int, &sel[1])))
	assert_equal(3, sel[0])
	assert_equal(5, sel[1])
	assert_equal(cast(int, UIA_E_INVALIDARG), uiat_call4(text, TEXT_SELECTION, 2, cast(int, &sel[0]), cast(int, &sel[1])))
	assert_equal(0, uiat_call3(text, TEXT_ADD_SELECTION, 2, 1))
	uiat_expect_request(bridge, app, 3, UI_ACCESS_SET_SELECTIONS, c"0 1 3 5 1 2")
	assert_equal(0, uiat_call2(text, TEXT_REMOVE_SELECTION, 1))
	uiat_expect_request(bridge, app, 3, UI_ACCESS_SET_SELECTIONS, c"0 1")
	assert_equal(0, uiat_call4(text, TEXT_SET_SELECTION, 0, 4, 2))
	uiat_expect_request(bridge, app, 3, UI_ACCESS_SET_SELECTIONS, c"2 4 3 5")
	assert_equal(0, uiat_call2(text, TEXT_SET_CARET, IA2_TEXT_OFFSET_LENGTH))
	uiat_expect_request(bridge, app, 3, UI_ACCESS_SET_SELECTION, c"5 5")
	assert_equal(cast(int, UIA_E_INVALIDARG), uiat_call2(text, TEXT_SET_CARET, 6))
	# Scrolling queues SCROLL_TO for a node that scrolls.
	assert_equal(0, uiat_call4(text, TEXT_SCROLL, 3, 5, IA2_SCROLL_TYPE_TOP_EDGE))
	uiat_expect_request(bridge, app, 3, UI_ACCESS_SCROLL_TO, c"3 5 0")
	assert_equal(0, uiat_call4(text, TEXT_SCROLL, 0, 1, IA2_SCROLL_TYPE_BOTTOM_RIGHT))
	uiat_expect_request(bridge, app, 3, UI_ACCESS_SCROLL_TO, c"0 1 1")
	assert_equal(0, uiat_call6(text, TEXT_SCROLL_POINT, 0, 2, IA2_COORDTYPE_SCREEN_RELATIVE, 5, 5))
	uiat_expect_request(bridge, app, 3, UI_ACCESS_SCROLL_TO, c"0 2 2")
	# No change published yet: no old or new text.
	char[16] segment
	assert_equal(UIA_S_FALSE, uiat_call2(text, TEXT_NEW, cast(int, &segment[0])))

	# Editable text: each edit queues the edited value.
	int edit = ia2_query(ia2, UI_UIA_IA2_EDIT)
	int word = ui_uia_bstr(c"XY", 2)
	char[8] word_ref
	save_int64(&word_ref[0], word)
	assert_equal(0, uiat_call3(edit, 5, 1, cast(int, &word_ref[0])))
	uiat_expect_request(bridge, app, 3, UI_ACCESS_SET_VALUE, c"aXYb\ncd")
	assert_equal(0, uiat_call3(edit, 4, 0, 3))
	uiat_expect_request(bridge, app, 3, UI_ACCESS_SET_VALUE, c"cd")
	assert_equal(0, uiat_call4(edit, 8, 3, IA2_TEXT_OFFSET_LENGTH, cast(int, &word_ref[0])))
	uiat_expect_request(bridge, app, 3, UI_ACCESS_SET_VALUE, c"ab\nXY")
	assert_equal(cast(int, UIA_E_NOTIMPL), uiat_call3(edit, 3, 0, 1))
	assert_equal(cast(int, UIA_E_NOTIMPL), uiat_call2(edit, 7, 0))
	SysFreeString(word)

	# Republishing an edit: get_newText / get_oldText describe it.
	ui_access_tree* edited = build(1)
	assert_equal(1, ui_access_uia_publish(bridge, edited))
	assert_equal(0, uiat_call2(text, TEXT_NEW, cast(int, &segment[0])))
	uiat_assert_bstr(c"x", load_int64(&segment[0]))
	SysFreeString(load_int64(&segment[0]))
	assert_equal(4, load_int32(&segment[8]))
	assert_equal(5, load_int32(&segment[12]))
	assert_equal(0, uiat_call2(text, TEXT_OLD, cast(int, &segment[0])))
	uiat_assert_bstr(c"", load_int64(&segment[0]))
	SysFreeString(load_int64(&segment[0]))
	assert_equal(1, ui_access_uia_publish(bridge, app))
	ui_access_tree_free(edited)

	# A read-only textbox offers text but not editable text.
	uiat_release(edit)
	uiat_release(text)
	uiat_release(ia2)
	int label = uiat_ia2_of(root, 2)
	asserts(c"no IAccessibleText on static text", uiat_query(label, ui_uia_kind_slot(UI_UIA_IA2_TEXT)) == 0)
	uiat_release(label)


void check_table(ui_uia_bridge* bridge, ui_access_tree* app, int root):
	int ia2 = uiat_ia2_of(root, 10)
	int table = ia2_query(ia2, UI_UIA_IA2_TABLE)
	assert_equal(2, uiat_get32(table, 7))
	assert_equal(3, uiat_get32(table, 6))
	int cell = 0
	assert_equal(0, uiat_call4(table, 3, 1, 2, cast(int, &cell)))
	assert_equal(0 - 31, uiat_unique_of(cell))
	assert_equal(0, uiat_call4(table, 3, 1, 0, cast(int, &cell)))
	assert_equal(0 - 21, uiat_unique_of(cell))
	assert_equal(cast(int, UIA_E_INVALIDARG), uiat_call4(table, 3, 2, 0, cast(int, &cell)))
	# No caption or summary.
	assert_equal(0, uiat_get_ptr(table, 4, UIA_S_FALSE))
	assert_equal(0, uiat_get_ptr(table, 15, UIA_S_FALSE))
	int bstr = 0
	assert_equal(0, uiat_call3(table, 5, 2, cast(int, &bstr)))
	uiat_assert_bstr(c"Item", bstr)
	SysFreeString(bstr)
	assert_equal(0, uiat_call3(table, 11, 1, cast(int, &bstr)))
	uiat_assert_bstr(c"Fruit", bstr)
	SysFreeString(bstr)
	# Row selection: the first data row and its cells.
	assert_equal(1, uiat_get32(table, 10))
	assert_equal(0, uiat_get32(table, 9))
	assert_equal(3, uiat_get32(table, 8))
	int rows = 0
	int32[1] count
	assert_equal(0, uiat_call3(table, 14, cast(int, &rows), cast(int, &count[0])))
	assert_equal(1, count[0])
	assert_equal(0, load_int32(cast(char*, rows)))
	CoTaskMemFree(rows)
	int cells = 0
	assert_equal(0, uiat_call3(table, 12, cast(int, &cells), cast(int, &count[0])))
	list[int] ids = uiat_object_ids(cells, count[0])
	assert_equal(3, ids.length)
	assert_equal(21, ids[0])
	assert_equal(23, ids[2])
	list_free[int](ids)
	assert_equal(UIA_S_FALSE, uiat_call3(table, 13, cast(int, &rows), cast(int, &count[0])))
	char[8] flag
	flag[0] = 7
	assert_equal(0, uiat_call3(table, 17, 0, cast(int, &flag[0])))
	assert_equal(1, flag[0])
	assert_equal(0, uiat_call3(table, 17, 1, cast(int, &flag[0])))
	assert_equal(0, flag[0])
	assert_equal(0, uiat_call2(table, 18, 1))
	uiat_expect_request(bridge, app, 30, UI_ACCESS_SELECT, c"only")
	assert_equal(0, uiat_call2(table, 20, 0))
	uiat_expect_request(bridge, app, 20, UI_ACCESS_SELECT, c"remove")
	assert_equal(cast(int, UIA_E_INVALIDARG), uiat_call2(table, 18, 5))
	assert_equal(cast(int, UIA_E_NOTIMPL), uiat_call2(table, 19, 0))
	char[24] change
	assert_equal(UIA_S_FALSE, uiat_call2(table, 22, cast(int, &change[0])))

	# Cells: Cherry spans two columns under Item, its row header Fruit
	# spans two rows.
	int cherry = uiat_ia2_of(root, 31)
	int c = ia2_query(cherry, UI_UIA_IA2_CELL)
	assert_equal(1, uiat_get32(c, 8))
	assert_equal(1, uiat_get32(c, 5))
	assert_equal(1, uiat_get32(c, 6))
	assert_equal(2, uiat_get32(c, 3))
	int headers = 0
	assert_equal(0, uiat_call3(c, 4, cast(int, &headers), cast(int, &count[0])))
	ids = uiat_object_ids(headers, count[0])
	assert_equal(1, ids.length)
	assert_equal(13, ids[0])
	list_free[int](ids)
	assert_equal(0, uiat_call3(c, 7, cast(int, &headers), cast(int, &count[0])))
	ids = uiat_object_ids(headers, count[0])
	assert_equal(1, ids.length)
	assert_equal(21, ids[0])
	list_free[int](ids)
	int32[4] ext
	flag[0] = 7
	assert_equal(0, uiat_call6(c, 10, cast(int, &ext[0]), cast(int, &ext[1]), cast(int, &ext[2]), cast(int, &ext[3]), cast(int, &flag[0])))
	assert_equal(1, ext[0])
	assert_equal(1, ext[1])
	assert_equal(1, ext[2])
	assert_equal(2, ext[3])
	assert_equal(0, flag[0])
	int owner = 0
	assert_equal(0, uiat_call2(c, 11, cast(int, &owner)))
	assert_equal(0 - 10, uiat_unique_of(owner))
	int fruit = uiat_ia2_of(root, 21)
	int fc = ia2_query(fruit, UI_UIA_IA2_CELL)
	assert_equal(2, uiat_get32(fc, 6))
	assert_equal(0, uiat_call2(fc, 9, cast(int, &flag[0])))
	assert_equal(1, flag[0])
	uiat_release(fc)
	uiat_release(fruit)
	# Header cells are not table cells (as UIA's GridItem).
	int kind = uiat_ia2_of(root, 12)
	asserts(c"no cell on a header", uiat_query(kind, ui_uia_kind_slot(UI_UIA_IA2_CELL)) == 0)
	uiat_release(kind)
	uiat_release(c)
	uiat_release(cherry)
	uiat_release(table)
	uiat_release(ia2)


int provider_control_type(int simple):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, uiat_call3(simple, 5, UIA_ControlTypePropertyId, cast(int, &v[0])))
	return load_int32(&v[8])


# A VARIANT double getter.
float64 value_of(int value, int slot):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, uiat_call2(value, slot, cast(int, &v[0])))
	assert_equal(VT_R8, load_int16(&v[0]) & 65535)
	return ui_uia_double_from_bits(load_int64(&v[8]))


void check_value(ui_uia_bridge* bridge, ui_access_tree* app, int root):
	int progress = uiat_ia2_of(root, 7)
	int value = ia2_query(progress, UI_UIA_IA2_VALUE)
	assert_equal(40, cast(int, value_of(value, 3)))
	assert_equal(100, cast(int, value_of(value, 5)))
	assert_equal(0, cast(int, value_of(value, 6)))
	char[24] v
	ui_uia_variant_clear(&v[0])
	ui_uia_variant_i4(&v[0], 50)
	assert_equal(cast(int, UIA_E_FAIL), uiat_call2(value, 4, cast(int, &v[0])))
	uiat_release(value)
	uiat_release(progress)
	# Without range values, the value text's number.
	int plain = uiat_ia2_of(root, 8)
	value = ia2_query(plain, UI_UIA_IA2_VALUE)
	assert_equal(25, cast(int, value_of(value, 3)))
	uiat_release(value)
	uiat_release(plain)
	int slider = uiat_ia2_of(root, 9)
	assert_equal(ROLE_SYSTEM_SLIDER, uiat_get32(slider, 31))
	value = ia2_query(slider, UI_UIA_IA2_VALUE)
	assert_equal(3, cast(int, value_of(value, 3)))
	assert_equal(10, cast(int, value_of(value, 5)))
	save_int16(&v[0], VT_R8)
	ui_uia_put_double(cast(int, &v[8]), 7.5)
	assert_equal(0, uiat_call2(value, 4, cast(int, &v[0])))
	uiat_expect_request(bridge, app, 9, UI_ACCESS_SET_VALUE, c"7.5")
	ui_uia_variant_i4(&v[0], 4)
	assert_equal(0, uiat_call2(value, 4, cast(int, &v[0])))
	uiat_expect_request(bridge, app, 9, UI_ACCESS_SET_VALUE, c"4")
	ui_uia_variant_i4(&v[0], 11)
	assert_equal(cast(int, UIA_E_INVALIDARG), uiat_call2(value, 4, cast(int, &v[0])))
	ui_uia_variant_bool(&v[0], 1)
	assert_equal(cast(int, UIA_E_INVALIDARG), uiat_call2(value, 4, cast(int, &v[0])))
	uiat_release(value)
	# UIA's RangeValue over the same values: a settable slider.
	int simple = uiat_find(root, 9)
	assert_equal(UIA_SliderControlTypeId, provider_control_type(simple))
	int range = 0
	assert_equal(0, uiat_call3(simple, 4, UIA_RangeValuePatternId, cast(int, &range)))
	assert_equal(0, uiat_get32(range, 5))
	float64[1] d
	assert_equal(0, uiat_call2(range, 9, cast(int, &d[0])))
	assert_equal(5, cast(int, d[0] * 10.0))
	assert_equal(0, uiat_call2(range, 8, cast(int, &d[0])))
	assert_equal(5, cast(int, d[0]))
	char[8] bits
	float64* p = cast(float64*, &bits[0])
	p[0] = 2.25
	assert_equal(0, uiat_call2(range, 3, load_int64(&bits[0])))
	uiat_expect_request(bridge, app, 9, UI_ACCESS_SET_VALUE, c"2.25")
	p[0] = 12.0
	assert_equal(cast(int, UIA_E_INVALIDARG), uiat_call2(range, 3, load_int64(&bits[0])))
	uiat_release(range)
	uiat_release(simple)
	int bar = uiat_find(root, 7)
	assert_equal(0, uiat_call3(bar, 4, UIA_RangeValuePatternId, cast(int, &range)))
	assert_equal(1, uiat_get32(range, 5))
	uiat_release(range)
	uiat_release(bar)
	uiat_release(slider)


void check_model():
	char[48] out
	assert_equal(1, ui_access_number_format(&out[0], 0.0))
	assert_equal('0', out[0])
	int n = ui_access_number_format(&out[0], 0.0 - 2.5)
	assert_bytes_equal(c"-2.5", &out[0], n)
	assert_equal(4, n)
	n = ui_access_number_format(&out[0], 0.125)
	assert_bytes_equal(c"0.125", &out[0], n)
	int from = 0
	int to = 0
	int align = 0
	assert_equal(1, ui_access_scroll_parse(c"3 5 2", 5, &from, &to, &align))
	assert_equal(2, align)
	assert_equal(0, ui_access_scroll_parse(c"5 3 0", 5, &from, &to, &align))
	assert_equal(0, ui_access_scroll_parse(c"3 5 7", 5, &from, &to, &align))
	assert_equal(0, ui_access_scroll_parse(c"3 5", 3, &from, &to, &align))


int main():
	check_model()
	ui_uia_bridge* bridge = ui_access_uia_open(0)
	ui_access_uia_set_origin(bridge, 100, 200)
	ui_access_tree* app = build(0)
	assert_equal(1, ui_access_uia_publish(bridge, app))
	# A tree compared with itself, and with a copy differing only in a
	# relation, a range or a composition.
	ui_access_tree* copy = ui_access_tree_clone(app)
	assert_equal(1, ui_access_tree_same(app, copy))
	ui_access_add_relation(copy, 4, UI_ACCESS_REL_DESCRIBED_BY, 2)
	assert_equal(0, ui_access_tree_same(app, copy))
	ui_access_tree_free(copy)
	copy = ui_access_tree_clone(app)
	ui_access_set_range(copy, 7, 41.0, 0.0, 100.0, 0.0)
	assert_equal(0, ui_access_tree_same(app, copy))
	ui_access_tree_free(copy)
	int root = ui_access_uia_root(bridge)
	check_relations(root)
	check_text(bridge, app, root)
	check_table(bridge, app, root)
	check_value(bridge, app, root)
	uiat_release(root)
	ui_access_uia_close(bridge)
	ui_access_tree_free(app)
	println(c"IAccessible2 depth OK")
	return 0
