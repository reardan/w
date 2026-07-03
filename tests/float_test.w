import lib.testing
import lib.format


float add_float(float a, float b):
	return a + b


float add_int_to_float(float a, int b):
	return a + b


int truncate_float(float f):
	return f


void assert_float_bits(int want, float got):
	char* p = &got
	assert_equal_hex(want, load_i(p, 4))


void test_float32_arithmetic_bits():
	float sum = 1.5 + 2.25
	assert_float_bits(0x40700000, sum)

	float diff = 5.5 - 2.0
	assert_float_bits(0x40600000, diff)

	float product = 1.5 * 2.0
	assert_float_bits(0x40400000, product)

	float quotient = 7.0 / 2.0
	assert_float_bits(0x40600000, quotient)


void test_float32_comparisons():
	assert_equal(1, 1.5 < 2.0)
	assert_equal(0, 2.0 < 1.5)
	assert_equal(1, 2.0 >= 2.0)
	assert_equal(1, 3.0 != 4.0)
	assert_equal(1, 3.0 == 3.0)


void test_float32_coercions():
	float from_int = 3
	assert_float_bits(0x40400000, from_int)

	int truncated = 3.75
	assert_equal(3, truncated)

	float negative = -1.5
	assert_float_bits(0xbfc00000, negative)


void test_float32_params_and_returns():
	assert_float_bits(0x40700000, add_float(1.5, 2.25))
	assert_float_bits(0x40800000, add_int_to_float(1.0, 3))
	assert_equal(4, truncate_float(4.75))


void test_ftoa():
	char* s = ftoa(3.25)
	assert_strings_equal("3.250000", s)
	free(s)
