# wbuild: x64
/*
Boundary integer literals stay legal: grammar/int_literal.w rejects
literals with more than 32 bits of significance (the rejection
fixtures are tests/int_literal_overflow_*_fixture.w), and significance
ignores leading zeros, so 0x00000000ffffffff still decodes. The
wrapped decodings themselves are unchanged: 0xffffffff and 4294967295
are -1 on every target because the compiler decodes literals in a
32-bit word and the word-sized int sign-extends. cast(int, ...)
suppresses the bit-31 warning where the top bit is intentional.
*/
import lib.testing


void test_hex_bounds():
	assert_equal(2147483647, 0x7fffffff)
	assert_equal(-1, cast(int, 0xffffffff))
	# leading zeros carry no significance: 16 digits spelled, 32 bits used
	assert_equal(-1, cast(int, 0x00000000ffffffff))
	assert_equal(255, 0x00000000000000ff)


void test_decimal_bounds():
	assert_equal(2147483647, 2147483647)
	# the largest legal decimal literal; wraps to -1 in the 32-bit decode
	assert_equal(-1, cast(int, 4294967295))
	assert_equal(cast(int, 0xffffffff), cast(int, 4294967295))
	# a negative literal is '-' applied to the positive form, so the
	# positive bound is what the overflow check enforces
	assert_equal(0 - 2147483647, -2147483647)


void test_binary_bounds():
	assert_equal(2147483647, 0b1111111111111111111111111111111)
	# 32 one-bits: the widest legal binary literal, -1 on every target
	assert_equal(-1, cast(int, 0b11111111111111111111111111111111))
	# leading zeros are insignificant: 35 digits spelled, 32 significant
	assert_equal(-1, cast(int, 0b00011111111111111111111111111111111))
