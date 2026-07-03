import lib.testing


void test_basic_float32_literals():
	int one = 1.0
	assert_equal_hex(0x3f800000, one)

	int one_half = 1.5
	assert_equal_hex(0x3fc00000, one_half)

	int quarter = 0.25
	assert_equal_hex(0x3e800000, quarter)


void test_float32_rounding_and_exponents():
	int tenth = 0.1
	assert_equal_hex(0x3dcccccd, tenth)

	int hundred_thousand = 1e5
	assert_equal_hex(0x47c35000, hundred_thousand)

	int small = 1.5e-3
	assert_equal_hex(0x3ac49ba6, small)


void test_float32_assignment_bits():
	int bits = 0
	bits = 2E+10
	assert_equal_hex(0x509502f9, bits)
