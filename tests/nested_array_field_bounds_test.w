# wbuild: x64 arch=arm64 arch=wasm
# wbuild: step="bin/wv2 --streaming tests/nested_array_field_bounds_test.w -o bin/nested_array_field_bounds_streaming_test"
# wbuild: step="bin/nested_array_field_bounds_streaming_test"
# wbuild: step="bin/wv2 x64 --streaming tests/nested_array_field_bounds_test.w -o bin/nested_array_field_bounds_streaming_64_test"
# wbuild: step="bin/nested_array_field_bounds_streaming_64_test"
import lib.testing

/*
Issue #701: a fixed array is a {data, length} header followed by its
elements, and the header is written when the storage is created. Only
the outermost header used to be written, so an array whose elements hold
arrays themselves (a struct with a fixed-array field, or an inner T[N])
left every element's headers zeroed: panes[1].nums[3] trapped with
"index out of range: index 3, length 0". Each storage shape builds the
headers separately (stack locals, globals, struct copies, 'new T',
'new T[n]', constructors), so each one is covered here, under both front
ends.
*/


struct nab_item:
	int v


struct nab_pane:
	int[16] nums
	nab_item*[4] items


struct nab_gui:
	int tag
	nab_pane[2] panes


struct nab_leaf:
	int[3] c


struct nab_mid:
	char pad
	nab_leaf[2] b


struct nab_top:
	nab_mid[2] a


nab_pane[3] nab_global_panes
nab_gui nab_global_gui
int[4][3] nab_global_grid
nab_top nab_global_top


int nab_sum_gui(nab_gui g):
	return g.panes[1].nums[3] + g.panes[0].nums.length


int nab_third(nab_pane[] ps):
	return ps[1].nums[3]


int nab_count():
	return 3


void test_issue_repro():
	nab_pane[2] panes
	panes[1].nums[3] = 5
	assert_equal(5, panes[1].nums[3])
	assert_equal(16, panes[1].nums.length)
	assert_equal(16, panes[0].nums.length)
	assert_equal(4, panes[1].items.length)


void test_pointer_array_field():
	nab_pane[2] panes
	nab_item it
	it.v = 7
	panes[0].items[2] = &it
	assert_equal(7, panes[0].items[2].v)


void test_struct_field_of_array_type():
	nab_gui g
	g.panes[1].nums[15] = 9
	assert_equal(9, g.panes[1].nums[15])
	nab_pane* p = &g.panes[0]
	p.nums[0] = 4
	assert_equal(4, g.panes[0].nums[0])
	nab_pane* q = &g.panes[1]
	assert_equal(9, q.nums[15])


void test_three_levels():
	nab_top t
	t.a[1].b[1].c[2] = 11
	t.a[0].b[0].c[0] = 12
	assert_equal(11, t.a[1].b[1].c[2])
	assert_equal(12, t.a[0].b[0].c[0])
	assert_equal(3, t.a[1].b[0].c.length)
	assert_equal(2, t.a[1].b.length)


void test_array_of_arrays():
	int[4][3] grid
	for i in range(3):
		for j in range(4): grid[i][j] = i * 10 + j
	assert_equal(23, grid[2][3])
	assert_equal(4, grid[1].length)
	assert_equal(3, grid.length)


void test_many_elements():
	nab_pane[40] many
	for i in range(40): many[i].nums[15] = i
	for i in range(40): assert_equal(i, many[i].nums[15])


void test_globals():
	nab_global_panes[2].nums[7] = 3
	assert_equal(3, nab_global_panes[2].nums[7])
	nab_global_gui.panes[1].nums[2] = 6
	assert_equal(6, nab_global_gui.panes[1].nums[2])
	nab_global_grid[1][2] = 1
	assert_equal(1, nab_global_grid[1][2])
	nab_global_top.a[1].b[1].c[1] = 2
	assert_equal(2, nab_global_top.a[1].b[1].c[1])
	assert_equal(16, nab_global_panes[0].nums.length)


void test_copies_own_their_storage():
	nab_gui g
	g.panes[1].nums[15] = 9
	g.panes[1].nums[3] = 9
	nab_gui h = g
	h.panes[1].nums[15] = 1
	assert_equal(9, g.panes[1].nums[15])
	assert_equal(1, h.panes[1].nums[15])
	assert_equal(25, nab_sum_gui(g))
	nab_gui[2] gs
	gs[1] = g
	assert_equal(9, gs[1].panes[1].nums[15])
	gs[1].panes[1].nums[15] = 3
	assert_equal(9, g.panes[1].nums[15])


void test_heap_and_slices():
	nab_gui* hp = new nab_gui
	hp.panes[1].nums[5] = 2
	assert_equal(2, hp.panes[1].nums[5])
	nab_pane[2] panes
	panes[1].nums[3] = 5
	nab_pane[] s = panes
	assert_equal(5, s[1].nums[3])
	assert_equal(5, nab_third(panes))
	nab_pane[] ps = new nab_pane[nab_count()]
	ps[2].nums[3] = 5
	assert_equal(5, ps[2].nums[3])
	assert_equal(16, ps[0].nums.length)
	nab_gui[] gs = new nab_gui[2]
	gs[1].panes[1].nums[4] = 6
	assert_equal(6, gs[1].panes[1].nums[4])
	nab_pane[] none = new nab_pane[0]
	assert_equal(0, none.length)


void test_constructor():
	nab_gui g = nab_gui()
	g.panes[1].nums[3] = 2
	assert_equal(2, g.panes[1].nums[3])
	nab_gui* hp = new nab_gui()
	hp.panes[0].nums[1] = 8
	assert_equal(8, hp.panes[0].nums[1])
