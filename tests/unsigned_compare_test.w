# wbuild: arch=arm64_darwin x64 arch=arm64 arch=wasm
/*
Unsigned word operations (docs/projects/type_system_p0.md, "Unsigned
operations"): `<`, `<=`, `>`, `>=`, `/`, `%` and `>>` are unsigned when
an operand is an unsigned WORD type -- uint everywhere, uint32 on the
4-byte-word targets (x86, wasm), uint64 on the 8-byte-word ones (x64,
arm64; see tests/x64_unsigned_compare_test.w) -- following C's usual
arithmetic conversions with W's word-sized int. Narrower unsigned types
zero-extend into the word and keep the signed (value-exact) forms. Before
the fix every one of these compiled signed: `cast(uint, -1) > 1` was
false on every target.

Boundary values are built at runtime: a hex literal with bit 31 set
sign-extends, and decimal literals wrap at 32 bits.
*/
import lib.testing
import lib.checked


type usize = uint


struct unsigned_box:
	uint word
	uint8 small


int word_bits():
	return __word_size__ * 8


# The signed word extremes, as int: -2^(bits-1) and 2^(bits-1)-1.
int word_min():
	return 1 << (word_bits() - 1)


int word_max():
	return ~word_min()


uint umax():
	return cast(uint, 0 - 1)


# 2^(bits-1): the lowest value with the sign bit set
uint uhigh():
	return cast(uint, word_min())


# 2^(bits-1)-1: the highest value without it
uint ulow():
	return cast(uint, word_max())


void test_uint_ordering_around_the_sign_bit():
	uint max = umax()
	uint hi = uhigh()
	uint lo = ulow()
	uint one = 1
	uint zero = 0
	asserts(c"uint max > 1", max > 1)
	asserts(c"1 < uint max", one < max)
	asserts(c"uint max >= 1", max >= one)
	asserts(c"uint max <= 1 is false", (max <= one) == 0)
	asserts(c"2^(n-1) > 2^(n-1)-1", hi > lo)
	asserts(c"2^(n-1)-1 < 2^(n-1)", lo < hi)
	asserts(c"2^(n-1) >= 2^(n-1)-1", hi >= lo)
	asserts(c"2^(n-1)-1 <= 2^(n-1)", lo <= hi)
	asserts(c"2^(n-1) < max", hi < max)
	asserts(c"0 is the minimum", zero < hi)
	asserts(c"0 <= 0", zero <= zero)
	asserts(c"max >= max", max >= max)
	asserts(c"max > max is false", (max > max) == 0)
	# The literal spellings: 0x80000000 is the sign bit on 32-bit words;
	# on 64-bit words it sign-extends, which is still above 0x7fffffff.
	uint a = cast(uint, 0x80000000)
	uint b = 0x7fffffff
	asserts(c"0x80000000 > 0x7fffffff", a > b)
	asserts(c"0x7fffffff < 0x80000000", b < a)


void test_uint_compares_in_conditions():
	uint max = umax()
	uint hi = uhigh()
	uint lo = ulow()
	int taken = 0
	if (max > 1): taken = 1
	assert_equal(1, taken)
	if (hi <= lo): taken = 2
	assert_equal(1, taken)
	if (lo < hi && hi < max): taken = 3
	assert_equal(3, taken)
	# A countdown across the sign boundary: hi, hi-1 (= lo) stops.
	uint u = hi + 1
	int steps = 0
	while (u > lo):
		u = u - 1
		steps += 1
	assert_equal(2, steps)
	assert1(u == lo)
	# Ternaries and for-style bounds
	int pick = (max > hi) ? 7 : 9
	assert_equal(7, pick)
	int n = 0
	uint i = lo
	while (i <= hi):
		n += 1
		i = i + 1
	assert_equal(2, n)


void test_uint_compares_as_values():
	uint max = umax()
	uint hi = uhigh()
	uint lo = ulow()
	int v = max > 1
	assert_equal(1, v)
	bool below = lo < hi
	assert1(below)
	assert_equal(0, hi < lo)
	assert_equal(1, lo <= hi)
	assert_equal(0, lo >= hi)


# C's rule with a word-sized int: an unsigned word operand makes the
# whole comparison unsigned, so a negative int operand reads as a huge
# unsigned value; narrower unsigned operands promote to (signed) int.
void test_mixed_signed_unsigned_operands():
	uint max = umax()
	uint one = 1
	int neg = 0 - 1
	asserts(c"uint max > literal 0", max > 0)
	asserts(c"uint 1 > int -1 is false (-1 converts to max)", (one > neg) == 0)
	asserts(c"int -1 > uint 1 (unsigned compare)", neg > one)
	asserts(c"uint max >= int -1", max >= neg)
	asserts(c"int 5 < uint max", 5 < max)
	uint8 b = 200
	asserts(c"uint8 compares as int: 200 > -1", b > neg)
	uint16 s = 65535
	asserts(c"uint16 compares as int: 65535 > -1", s > neg)
	uint32 w = 0 - 1
	if (__word_size__ == 4):
		# uint32 is the word here: unsigned, like uint
		asserts(c"uint32 max > 1 on a 32-bit word", w > 1)
		asserts(c"uint32 vs int -1 compares unsigned on a 32-bit word", (w > neg) == 0)
	else:
		# uint32 zero-extends into the 64-bit word: a signed compare of
		# its exact value
		asserts(c"uint32 max > -1 on a 64-bit word", w > neg)
		asserts(c"uint32 max > 1 on a 64-bit word", w > 1)


void test_unsigned_division_and_modulo():
	uint max = umax()
	uint hi = uhigh()
	assert_equal(word_max(), max / 2)
	# 2^32-1 and 2^64-1 both end in ...5
	assert_equal(5, max % 10)
	uint third = max / 3
	asserts(c"max / 3 is positive", third > 0)
	assert1(third * 3 == max)
	assert_equal(0, max % 3)
	assert_equal(1 << (word_bits() - 2), hi / 2)
	# 2^odd = 2 (mod 3)
	assert_equal(2, hi % 3)
	# A signed right operand converts to unsigned, like C
	int seven = 7
	assert_equal(max / 7, max / seven)
	assert1(max / seven > 0)
	# Signed division is unchanged
	int m = 0 - 7
	assert_equal(0 - 3, m / 2)
	assert_equal(0 - 1, m % 2)


void test_unsigned_right_shift():
	uint max = umax()
	uint hi = uhigh()
	int k = 1
	assert_equal(word_max(), max >> 1)
	assert_equal(word_max(), max >> k)
	assert_equal(1, hi >> (word_bits() - 1))
	int top = word_bits() - 1
	assert_equal(1, hi >> top)
	assert_equal(1, max >> top)
	# Left shifts are sign-agnostic; signed >> still sign-fills
	assert_equal(0, hi << 1)
	int neg = 0 - 8
	assert_equal(0 - 4, neg >> 1)
	assert_equal(0 - 1, word_min() >> top)


void test_unsigned_compound_assignment():
	uint u = umax()
	u /= 2
	assert_equal(word_max(), u)
	u = umax()
	u %= 10
	assert_equal(5, u)
	u = umax()
	u >>= word_bits() - 1
	assert_equal(1, u)
	u = umax()
	int k = 4
	u >>= k
	assert1(u > 1)
	assert_equal(word_max() >> 3, u)
	# The assignment's value is the stored uint
	uint c = 3
	int runs = 0
	# (runs bounds the loop should the compare regress to signed)
	while (((c -= 1) < 10) && (runs < 100)): runs += 1
	assert_equal(3, runs)


# Unsignedness flows through the integer operators' results.
void test_unsigned_results_propagate():
	uint max = umax()
	uint hi = uhigh()
	uint lo = ulow()
	uint one = 1
	uint zero = 0
	asserts(c"(max - 1) > 1", (max - 1) > 1)
	asserts(c"lo + 1 > lo", lo + 1 > lo)
	asserts(c"(lo + 1) / 2 is unsigned", (lo + 1) / 2 == hi / 2)
	asserts(c"-1u > 1", (0 - one) > 1)
	asserts(c"-uint 1 > 1", -one > 1)
	asserts(c"~uint 0 > 1", ~zero > 1)
	asserts(c"(max & hi) > lo", (max & hi) > lo)
	asserts(c"(hi | 1) > lo", (hi | 1) > lo)
	asserts(c"(max ^ 0) > lo", (max ^ 0) > lo)
	asserts(c"hi * 1 > lo", hi * 1 > lo)
	assert_equal(word_max(), (max ^ 0) / 2)
	assert_equal(1, (hi + 0) >> (word_bits() - 1))
	assert_equal(word_max(), (max << 0) >> 1)


void test_narrow_unsigned_unchanged():
	uint8 b = 200
	asserts(c"uint8 200 > 100", b > 100)
	assert_equal(66, b / 3)
	assert_equal(2, b % 3)
	assert_equal(100, b >> 1)
	uint16 s = 65535
	asserts(c"uint16 65535 > 0", s > 0)
	assert_equal(32767, s >> 1)
	int8 sb = 0 - 100
	asserts(c"int8 stays signed", sb < 0)


void test_aliases_fields_and_returns():
	usize n = umax()
	asserts(c"alias of uint compares unsigned", n > 1)
	assert_equal(word_max(), n / 2)
	unsigned_box* box = new unsigned_box
	box.word = umax()
	box.small = 255
	asserts(c"uint field compares unsigned", box.word > 1)
	asserts(c"uint field vs uint8 field", box.word > box.small)
	assert_equal(word_max(), box.word >> 1)
	asserts(c"uint return compares unsigned", umax() > uhigh())
	uint[] arr = new uint[2]
	arr[0] = umax()
	arr[1] = 1
	asserts(c"uint element compares unsigned", arr[0] > arr[1])
	free(box)


# lib/checked.w's helpers agree with the native operators.
void test_agrees_with_checked_helpers():
	int[] samples = new int[8]
	samples[0] = 0
	samples[1] = 1
	samples[2] = 0 - 1
	samples[3] = word_min()
	samples[4] = word_max()
	samples[5] = 0x7fffffff
	samples[6] = cast(int, 0x80000000)
	samples[7] = 12345
	for i in range(8):
		for j in range(8):
			uint x = cast(uint, samples[i])
			uint y = cast(uint, samples[j])
			int native = x < y
			assert_equal(unsigned_lt(samples[i], samples[j]), native)
			int le = x <= y
			assert_equal(unsigned_le(samples[i], samples[j]), le)
		uint s = cast(uint, samples[i])
		assert_equal(unsigned_shr(samples[i], 3), s >> 3)
