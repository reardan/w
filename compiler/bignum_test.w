import lib.testing
import compiler.bignum


void test_mul_pow10():
	int n = bignum_new()
	bignum_set_u32(n, 123)
	bignum_mul_pow10(n, 3)
	assert_equal(2, bignum_length(n))
	assert_equal_hex(0xe078, bignum_limb(n, 0))
	assert_equal_hex(0x0001, bignum_limb(n, 1))
	free(n)


void test_shift_and_subtract():
	int n = bignum_new()
	bignum_set_u32(n, 1)
	bignum_shl_bits(n, 20)
	assert_equal(21, bignum_bit_length(n))
	assert_equal(1, bignum_get_bit(n, 20))

	int m = bignum_new()
	bignum_set_u32(m, 1)
	bignum_shl_bits(m, 19)
	bignum_sub(n, m)
	assert_equal(20, bignum_bit_length(n))
	assert_equal(1, bignum_get_bit(n, 19))
	free(n)
	free(m)


void test_ratio_exponent():
	int num = bignum_new()
	int den = bignum_new()
	bignum_set_u32(num, 3)
	bignum_set_u32(den, 10)
	assert_equal(-2, bignum_floor_log2_ratio(num, den))
	free(num)
	free(den)


void test_scaled_division_and_rounding():
	int num = bignum_new()
	int den = bignum_new()
	int rem = bignum_new()
	bignum_set_u32(num, 1)
	bignum_set_u32(den, 10)
	int quotient = bignum_div_scaled_to_int(num, den, 4, rem)
	assert_equal(1, quotient)
	assert_equal(1, bignum_round_up(rem, den, quotient))
	free(num)
	free(den)
	free(rem)
