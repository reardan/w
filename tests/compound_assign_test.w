# wbuild: x64
import lib.testing


int g_total
char* g_cursor


struct ca_point:
	int x
	int y


void test_compound_int_locals():
	int a = 10
	a += 5
	assert_equal(15, a)
	a -= 2
	assert_equal(13, a)
	a *= 3
	assert_equal(39, a)
	a /= 2
	assert_equal(19, a)
	a %= 7
	assert_equal(5, a)
	a |= 8
	assert_equal(13, a)
	a &= 12
	assert_equal(12, a)
	a ^= 5
	assert_equal(9, a)
	a <<= 2
	assert_equal(36, a)
	a >>= 1
	assert_equal(18, a)


# arm64 regression for #174: arm64_add_x9_imm pre-set imm12 bit 0 in its
# base word, so any even immediate in 1..4095 reaching it encoded
# #(imm|1) — off by one. Odd immediates (the ±1 hot path) masked it.
# Sweep even constants across the add/sub immediate range on locals,
# globals and pointer targets, the operand shapes the [wsp+k] += imm
# fast path serves.
void test_compound_even_constants():
	int a = 100
	a += 2
	assert_equal(102, a)
	a -= 16
	assert_equal(86, a)
	a += 4094
	assert_equal(4180, a)
	a -= 4094
	assert_equal(86, a)
	a -= 2
	assert_equal(84, a)
	g_total = 50
	g_total += 8
	assert_equal(58, g_total)
	g_total -= 40
	assert_equal(18, g_total)
	int v = 6
	int* p = &v
	*p += 10
	assert_equal(16, v)
	*p -= 4
	assert_equal(12, v)


void test_compound_negative_operands():
	int d = -7
	d /= 2
	assert_equal(-3, d)
	int m = -7
	m %= 2
	assert_equal(-1, m)
	int neg = -8
	neg >>= 1  # arithmetic shift, like '>>'
	assert_equal(-4, neg)


void test_compound_globals():
	g_total = 100
	g_total += 20
	assert_equal(120, g_total)
	g_total /= 6
	assert_equal(20, g_total)
	g_total <<= 1
	assert_equal(40, g_total)


void test_compound_pointer_deref():
	int v = 40
	int* p = &v
	*p += 2
	assert_equal(42, v)
	*p *= 2
	assert_equal(84, v)


void test_compound_array_element():
	int[4] arr
	arr[0] = 1
	arr[1] = 2
	arr[2] = 3
	arr[3] = 4
	arr[1] += 7
	assert_equal(9, arr[1])
	int i = 2
	arr[i] <<= 4
	assert_equal(48, arr[2])
	arr[i + 1] ^= 6  # 4 ^ 6 == 2
	assert_equal(2, arr[3])


void test_compound_list_element():
	list[int] xs = list[int]{1, 2, 3}
	xs[1] *= 5
	assert_equal(10, xs[1])
	xs[0] += xs[2]
	assert_equal(4, xs[0])


void test_compound_struct_field():
	ca_point p
	p.x = 3
	p.y = 4
	p.x += 5
	assert_equal(8, p.x)
	p.y *= p.x
	assert_equal(32, p.y)
	ca_point* q = &p
	q.x -= 6
	assert_equal(2, p.x)


void test_compound_char_width():
	char c = 10
	c += 5
	assert_equal(15, c)
	# narrow store: only the low byte lands in the char
	c += 250
	assert_equal(9, c)


void test_compound_pointer_arithmetic():
	# 'p += n' advances by n bytes, exactly like 'p = p + n'
	char* s = c"hello"
	char* p = s
	p += 2
	assert_equal('l', *p)
	# global pointer lhs too
	g_cursor = s
	g_cursor += 4
	assert_equal('o', *g_cursor)


void test_compound_precedence():
	int a = 1
	int b = 5
	a += b * 2  # rhs binds tighter: a + (b * 2)
	assert_equal(11, a)
	a -= b - 2
	assert_equal(8, a)


void test_compound_yields_value():
	int a = 4
	int r = (a += 3)
	assert_equal(7, a)
	assert_equal(7, r)
	int b = 2
	r = (b <<= 3)
	assert_equal(16, b)
	assert_equal(16, r)


void test_compound_float():
	float f = 2.5
	f += 1.25
	f *= 2.0
	f -= 0.5
	f /= 7.0
	int in_range = 0
	if (f > 0.99):
		if (f < 1.01):
			in_range = 1
	assert_equal(1, in_range)
	# int rhs coerces like the plain binary operators
	float g = 1.5
	g *= 4
	assert_equal(6, cast(int, g))
	# float rhs on an int lhs truncates on the store, like 'i = i + 0.75'
	int i = 3
	i += 0.75
	assert_equal(3, i)


void test_compound_in_condition():
	int n = 5
	int iterations = 0
	while ((n -= 1) > 0):
		iterations += 1
	assert_equal(4, iterations)
	assert_equal(0, n)
