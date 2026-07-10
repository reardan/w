# wbuild: x64
/*
The bit-manipulation intrinsics (grammar/bit_builtin.w, #249):

  shr(a, n)     logical (unsigned) right shift by n mod 32
  rotl(a, n)    rotate left by n mod 32
  rotr(a, n)    rotate right by n mod 32
  popcount(a)   number of set bits
  clz(a)        leading zeros; clz(0) == 32
  ctz(a)        trailing zeros; ctz(0) == 32

All six read only the operands' low 32 bits, as unsigned. Results
follow the masked-32-bit-word convention (lib/sha256.w): the low 32
bits are the meaningful pattern, zero-extended on 64-bit targets. Every
expected value below is therefore built at runtime from the same
patterns (mask32() etc.), so the assertions hold verbatim on the
32-bit x86 target, the 64-bit targets, and arm64. Shift/rotate counts
are masked to 5 bits, the hardware behavior of 32-bit shifts on both
x86 and A64.

The shadow tests at the bottom exercise the not-a-reserved-word rule:
a user symbol with an intrinsic's name that is already defined at the
call site takes precedence (grammar/limb_builtin.w's rule), so the
rotl() calls above the user definition use the intrinsic and the ones
below it do not.
*/
import lib.testing


# 0xffffffff as this target represents a masked 32-bit word: -1 on the
# 32-bit target, 4294967295 zero-extended on the 64-bit ones.
int mask32():
	int h = 1 << 16
	return h * h - 1


# 0xaaaaaaaa: the alternating pattern with bit 31 set, built at runtime
# because bit-31 literals are banned in W source.
int alternating_hi():
	return mask32() - 0x55555555


void test_shr_basics():
	assert_equal(0, shr(0, 0))
	assert_equal(0, shr(0, 31))
	assert_equal(5, shr(5, 0))
	assert_equal(2, shr(5, 1))
	assert_equal(0b101, shr(0b1010, 1))


void test_shr_is_logical_not_arithmetic():
	int m = mask32()
	# an arithmetic >> would smear the sign bit into all of these
	assert_equal((1 << 31) - 1, shr(m, 1))
	assert_equal(1, shr(m, 31))
	assert_equal(1, shr(1 << 31, 31))
	assert_equal(1 << 30, shr(1 << 31, 1))
	assert_equal(0x7fffffff, shr(0 - 1, 1))


void test_shr_reads_low_32_bits_only():
	# -1 sign-extends to all ones on the 64-bit targets; only the low
	# 32 bits participate
	assert_equal(mask32(), shr(0 - 1, 0))
	assert_equal(3, shr(0 - 1, 30))


void test_shr_count_masked_to_5_bits():
	assert_equal(8, shr(8, 32))
	assert_equal(4, shr(8, 33))
	assert_equal(1, shr(1 << 31, 63))
	# a negative count masks to 31
	assert_equal(1, shr(1 << 31, 0 - 1))


void test_rotl():
	assert_equal(0, rotl(0, 17))
	assert_equal(13, rotl(0b1101, 0))
	assert_equal(0b11010, rotl(0b1101, 1))
	assert_equal(1 << 31, rotl(1, 31))
	# bit 31 wraps around to bit 0
	assert_equal(1, rotl(1 << 31, 1))
	assert_equal(mask32(), rotl(mask32(), 13))
	assert_equal(alternating_hi(), rotl(0x55555555, 1))
	# count masked to 5 bits: 32 and -1 behave as 0 and 31
	assert_equal(7, rotl(7, 32))
	assert_equal(1 << 31, rotl(1, 0 - 1))


void test_rotr():
	assert_equal(0, rotr(0, 9))
	assert_equal(13, rotr(0b1101, 0))
	# bit 0 wraps around to bit 31
	assert_equal(1 << 31, rotr(1, 1))
	assert_equal(1, rotr(1 << 31, 31))
	assert_equal(2, rotr(1, 31))
	assert_equal(mask32(), rotr(mask32(), 7))
	assert_equal(alternating_hi(), rotr(0x55555555, 1))
	# count masked to 5 bits
	assert_equal(7, rotr(7, 32))
	assert_equal(2, rotr(1, 0 - 1))


void test_rotations_invert_each_other():
	int v = 0x12345678
	assert_equal(v, rotr(rotl(v, 13), 13))
	assert_equal(v, rotl(rotr(v, 5), 5))
	v = alternating_hi()
	assert_equal(v, rotr(rotl(v, 31), 31))


void test_popcount():
	assert_equal(0, popcount(0))
	assert_equal(1, popcount(1))
	assert_equal(1, popcount(1 << 31))
	assert_equal(32, popcount(mask32()))
	assert_equal(32, popcount(0 - 1))
	assert_equal(16, popcount(0x55555555))
	assert_equal(16, popcount(alternating_hi()))
	assert_equal(16, popcount(0x0f0f0f0f))
	assert_equal(8, popcount(0x11111111))
	assert_equal(3, popcount(0b1011))
	assert_equal(31, popcount(mask32() - (1 << 15)))


void test_clz():
	assert_equal(32, clz(0))
	assert_equal(31, clz(1))
	assert_equal(0, clz(1 << 31))
	assert_equal(0, clz(mask32()))
	assert_equal(0, clz(0 - 1))
	assert_equal(1, clz(1 << 30))
	assert_equal(16, clz(1 << 15))
	assert_equal(28, clz(0b1010))


void test_ctz():
	assert_equal(32, ctz(0))
	assert_equal(0, ctz(1))
	assert_equal(31, ctz(1 << 31))
	assert_equal(0, ctz(mask32()))
	assert_equal(0, ctz(0 - 1))
	assert_equal(30, ctz(1 << 30))
	assert_equal(15, ctz(1 << 15))
	assert_equal(1, ctz(0b1010))
	assert_equal(2, ctz(12))


void test_intrinsics_compose_in_expressions():
	# results are ordinary int values: usable inline and nested
	assert_equal(32, popcount(mask32()) + clz(1 << 31))
	assert_equal(16, popcount(rotl(0x55555555, 3)))
	assert_equal(0, ctz(rotr(1, 1)) - 31)
	assert_equal(clz(shr(mask32(), 16)), 16)


# ---- shadowing: everything above this line used the rotl intrinsic ----
int rotl(int a, int n):
	return a + n


void test_user_definition_shadows_the_intrinsic():
	# the intrinsic would return 20
	assert_equal(15, rotl(10, 5))


void test_other_intrinsics_stay_unshadowed():
	assert_equal(1 << 31, rotr(1, 1))
	assert_equal(16, popcount(0x55555555))
	assert_equal(4, shr(8, 1))
