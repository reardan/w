import lib.testing
import lib.math


struct inf_point:
	int x
	int y


inf_point inf_make_point(int x, int y):
	inf_point p
	p.x = x
	p.y = y
	return p


int inf_add(int a, int b):
	return a + b


void test_infer_int_and_constant():
	x := 5
	assert_equal(5, x)
	y := x * 2 + 1
	assert_equal(11, y)
	x = 40
	assert_equal(51, x + y)


void test_infer_char_and_bool():
	c := 'a'
	assert_equal(97, c)
	b := true
	assert_equal(1, b)


void test_infer_from_call():
	n := inf_add(20, 22)
	assert_equal(42, n)
	m := max(3, 9)
	assert_equal(9, m)


void test_infer_cstr_and_string():
	s := c"hello"
	assert_equal('h', s[0])
	assert_equal(5, strlen(s))
	t := s"world"
	assert_equal(5, t.length)


void test_infer_float():
	f := 1.5
	g := f + 2.25
	assert_equal(3, cast(int, g * 1.0))


void test_infer_pointer():
	int v = 7
	p := &v
	assert_equal(7, *p)
	*p = 9
	assert_equal(9, v)


void test_infer_struct_value():
	pt := inf_make_point(3, 4)
	assert_equal(3, pt.x)
	assert_equal(4, pt.y)
	pt.y = 5
	assert_equal(5, pt.y)


void test_infer_struct_copy():
	inf_point a
	a.x = 1
	a.y = 2
	b := a
	b.x = 10
	assert_equal(1, a.x)
	assert_equal(10, b.x)


void test_infer_new_struct():
	pp := new inf_point(6, 7)
	assert_equal(6, pp.x)
	assert_equal(7, pp.y)


void test_infer_containers():
	l := list[int]{1, 2, 3}
	assert_equal(3, l.length)
	l.push(4)
	assert_equal(4, l.length)
	m := map[int, int]{1: 10, 2: 20}
	assert_equal(20, m[2])
	s := set[int]{5, 6}
	assert_equal(1, 5 in s)


void test_infer_in_blocks_and_loops():
	total := 0
	for int i in range(4):
		doubled := i * 2
		total += doubled
	assert_equal(12, total)
	if (total > 0):
		inner := total + 1
		assert_equal(13, inner)


void test_infer_not_confused_with_statements():
	# Plain assignments and calls still parse after the ':=' lookahead
	int a = 1
	a = 2
	assert_equal(2, a)
	a += 3
	assert_equal(5, a)
	b := a
	b = 6
	assert_equal(6, b)
	assert_equal(5, a)
