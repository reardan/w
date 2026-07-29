# wbuild: x64
# Parallel assignment 'a, b = b, a + b' (issue #360 item 6,
# grammar/multi_assign.w): statement-position sugar where every right-
# hand element is evaluated into a temporary before any store, then the
# stores run left to right. Mirrors tests/compound_assign_test.w's
# lvalue-shape coverage; the arity and target rejections live in the
# multi_assign_error_test fixtures.
import lib.testing


int g_first
int g_second


struct ma_point:
	int x
	int y


void test_swap():
	int a = 1
	int b = 2
	a, b = b, a
	assert_equal(2, a)
	assert_equal(1, b)


void test_rhs_evaluates_before_stores():
	# From known values: with a stored first, a naive left-to-right
	# lowering would compute a + b as 5 + 5 = 10; the parked
	# temporaries keep the OLD a, so b must become 3 + 5 = 8.
	int a = 3
	int b = 5
	a, b = b, a + b
	assert_equal(5, a)
	assert_equal(8, b)


void test_fibonacci_loop():
	int a = 0
	int b = 1
	int i = 0
	while (i < 10):
		a, b = b, a + b
		i = i + 1
	assert_equal(55, a)
	assert_equal(89, b)


void test_three_way_rotate():
	int x = 1
	int y = 2
	int z = 3
	x, y, z = z, x, y
	assert_equal(3, x)
	assert_equal(1, y)
	assert_equal(2, z)


void test_stores_run_left_to_right():
	# The same target twice: both parked values store, left to right,
	# so the rightmost value wins.
	int a = 0
	a, a = 1, 2
	assert_equal(2, a)


void test_globals():
	g_first = 10
	g_second = 20
	g_first, g_second = g_second, g_first
	assert_equal(20, g_first)
	assert_equal(10, g_second)


void test_indexed_elements():
	int[4] arr
	arr[0] = 100
	arr[1] = 200
	arr[2] = 300
	arr[3] = 400
	arr[0], arr[3] = arr[3], arr[0]
	assert_equal(400, arr[0])
	assert_equal(100, arr[3])
	# index expressions on both sides read pre-assignment state
	int i = 1
	arr[i], i = i, arr[i]
	assert_equal(1, arr[1])
	assert_equal(200, i)


void test_struct_fields():
	ma_point p
	p.x = 1
	p.y = 2
	p.x, p.y = p.y, p.x
	assert_equal(2, p.x)
	assert_equal(1, p.y)


void test_pointer_targets():
	int a = 1
	int b = 2
	int* pa = &a
	int* pb = &b
	*pa, *pb = *pb, *pa
	assert_equal(2, a)
	assert_equal(1, b)
	# pointers themselves are word-sized values and swap too
	pa, pb = pb, pa
	assert_equal(1, *pa)
	assert_equal(2, *pb)


void test_char_sized_targets():
	# sub-word stores size by each target's own type
	char c1 = 'a'
	char c2 = 'z'
	c1, c2 = c2, c1
	assert_equal('z', c1)
	assert_equal('a', c2)


int ma_forty():
	return 40


int ma_two():
	return 2


void test_call_values():
	int a = 0
	int b = 0
	a, b = ma_forty(), ma_two()
	assert_equal(40, a)
	assert_equal(2, b)
	assert_equal(42, a + b)


void test_mixed_target_shapes():
	int[2] arr
	arr[0] = 5
	ma_point p
	p.x = 6
	int local = 7
	arr[0], p.x, local = local, arr[0], p.x
	assert_equal(7, arr[0])
	assert_equal(5, p.x)
	assert_equal(6, local)
