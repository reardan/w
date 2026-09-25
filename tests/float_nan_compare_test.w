# wbuild: arch_only=arm64
# NaN comparisons on arm64 follow IEEE-754: every ordered comparison
# (<, <=, >, >=) with a NaN operand is false, == is false and != is true.
# An unordered fcmp sets NZCV to 0011, which the unsigned hi/hs conditions
# the x86-shaped lowering picks for > and >= (and, with swapped operands,
# for < and <=) read as true; code_generator/sse.w maps those to gt/ge.
# The x86 family keeps its documented ucomis divergence (nan == nan is
# true there), so this file only builds for arm64; wasm's f32 compares
# are IEEE already. See docs/projects/float.md.
import lib.testing
import lib.fmath


void test_float32_nan_compares():
	float n = float_from_bits(0x7fc00000)
	float one = 1.0
	assert_equal(0, n == n)
	assert_equal(1, n != n)
	assert_equal(0, n < one)
	assert_equal(0, n <= one)
	assert_equal(0, n > one)
	assert_equal(0, n >= one)
	assert_equal(0, one < n)
	assert_equal(0, one <= n)
	assert_equal(0, one > n)
	assert_equal(0, one >= n)


void test_float64_nan_compares():
	float64 zero = 0.0
	float64 n = zero / zero
	float64 one = 1.0
	assert_equal(0, n == n)
	assert_equal(1, n != n)
	assert_equal(0, n < one)
	assert_equal(0, n <= one)
	assert_equal(0, n > one)
	assert_equal(0, n >= one)
	assert_equal(0, one < n)
	assert_equal(0, one >= n)


void test_ordered_compares_unchanged():
	float a = 1.0
	float b = 2.0
	assert_equal(1, a < b)
	assert_equal(1, a <= b)
	assert_equal(0, a > b)
	assert_equal(0, a >= b)
	assert_equal(1, b > a)
	assert_equal(1, b >= a)
	assert_equal(1, a <= a)
	assert_equal(1, a >= a)
	assert_equal(0, a < a)
	assert_equal(0, a > a)
	float m = 0.0 - 3.0
	assert_equal(1, m < a)
	assert_equal(1, a > m)
	float negzero = 0.0 - 0.0
	float zero = 0.0
	assert_equal(1, negzero == zero)
	assert_equal(1, negzero >= zero)
	assert_equal(0, negzero < zero)
