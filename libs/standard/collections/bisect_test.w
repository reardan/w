# wbuild: x64
# wbuild: step="bin/bisect_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import libs.standard.collections.bisect


struct bisect_pt:
	int x
	int y


bisect_pt* bisect_pt_new(int x, int y):
	bisect_pt* p = new bisect_pt
	p.x = x
	p.y = y
	return p


int bisect_pt_cmp(int a, int b):
	bisect_pt* pa = cast(bisect_pt*, a)
	bisect_pt* pb = cast(bisect_pt*, b)
	if (pa.x != pb.x): return pa.x - pb.x
	return pa.y - pb.y


int int_desc_cmp(int a, int b):
	return b - a


int abs_key(int v):
	if (v < 0): return 0 - v
	return v


void assert_ints(list[int] want, list[int] got):
	assert_equal(want.length, got.length)
	for i in range(want.length):
		assert_equal(want[i], got[i])


void test_bisect_empty():
	list[int] a = new list[int]
	assert_equal(0, bisect_left(a, 5))
	assert_equal(0, bisect_right(a, 5))
	a.free()


void test_bisect_left_right_python_cases():
	# Python: a = [1, 2, 2, 2, 3, 5]
	list[int] a = list[int]{1, 2, 2, 2, 3, 5}
	assert_equal(1, bisect_left(a, 2))
	assert_equal(4, bisect_right(a, 2))
	assert_equal(4, bisect(a, 2))
	assert_equal(0, bisect_left(a, 0))
	assert_equal(0, bisect_right(a, 0))
	assert_equal(0, bisect_left(a, 1))
	assert_equal(1, bisect_right(a, 1))
	assert_equal(5, bisect_left(a, 4))
	assert_equal(5, bisect_right(a, 4))
	assert_equal(5, bisect_left(a, 5))
	assert_equal(6, bisect_right(a, 5))
	assert_equal(6, bisect_left(a, 99))
	assert_equal(6, bisect_right(a, 99))
	a.free()


void test_bisect_negatives():
	list[int] a = list[int]{-10, -5, -5, 0, 7}
	assert_equal(1, bisect_left(a, -5))
	assert_equal(3, bisect_right(a, -5))
	assert_equal(0, bisect_left(a, -11))
	assert_equal(3, bisect_left(a, -1))
	a.free()


void test_bisect_lo_hi():
	# bisect.bisect_left([1,2,2,2,3,5], 2, 2) == 2
	# bisect.bisect_right([1,2,2,2,3,5], 2, 0, 3) == 3
	# bisect.bisect_left([1,2,2,2,3,5], 9, 1, 4) == 4
	# bisect.bisect_left([1,2,2,2,3,5], 0, 3) == 3
	# bisect.bisect_left([1,2,2,2,3,5], 2, 4, 2) == 4   (hi < lo)
	list[int] a = list[int]{1, 2, 2, 2, 3, 5}
	assert_equal(2, bisect_left(a, 2, 2))
	assert_equal(3, bisect_right(a, 2, 0, 3))
	assert_equal(4, bisect_left(a, 9, 1, 4))
	assert_equal(3, bisect_left(a, 0, 3))
	assert_equal(4, bisect_left(a, 2, 4, 2))
	assert_equal(6, bisect_right(a, 2, 6))
	assert_equal(0, bisect_right(a, 9, 0, 0))
	a.free()


void test_insort_keeps_sorted():
	list[int] a = new list[int]
	list[int] input = list[int]{5, 1, 4, 1, 5, 9, 2, 6, 5, 3}
	for int v in input: insort(a, v)
	list[int] want = list[int]{1, 1, 2, 3, 4, 5, 5, 5, 6, 9}
	assert_ints(want, a)
	want.free()
	input.free()
	a.free()


void test_insort_left_vs_right_with_comparator_identity():
	# Distinguish left/right placement by inserting equal keys whose
	# pointers differ (the comparator only looks at x).
	list[bisect_pt*] pts = new list[bisect_pt*]
	bisect_pt* a = bisect_pt_new(1, 0)
	bisect_pt* b = bisect_pt_new(2, 0)
	bisect_pt* c = bisect_pt_new(2, 0)
	bisect_pt* d = bisect_pt_new(2, 0)
	insort_by[bisect_pt*](pts, a, bisect_pt_cmp, 0, -1)
	insort_by[bisect_pt*](pts, b, bisect_pt_cmp, 0, -1)
	insort_right_by[bisect_pt*](pts, c, bisect_pt_cmp, 0, -1)
	insort_left_by[bisect_pt*](pts, d, bisect_pt_cmp, 0, -1)
	# order: a, d (left of equal run), b, c (right of b)
	assert_equal(4, pts.length)
	asserts(c"pts[0] is a", pts[0] == a)
	asserts(c"pts[1] is d", pts[1] == d)
	asserts(c"pts[2] is b", pts[2] == b)
	asserts(c"pts[3] is c", pts[3] == c)
	assert_equal(1, bisect_left_by[bisect_pt*](pts, b, bisect_pt_cmp, 0, -1))
	assert_equal(4, bisect_right_by[bisect_pt*](pts, b, bisect_pt_cmp, 0, -1))
	assert_equal(2, bisect_right_by[bisect_pt*](pts, b, bisect_pt_cmp, 0, 2))
	assert_equal(3, bisect_left_by[bisect_pt*](pts, b, bisect_pt_cmp, 3, -1))
	free(a)
	free(b)
	free(c)
	free(d)
	pts.free()


void test_insort_left_right_ints():
	list[int] a = list[int]{1, 3, 3, 5}
	insort_left(a, 3)
	insort_right(a, 4)
	insort_left(a, 0)
	insort_right(a, 6)
	list[int] want = list[int]{0, 1, 3, 3, 3, 4, 5, 6}
	assert_ints(want, a)
	# bounded insort: Python insort([0,1,3,3,3,4,5,6], 9, 0, 2) -> index 2
	insort(a, 9, 0, 2)
	assert_equal(9, a[2])
	assert_equal(9, a.length)
	want.free()
	a.free()


void test_comparator_descending_ints():
	list[int] a = list[int]{9, 7, 7, 3, 1}
	assert_equal(1, bisect_left_by[int](a, 7, int_desc_cmp, 0, -1))
	assert_equal(3, bisect_right_by[int](a, 7, int_desc_cmp, 0, -1))
	assert_equal(0, bisect_left_by[int](a, 10, int_desc_cmp, 0, -1))
	assert_equal(5, bisect_left_by[int](a, 0, int_desc_cmp, 0, -1))
	insort_by[int](a, 5, int_desc_cmp, 0, -1)
	list[int] want = list[int]{9, 7, 7, 5, 3, 1}
	assert_ints(want, a)
	want.free()
	a.free()


void test_strings():
	list[char*] a = list[char*]{c"apple", c"banana", c"banana", c"cherry"}
	assert_equal(1, bisect_left_str(a, c"banana"))
	assert_equal(3, bisect_right_str(a, c"banana"))
	assert_equal(0, bisect_left_str(a, c"Zebra")) /* uppercase sorts first */
	assert_equal(1, bisect_left_str(a, c"apples"))
	assert_equal(4, bisect_right_str(a, c"date"))
	assert_equal(2, bisect_right_str(a, c"banana", 0, 2))
	insort_str(a, c"blueberry")
	insort_left_str(a, c"")
	insort_right_str(a, c"zucchini")
	assert_equal(7, a.length)
	assert_strings_equal(c"", a[0])
	assert_strings_equal(c"apple", a[1])
	assert_strings_equal(c"banana", a[2])
	assert_strings_equal(c"banana", a[3])
	assert_strings_equal(c"blueberry", a[4])
	assert_strings_equal(c"cherry", a[5])
	assert_strings_equal(c"zucchini", a[6])
	a.free()


void test_key_function():
	# Python: a = [0, -1, 2, -3, 3, -5] sorted by abs; key=abs
	# bisect_left(a, 3, key=abs) == 3; bisect_right(a, 3, key=abs) == 5
	list[int] a = list[int]{0, -1, 2, -3, 3, -5}
	assert_equal(3, bisect_left_key(a, 3, abs_key))
	assert_equal(5, bisect_right_key(a, 3, abs_key))
	assert_equal(6, bisect_right_key(a, 5, abs_key))
	assert_equal(0, bisect_left_key(a, 0, abs_key))
	assert_equal(1, bisect_right_key(a, 0, abs_key))
	assert_equal(4, bisect_left_key(a, 3, abs_key, 4))
	a.free()


void test_raw_int_arrays():
	int[6] v
	v[0] = 1
	v[1] = 2
	v[2] = 2
	v[3] = 2
	v[4] = 3
	v[5] = 5
	assert_equal(1, bisect_left_int(v, 6, 2))
	assert_equal(4, bisect_right_int(v, 6, 2))
	assert_equal(0, bisect_left_int(v, 0, 2))
	assert_equal(6, bisect_right_int(v, 6, 7))


void test_brute_force_agreement():
	# Every x in [-1, 6] against a sorted list with repeats: left index
	# counts elements < x, right counts elements <= x.
	list[int] a = list[int]{0, 0, 1, 3, 3, 3, 5}
	for x in range(-1, 7):
		int lt = 0
		int le = 0
		for int v in a:
			if (v < x): lt = lt + 1
			if (v <= x): le = le + 1
		assert_equal(lt, bisect_left(a, x))
		assert_equal(le, bisect_right(a, x))
	a.free()
