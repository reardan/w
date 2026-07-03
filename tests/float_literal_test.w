import lib.testing


void assert_float_literal_bits(int want, float got):
	char* p = &got
	assert_equal_hex(want, load_i(p, 4))


void test_basic_float32_literals():
	assert_float_literal_bits(0x3f800000, 1.0)

	assert_float_literal_bits(0x3fc00000, 1.5)

	assert_float_literal_bits(0x3e800000, 0.25)


void test_float32_rounding_and_exponents():
	assert_float_literal_bits(0x3dcccccd, 0.1)

	assert_float_literal_bits(0x47c35000, 1e5)

	assert_float_literal_bits(0x3ac49ba6, 1.5e-3)


void test_float32_assignment_bits():
	float bits = 0
	bits = 2E+10
	assert_float_literal_bits(0x509502f9, bits)
