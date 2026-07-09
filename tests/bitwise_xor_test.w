import lib.testing


int xor_global


void test_basic_xor():
	int a = 12
	int b = 10
	assert_equal(6, a ^ b)
	assert_equal(0, a ^ a)
	assert_equal(12, a ^ 0)


void test_left_associative_chain():
	# (1 ^ 3) ^ 5 = 2 ^ 5 = 7
	assert_equal(7, 1 ^ 3 ^ 5)


void test_precedence_between_and_and_or():
	# & binds tighter than ^, and ^ binds tighter than |
	# 12 & 10 ^ 3 = (12 & 10) ^ 3 = 8 ^ 3 = 11
	assert_equal(11, 12 & 10 ^ 3)
	# 12 ^ 10 | 3 = (12 ^ 10) | 3 = 6 | 3 = 7
	assert_equal(7, 12 ^ 10 | 3)
	# 1 | 2 ^ 2 = 1 | (2 ^ 2) = 1
	assert_equal(1, 1 | 2 ^ 2)


void test_precedence_below_equality():
	# equality binds tighter: 5 ^ 3 == 3 is 5 ^ (3 == 3) = 5 ^ 1 = 4
	assert_equal(4, 5 ^ 3 == 3)


void test_negative_operands():
	assert_equal(-1, -1 ^ 0)
	assert_equal(-13, 5 ^ -10)
	assert_equal(5, -10 ^ -13)


void test_globals_and_compound_assign_agree():
	xor_global = 12
	int direct = xor_global ^ 10
	xor_global ^= 10
	assert_equal(direct, xor_global)


void test_xor_in_conditions():
	int flips = 0
	if (5 ^ 5):
		flips = 1
	assert_equal(0, flips)
	if (5 ^ 4):
		flips = 1
	assert_equal(1, flips)


void test_bit_flipping():
	int mask = 255
	int value = 170
	assert_equal(85, value ^ mask)
	assert_equal(value, value ^ mask ^ mask)
