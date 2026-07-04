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
	raw_asm (c"\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90")


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
	char* s = c"a\n\t\rb"
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


void test_relational_values():
	assert_equal(1, 1 < 2)
	assert_equal(0, 2 < 1)
	assert_equal(1, 2 <= 2)
	assert_equal(0, 3 <= 2)
	assert_equal(1, 3 > 2)
	assert_equal(0, 2 > 3)
	assert_equal(1, 2 >= 2)
	assert_equal(0, 1 >= 2)


void test_relational_left_assoc():
	# a < b < c chains as (a < b) < c
	assert_equal(1, 1 < 2 < 3)
	assert_equal(0, 5 > 3 > 1)
	assert_equal(1, 5 > 3 >= 1)


void test_equality_values():
	assert_equal(1, 3 == 3)
	assert_equal(0, 3 == 4)
	assert_equal(1, 3 != 4)
	assert_equal(0, 3 != 3)
	assert_equal(1, 7 % 2 == 1)


void test_shift_operators():
	assert_equal(4, 1 << 2)
	assert_equal(4, 8 >> 1)
	assert_equal(2, 16 >> 2 >> 1)
	# additive binds tighter than shift: (1 + 2) << 3
	assert_equal(24, 1 + 2 << 3)


void test_bitwise_operators():
	assert_equal(2, 6 & 3)
	assert_equal(3, 1 | 2)
	assert_equal(7, 6 | 3)
	# & binds tighter than |: 4 | (6 & 1)
	assert_equal(4, 4 | 6 & 1)


void test_unary_chains():
	assert_equal(1, !!5)
	assert_equal(0, !!0)
	assert_equal(3, -(-3))


void test_unary_binds_tighter_than_binary():
	int a = 5
	# (-a) * 2 and (!a) * 3, not -(a * 2) or !(a * 3)
	assert_equal(-10, -a * 2)
	assert_equal(0, !a * 3)
	int z = 0
	assert_equal(3, !z * 3)


void test_unary_plus():
	assert_equal(5, +5)
	int a = 7
	assert_equal(7, +a)
	assert_equal(12, +a + +5)


void test_deref_of_address():
	int x = 42
	assert_equal(42, *&x)


void test_mixed_precedence():
	assert_equal(7, 1 + 2 * 3)
	assert_equal(1, 0 || 2 * 3)
	assert_equal(1, !0 && 1)
	assert_equal(-6, -2 * 3)


void test_else_if_without_parens():
	int a = 2
	int r = 0
	if a == 1:
		r = 1
	else if a == 2:
		r = 2
	else:
		r = 3
	assert_equal(2, r)


void test_empty_if_body_dedent():
	# A next line at the same indent means the if body is empty, so the
	# assignment below runs unconditionally
	int r = 0
	if (r == 5):
	r = 1
	assert_equal(1, r)


void test_pass_statement():
	int r = 0
	if (1):
		pass
	else:
		r = 1
	assert_equal(0, r)
	if (0): pass
	while (0): pass
	assert_equal(0, r)


void body_is_only_pass():
	pass


void test_pass_function_body():
	body_is_only_pass()
	assert_equal(1, 1)

