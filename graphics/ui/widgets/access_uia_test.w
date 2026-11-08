# wbuild: name=graphics_ui_widgets_uia_test arch_only=win64
# The #913 widgets through the UI Automation bridge, under wine in CI (as
# graphics_ui_accessibility_uia_test): a headless frame with the
# multi-selection list box and a grid table is published unhosted, and
# the provider vtables (wine's flat pattern functions are stubs) read
# the Selection pattern's CanSelectMultiple and selection, drive
# SelectionItem AddToSelection / RemoveFromSelection / Select into the
# list's flags on the next frame, and read the Grid, GridItem, Table and
# TableItem patterns: header row, row headers and spans.
import lib.lib
import lib.assert
import graphics.ui.accessibility_uia
import graphics.ui.accessibility_table
import graphics.ui.testing

c_lib "oleaut32.dll"
extern int SafeArrayGetElement(int array, int32* index, char* value)
extern int SafeArrayGetUBound(int array, int dim, int32* bound)
extern int VariantClear(char* value)

type wu_m1 = fn(int) -> int
type wu_m2 = fn(int, int) -> int
type wu_m3 = fn(int, int, int) -> int
type wu_m4 = fn(int, int, int, int) -> int


int wu_hr(int v):
	return (v << 32) >> 32


int wu_method(int object, int slot, int nargs):
	int vtbl = load_int64(cast(char*, object))
	return win_c_function(load_int64(cast(char*, vtbl + slot * 8)), nargs, 1)


int wu_call1(int object, int slot):
	wu_m1* f = cast(wu_m1*, wu_method(object, slot, 1))
	return wu_hr(f(object))


int wu_call2(int object, int slot, int a):
	wu_m2* f = cast(wu_m2*, wu_method(object, slot, 2))
	return wu_hr(f(object, a))


int wu_call3(int object, int slot, int a, int b):
	wu_m3* f = cast(wu_m3*, wu_method(object, slot, 3))
	return wu_hr(f(object, a, b))


int wu_call4(int object, int slot, int a, int b, int c):
	wu_m4* f = cast(wu_m4*, wu_method(object, slot, 4))
	return wu_hr(f(object, a, b, c))


void wu_release(int object):
	if (object != 0): wu_call1(object, 2)


int wu_query(int object, int slot):
	int out = 0
	if (wu_call3(object, 0, cast(int, &ui_uia_iids[slot * 16]), cast(int, &out)) != 0): return 0
	return out


# GetPatternProvider (Simple slot 4).
int wu_pattern(int simple, int pattern_id):
	int out = 0
	assert_equal(0, wu_call3(simple, 4, pattern_id, cast(int, &out)))
	return out


int wu_navigate(int simple, int direction):
	int fragment = wu_query(simple, 2)
	int out = 0
	assert_equal(0, wu_call3(fragment, 3, direction, cast(int, &out)))
	wu_release(fragment)
	if (out == 0): return 0
	int simple_out = wu_query(out, 1)
	wu_release(out)
	return simple_out


int wu_automation_id(int simple):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, wu_call3(simple, 5, UIA_AutomationIdPropertyId, cast(int, &v[0])))
	assert_equal(VT_BSTR, load_int16(&v[0]) & 65535)
	int length = 0
	char* text = ui_uia_utf8(load_int64(&v[8]), &length)
	int id = atoi(text)
	free(text)
	VariantClear(&v[0])
	return id


int wu_i4(int simple, int property):
	char[24] v
	ui_uia_variant_clear(&v[0])
	assert_equal(0, wu_call3(simple, 5, property, cast(int, &v[0])))
	assert_equal(VT_I4, load_int16(&v[0]) & 65535)
	return load_int32(&v[8])


int wu_get32(int object, int slot):
	int32[1] out
	out[0] = 0 - 7
	assert_equal(0, wu_call2(object, slot, cast(int, &out[0])))
	return out[0]


# An element-array getter (pattern slot): its count, and the first two
# AutomationIds in *a, *b.
int wu_array(int object, int slot, int* a, int* b):
	int array = 0
	assert_equal(0, wu_call2(object, slot, cast(int, &array)))
	asserts(c"array", array != 0)
	int32[1] bound
	assert_equal(0, wu_hr(SafeArrayGetUBound(array, 1, &bound[0])))
	int32[1] index
	for i in range(bound[0] + 1):
		index[0] = i
		int unknown = 0
		assert_equal(0, wu_hr(SafeArrayGetElement(array, &index[0], cast(char*, &unknown))))
		int simple = wu_query(unknown, 1)
		if (i == 0): a[0] = wu_automation_id(simple)
		if (i == 1): b[0] = wu_automation_id(simple)
		wu_release(simple)
		wu_release(unknown)
	SafeArrayDestroy(array)
	return bound[0] + 1


struct wu_model:
	ui_listbox_state list
	char[4] picked
	ui_table_state table
	int32 table_picked


void wu_frame(ui_context* ctx, wu_model* m):
	char*[4] names
	names[0] = c"Apple"
	names[1] = c"Cherry"
	names[2] = c"Kiwi"
	names[3] = c"Pecan"
	char*[3] headers
	headers[0] = c"Kind"
	headers[1] = c"Item"
	headers[2] = c""
	int32[3] spans
	spans[0] = 1
	spans[1] = 2
	spans[2] = 1
	int32[3] widths
	widths[0] = 80
	widths[1] = 80
	widths[2] = 60
	ui_begin(ctx, 600, 400)
	ui_listbox_begin(ctx, ui_rect_new(8.0, 8.0, 160.0, 140.0), &m.list, c"Fruit", &m.picked[0], 4)
	for i in range(4): ui_listbox_item(ctx, &m.list, i, names[i])
	ui_listbox_end(ctx, &m.list)
	m.table.row_header_col = 0
	m.table.header_spans = &spans[0]
	ui_table_begin(ctx, ui_rect_new(200.0, 8.0, 240.0, 200.0), &headers[0], &widths[0], 3, &m.table)
	if (ui_table_row(ctx, &m.table, 0)):
		ui_table_cell_span(ctx, &m.table, c"Fruit", 2, 1)
		ui_table_cell(ctx, &m.table, c"Apple")
		ui_table_cell(ctx, &m.table, c"Red")
	if (ui_table_row(ctx, &m.table, 1)):
		ui_table_cell_span(ctx, &m.table, c"Cherry", 1, 2)
	m.table_picked = ui_table_end(ctx, &m.table)
	ui_end(ctx)


ui_access_tree* wu_capture(ui_context* ctx, wu_model* m):
	ui_access_tree* tree = ui_access_tree_new(64, 4096)
	ui_access_capture(ctx, tree)
	wu_frame(ctx, m)
	ui_access_capture(ctx, 0)
	return tree


# The flags as "0101".
void wu_marks(char* expect, wu_model* m):
	for i in range(4): assert_equal(expect[i] - '0', m.picked[i])


int main():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	wu_model m
	ui_listbox_init(&m.list)
	for i in range(4): m.picked[i] = 0
	m.picked[1] = 1
	ui_table_init(&m.table)
	ui_uia_bridge* bridge = ui_access_uia_open(0)
	ui_access_tree* tree = wu_capture(ctx, &m)
	assert_equal(1, ui_access_uia_publish(bridge, tree))
	int root = ui_access_uia_root(bridge)
	asserts(c"root provider", root != 0)

	# The list box: id 1, items 2..5.
	int list = wu_navigate(root, NavigateDirection_FirstChild)
	assert_equal(1, wu_automation_id(list))
	assert_equal(UIA_ListControlTypeId, wu_i4(list, UIA_ControlTypePropertyId))
	int selection = wu_pattern(list, UIA_SelectionPatternId)
	asserts(c"Selection pattern", selection != 0)
	assert_equal(1, wu_get32(selection, 4))
	int a = 0
	int b = 0
	assert_equal(1, wu_array(selection, 3, &a, &b))
	assert_equal(3, a)
	int apple = wu_navigate(list, NavigateDirection_FirstChild)
	int cherry = wu_navigate(apple, NavigateDirection_NextSibling)
	int kiwi = wu_navigate(cherry, NavigateDirection_NextSibling)
	assert_equal(4, wu_automation_id(kiwi))
	int kiwi_item = wu_pattern(kiwi, UIA_SelectionItemPatternId)
	int apple_item = wu_pattern(apple, UIA_SelectionItemPatternId)
	int cherry_item = wu_pattern(cherry, UIA_SelectionItemPatternId)
	assert_equal(1, wu_get32(cherry_item, 6))
	assert_equal(0, wu_get32(kiwi_item, 6))
	# AddToSelection (slot 4) and RemoveFromSelection (5) reach the flags
	# on the next frame.
	assert_equal(0, wu_call1(kiwi_item, 4))
	assert_equal(0, wu_call1(apple_item, 4))
	assert_equal(2, ui_access_uia_dispatch(bridge, tree))
	ui_access_tree* next = wu_capture(ctx, &m)
	wu_marks(c"1110", &m)
	assert_equal(1, ui_access_uia_publish(bridge, next))
	ui_access_tree_free(tree)
	tree = next
	assert_equal(3, wu_array(selection, 3, &a, &b))
	assert_equal(2, a)
	assert_equal(3, b)
	assert_equal(1, wu_get32(kiwi_item, 6))
	assert_equal(0, wu_call1(cherry_item, 5))
	assert_equal(1, ui_access_uia_dispatch(bridge, tree))
	next = wu_capture(ctx, &m)
	wu_marks(c"1010", &m)
	assert_equal(1, ui_access_uia_publish(bridge, next))
	ui_access_tree_free(tree)
	tree = next
	# Select (slot 3) selects that item alone.
	assert_equal(0, wu_call1(kiwi_item, 3))
	assert_equal(1, ui_access_uia_dispatch(bridge, tree))
	next = wu_capture(ctx, &m)
	wu_marks(c"0010", &m)
	assert_equal(1, ui_access_uia_publish(bridge, next))
	ui_access_tree_free(tree)
	tree = next
	assert_equal(1, wu_array(selection, 3, &a, &b))
	assert_equal(4, a)

	# The grid: header row, a row header over two rows, a cell over two
	# columns. Its cells have no widget id, so the expected ids come from
	# the snapshot.
	int table = wu_navigate(list, NavigateDirection_NextSibling)
	ui_access_node* table_node = ui_access_find(tree, wu_automation_id(table))
	asserts(c"table published", table_node != 0)
	assert_equal(UI_ACCESS_TABLE, table_node.role)
	ui_access_node* fruit_node = ui_access_table_cell_at(table_node, 0, 0)
	ui_access_node* cherry_node = ui_access_table_cell_at(table_node, 1, 2)
	ui_access_node* item_node = ui_access_row_cell(ui_access_header_row(table_node), 1)
	asserts(c"grid cells", (fruit_node != 0) && (cherry_node != 0) && (item_node != 0))
	int grid = wu_pattern(table, UIA_GridPatternId)
	asserts(c"Grid pattern", grid != 0)
	assert_equal(2, wu_get32(grid, 4))
	assert_equal(3, wu_get32(grid, 5))
	int cell = 0
	assert_equal(0, wu_call4(grid, 3, 1, 2, cast(int, &cell)))
	assert_equal(cherry_node.id, wu_automation_id(cell))
	int grid_item = wu_pattern(cell, UIA_GridItemPatternId)
	assert_equal(1, wu_get32(grid_item, 3))
	assert_equal(1, wu_get32(grid_item, 4))
	assert_equal(1, wu_get32(grid_item, 5))
	assert_equal(2, wu_get32(grid_item, 6))
	int table_item = wu_pattern(cell, UIA_TableItemPatternId)
	assert_equal(1, wu_array(table_item, 3, &a, &b))
	assert_equal(fruit_node.id, a)
	assert_equal(1, wu_array(table_item, 4, &a, &b))
	assert_equal(item_node.id, a)
	int table_pattern = wu_pattern(table, UIA_TablePatternId)
	assert_equal(1, wu_array(table_pattern, 3, &a, &b))
	assert_equal(fruit_node.id, a)
	int fruit = 0
	assert_equal(0, wu_call4(grid, 3, 0, 0, cast(int, &fruit)))
	assert_equal(fruit_node.id, wu_automation_id(fruit))
	assert_equal(UIA_HeaderItemControlTypeId, wu_i4(fruit, UIA_ControlTypePropertyId))
	int fruit_item = wu_pattern(fruit, UIA_GridItemPatternId)
	assert_equal(2, wu_get32(fruit_item, 5))

	wu_release(fruit_item)
	wu_release(fruit)
	wu_release(table_pattern)
	wu_release(table_item)
	wu_release(grid_item)
	wu_release(cell)
	wu_release(grid)
	wu_release(table)
	wu_release(kiwi_item)
	wu_release(apple_item)
	wu_release(cherry_item)
	wu_release(kiwi)
	wu_release(cherry)
	wu_release(apple)
	wu_release(selection)
	wu_release(list)
	wu_release(root)
	ui_access_uia_close(bridge)
	ui_access_tree_free(tree)
	ui_render_destroy(&fx.r)
	println(c"widgets UI Automation OK")
	return 0
