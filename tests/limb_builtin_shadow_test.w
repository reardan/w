# wbuild: x64
/*
The limb intrinsics (grammar/limb_builtin.w, #213) are not reserved
words: a user symbol with the same name that is already defined at the
call site takes precedence, so pre-#213 code that shipped its own
helpers under these names keeps its own definitions.
*/
import lib.testing


int mul_hi(int a, int b):
	return a - b


int add_carry(int a, int b, int* carry):
	*carry = 42
	return a + b + 1


void test_user_definitions_shadow_the_intrinsics():
	# The intrinsic would return 0 for both of these
	assert_equal(7, mul_hi(10, 3))
	int c = 0
	assert_equal(6, add_carry(2, 3, &c))
	assert_equal(42, c)


void test_unshadowed_intrinsic_still_works():
	# mul_wide has no user definition in this file, so the builtin runs
	int hi = 0
	assert_equal(15, mul_wide(3, 5, &hi))
	assert_equal(0, hi)
	# 65536 * 65536 = 2^32: lo 0, hi 1
	assert_equal(0, mul_wide(1 << 16, 1 << 16, &hi))
	assert_equal(1, hi)
