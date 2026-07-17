# wbuild: x64
# '++'/'--' increment and decrement statements (issue #103,
# docs/projects/increment_decrement.md): statement-position only, both
# prefix and postfix spellings, pure sugar for '+= 1'/'-= 1' through
# the compound-assignment lowering. Mirrors
# tests/compound_assign_test.w's lvalue-shape coverage; the
# expression-position and map-element rejections live in the
# increment_error_test fixtures.
import lib.testing


int g_count
char* g_cursor


struct inc_point:
	int x
	int y


void test_increment_int_locals():
	int a = 5
	a++
	assert_equal(6, a)
	a--
	assert_equal(5, a)
	++a
	assert_equal(6, a)
	--a
	assert_equal(5, a)


void test_increment_globals():
	g_count = 10
	g_count++
	assert_equal(11, g_count)
	--g_count
	assert_equal(10, g_count)
	g_count--
	assert_equal(9, g_count)
	++g_count
	assert_equal(10, g_count)


void test_increment_struct_field():
	inc_point p
	p.x = 3
	p.y = 7
	p.x++
	assert_equal(4, p.x)
	++p.y
	assert_equal(8, p.y)
	inc_point* q = &p
	q.x--
	assert_equal(3, p.x)
	--q.y
	assert_equal(7, p.y)


void test_increment_array_element():
	int[4] arr
	arr[0] = 1
	arr[1] = 2
	arr[2] = 3
	arr[3] = 4
	arr[1]++
	assert_equal(3, arr[1])
	int i = 2
	arr[i]++
	assert_equal(4, arr[2])
	--arr[i + 1]
	assert_equal(3, arr[3])


void test_increment_list_element():
	list[int] xs = list[int]{1, 2, 3}
	xs[1]++
	assert_equal(3, xs[1])
	--xs[2]
	assert_equal(2, xs[2])


void test_increment_pointer_deref():
	int v = 41
	int* p = &v
	# '*p++' binds like '*p += 1': the statement's lvalue is the whole
	# unary expression, so it increments the POINTEE — unlike C, where
	# postfix binds tighter and '*p++' means '*(p++)'. ('(*p)++' is
	# rejected like '(*p) += 1': grouping parens yield a value, not an
	# lvalue, so '++' keeps '+='s exact acceptance surface.)
	*p++
	assert_equal(42, v)
	++*p
	assert_equal(43, v)
	--*p
	assert_equal(42, v)
	*p--
	assert_equal(41, v)


void test_increment_pointer_steps_raw_bytes():
	# 'p++' advances by exactly 1 BYTE, not sizeof(T): '++' is sugar
	# for '+= 1' and W pointer arithmetic is unscaled — the same
	# contract test_compound_pointer_arithmetic pins for '+='
	# (docs/projects/increment_decrement.md §1.3 / open question 1).
	int[2] arr
	arr[0] = 0
	arr[1] = 0
	int* p = &arr[0]
	p++
	assert_equal(1, cast(int, p) - cast(int, &arr[0]))
	p--
	assert_equal(0, cast(int, p) - cast(int, &arr[0]))
	# on a char* the byte step is also the element step
	char* s = c"hello"
	g_cursor = s
	g_cursor++
	assert_equal('e', *g_cursor)
	++g_cursor
	assert_equal('l', *g_cursor)
	g_cursor--
	assert_equal('e', *g_cursor)


void test_increment_char_width():
	char c = 10
	c++
	assert_equal(11, c)
	# narrow store truncates, like 'c += 1' (test_compound_char_width):
	# 255 + 1 wraps to 0 in the byte
	c = 255
	c++
	assert_equal(0, c)
	# char loads sign-extend (promote_int8_eax): byte 0xff reads as -1
	c--
	assert_equal(-1, c)


void test_increment_float():
	# floats ride the same compound-assign lowering: 'f++' is 'f += 1'
	float f = 2.5
	f++
	assert1(f > 3.49)
	assert1(f < 3.51)
	f--
	assert1(f > 2.49)
	assert1(f < 2.51)


void test_increment_in_loop_body():
	int total = 0
	int i = 0
	while (i < 5):
		total += i
		i++
	assert_equal(10, total)
	for int j in range(0, 3):
		total++
	assert_equal(13, total)
	# decrement-driven loop
	int n = 4
	int steps = 0
	while (n > 0):
		n--
		steps++
	assert_equal(4, steps)
	assert_equal(0, n)


void test_increment_then_prefix_next_line():
	# a '++' opening a line is that statement's own prefix operator,
	# never a postfix continuation of the line above
	int a = 1
	int b = a
	++b
	assert_equal(1, a)
	assert_equal(2, b)
