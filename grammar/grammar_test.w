import lib.testing
import lib.testing


void test_arithmetic():
	assert_equal(7, 3 + 2 * 2)
	assert_equal(7, 2 * 2 + 3)


void test_division():
	assert_equal(3, 7 / 2)
	assert_equal(0, 1 / 2)
	int a = -7
	assert_equal(-3, a / 2)
	assert_equal(3, a / -2)
	int b = 7
	assert_equal(-3, b / -2)


void test_modulus():
	assert_equal(1, 7 % 2)
	assert_equal(0, 6 % 2)
	assert_equal(2, 12 % 5)
	int a = -7
	assert_equal(-1, a % 2)
	assert_equal(-1, a % -2)
	int b = 7
	assert_equal(1, b % -2)


void test_raw_asm():
	raw_asm ("\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90")


int func1():
	return 99


int func2(int* f):
	return f()

void test_func_pointer_argument():
	int *f = func1
	int got = func2(f)
	assert_equal(99, got)


void test_func_argument_direct():
	int got = func2(func1)
	assert_equal(99, got)


void test_func_pointer_variable():
	int *f = func1
	int got = f()
	assert_equal(99, got)


void test_int_literals():
	int a = 0
	assert_equal(0, a)
	a = a + 5
	assert_equal(5, a)
	a = a + 5
	assert_equal(10, a)
	a = a + 7
	assert_equal(17, a)

	int b = 0
	b = b - 1
	assert_equal(-1, b)

	int c = -1
	assert_equal(-1, b)
	assert_equal(1, c + 2)

void test_end_of_line_comments():
	assert_equal(0, 0) /* block comment */
	assert_equal(0, 0) # line comment
	assert_equal(1, 1) #


int side_effect_counter

int bump():
	side_effect_counter = side_effect_counter + 1
	return 1

int zero():
	side_effect_counter = side_effect_counter + 1
	return 0


void test_logical_and():
	assert_equal(1, 1 && 1)
	assert_equal(0, 1 && 0)
	assert_equal(0, 0 && 1)
	assert_equal(0, 0 && 0)
	assert_equal(1, 2 && 3) /* booleanized, not bitwise */
	assert_equal(1, 1 && 1 && 1)
	assert_equal(0, 1 && 1 && 0)


void test_logical_and_short_circuit():
	side_effect_counter = 0
	int r = zero() && bump()
	assert_equal(0, r)
	assert_equal(1, side_effect_counter) /* bump() must not run */


void test_logical_or():
	assert_equal(1, 1 || 0)
	assert_equal(1, 0 || 1)
	assert_equal(0, 0 || 0)
	assert_equal(1, 2 || 0) /* booleanized, not bitwise */
	assert_equal(1, 0 || 0 || 3)


void test_logical_or_short_circuit():
	side_effect_counter = 0
	int r = bump() || bump()
	assert_equal(1, r)
	assert_equal(1, side_effect_counter) /* second bump() must not run */


void test_unary_minus():
	int a = 5
	assert_equal(-5, -a)
	assert_equal(5, -(-a))
	assert_equal(-10, -a * 2)
	assert_equal(-4, 1 + -a)
	assert_equal(0, a + -5)


void test_hex_literals():
	assert_equal(31, 0x1f)
	assert_equal(255, 0xff)
	assert_equal(4096, 0x1000)
	assert_equal(0, 0x0)
	int a = 0x10
	assert_equal(16, a)
	assert_equal(-16, -0x10)


void test_string_escapes():
	char* s = "a\n\t\rb"
	assert_equal_hex('a', s[0])
	assert_equal_hex(10, s[1])
	assert_equal_hex(9, s[2])
	assert_equal_hex(13, s[3])
	assert_equal_hex('b', s[4])
	assert_equal_hex(0, s[5])


void test_char_escapes():
	assert_equal(10, '\n')
	assert_equal(9, '\t')
	assert_equal(13, '\r')
	assert_equal(0, '\0')
	assert_equal(92, '\\')


void test_capital_identifiers():
	int BigName = 3
	int _underscore = 4
	assert_equal(7, BigName + _underscore)


void test_while_break():
	int i = 0
	while (1):
		i = i + 1
		if (i == 5):
			break
	assert_equal(5, i)


void test_while_continue():
	int i = 0
	int c = 0
	while (i < 10):
		i = i + 1
		if (i % 2 == 0):
			continue
		c = c + 1
	assert_equal(5, c)


void test_while_without_parens():
	int i = 0
	while i < 3:
		i = i + 1
	assert_equal(3, i)


void test_if_without_parens():
	int r = 0
	if 1 < 2:
		r = 5
	assert_equal(5, r)


void test_single_line_if():
	int r = 0
	if (1): r = 7
	assert_equal(7, r)


int nested_if_else(int a, int b):
	if (a):
		if (b):
			return 3
	else:
		return 2
	return 1


void test_nested_if_else_binding():
	# The else is indented at the outer if's level, so it must bind there
	assert_equal(3, nested_if_else(1, 1))
	assert_equal(1, nested_if_else(1, 0))
	assert_equal(2, nested_if_else(0, 0))
	assert_equal(2, nested_if_else(0, 1))


void test_not_operator():
	assert_equal(1, !0)
	assert_equal(0, !1)
	assert_equal(0, !5)
	int a = 0
	assert_equal(1, !a)

