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


void test_float32_round_to_nearest_above_2_24():
	# From 2^24 up not every integer is representable: halfway values
	# round to even, below-halfway values round down (issue #238 made
	# them always round up)
	assert_float_literal_bits(0x4b800000, 16777217.0)
	assert_float_literal_bits(0x4b800002, 16777219.0)


void test_float32_max_boundary():
	# The shortest round-trip spelling of FLT_MAX must not overflow
	assert_float_literal_bits(0x7f7fffff, 3.4028235e38)
	# past the rounding boundary the mantissa round-up carries into the
	# exponent and correctly becomes inf
	assert_float_literal_bits(0x7f800000, 3.4028236e38)
	# and above 2^128 the exponent alone is already out of range
	assert_float_literal_bits(0x7f800000, 3.4028237e38)
