# wbuild: x64 arch=arm64 arch=wasm
import lib.testing


# cast(T, x) to an integer type narrower than the word truncates the
# value to T's width and sign- or zero-extends it, as C's conversions do
# (grammar/promote.w, coerce_narrow_integer). The word-width compares
# rely on a narrow value having the representation a load of a T
# variable gives it: on a 64-bit word a uint32 is a zero-extended word,
# so cast(uint32, -1) must be 0xffffffff there. Before the fix a cast
# only retyped the register, so for a uint32 x = 64 both
# x < cast(uint32, 4294967295) and x < cast(uint32, -1) were false on
# x64 (the decimal literal is -1 in W).

int minus_one():
	return 0 - 1


void test_uint32_constant_compares():
	uint32 x = 64
	asserts(c"x < cast(uint32, 4294967295)", x < cast(uint32, 4294967295))
	asserts(c"x < cast(uint32, -1)", x < cast(uint32, -1))
	asserts(c"cast(uint32, -1) > x", cast(uint32, -1) > x)
	asserts(c"x <= cast(uint32, -1)", x <= cast(uint32, -1))
	asserts(c"x != cast(uint32, -1)", x != cast(uint32, -1))
	uint32 top = cast(uint32, -1)
	asserts(c"top == cast(uint32, -1)", top == cast(uint32, -1))
	asserts(c"x < top", x < top)


void test_uint32_runtime_compares():
	uint32 x = 64
	int m = minus_one()
	asserts(c"x < cast(uint32, m)", x < cast(uint32, m))
	asserts(c"cast(uint32, m) > x", cast(uint32, m) > x)
	uint32 top = cast(uint32, m)
	asserts(c"top == cast(uint32, m)", top == cast(uint32, m))


void test_unsigned_narrowing():
	int k = 300
	assert_equal(44, cast(uint8, 300))
	assert_equal(44, cast(uint8, k))
	assert_equal(255, cast(uint8, minus_one()))
	assert_equal(65535, cast(uint16, minus_one()))
	assert_equal(4464, cast(uint16, 70000))
	asserts(c"cast(uint8, 300) < 100", cast(uint8, 300) < 100)
	if (__word_size__ == 8):
		assert_equal(65536 * 65536 - 1, cast(uint32, minus_one()))


void test_signed_narrowing():
	int k = 200
	assert_equal(0 - 56, cast(int8, 200))
	assert_equal(0 - 56, cast(int8, k))
	assert_equal(0 - 56, cast(char, k))
	assert_equal(0 - 1, cast(int16, 65535))
	assert_equal(0 - 1, cast(int32, minus_one()))
	if (__word_size__ == 8):
		int wide = 65536 * 65536 + 5
		assert_equal(5, cast(int32, wide))
		assert_equal(5, cast(uint32, wide))
		int high = 65536 * 32768
		assert_equal(0 - 65536 * 32768, cast(int32, high))


void test_same_width_casts_keep_value():
	uint8 b = 200
	assert_equal(200, cast(uint8, b))
	int8 s = 0 - 3
	assert_equal(0 - 3, cast(int8, s))
	assert_equal(1000, cast(int, 1000))
