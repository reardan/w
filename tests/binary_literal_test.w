# wbuild: x64
/*
0b binary integer literals (#249): decoded by grammar/int_literal.w the
same way as the 0x hex path — including the leading minus sign — and
usable anywhere an int literal is. Literals stay below bit 31 (the
repo-wide rule for hex literals applies to binary too). '_' digit
separators are a possible follow-up.
*/
import lib.testing


void test_binary_literal_values():
	assert_equal(0, 0b0)
	assert_equal(1, 0b1)
	assert_equal(2, 0b10)
	assert_equal(5, 0b101)
	assert_equal(10, 0b1010)
	assert_equal(255, 0b11111111)
	assert_equal(0x2d, 0b101101)
	assert_equal(1234567890, 0b1001001100101100000001011010010)


void test_binary_literal_boundaries():
	# 30 and 31 significant bits; bit 31 itself stays out of source
	# literals (the hex-literal sign-extension rule applies to 0b too)
	assert_equal(1 << 30, 0b1000000000000000000000000000000)
	assert_equal((1 << 31) - 1, 0b1111111111111111111111111111111)
	assert_equal(2147483647, 0b1111111111111111111111111111111)
	# leading zeros are insignificant
	assert_equal(6, 0b00000110)


void test_binary_literal_negative():
	# the minus sign folds into the literal, mirroring -0x1f
	assert_equal(-5, -0b101)
	assert_equal(0 - 5, -0b101)
	assert_equal(-1, -0b1)
	assert_equal(0 - 2147483647, -0b1111111111111111111111111111111)
	assert_equal(-0x1f, -0b11111)


void test_binary_literals_in_expressions():
	assert_equal(3, 0b1 + 0b10)
	assert_equal(0b1000, 0b1 << 3)
	assert_equal(0b1010 & 0b0110, 0b0010)
	assert_equal(0b1010 | 0b0110, 0b1110)
	assert_equal(8, 0b1010 - 0b10)
	int x = 0b110
	assert_equal(6, x)
	if (0b1):
		x = 0b111
	assert_equal(7, x)
