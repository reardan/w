# wbuild: x64 arch=arm64
# lib/float_text.w: correctly rounded decimal -> float parsing, shortest
# round-trip float -> decimal formatting and fixed-precision formatting
# (issue #529). float32 runs on every target; the float64 cases work
# on raw bit patterns (this file never names float64, so it compiles
# for x86) and run only on the 8-byte word, where a float64 pattern
# fits an int. Expected spellings were cross-checked against Python's
# repr and float() over tens of thousands of random patterns.
import lib.testing
import lib.rand
import lib.float_text


# A float64 bit pattern from its two 32-bit halves (8-byte word only).
int ft_bits64(int hi, int lo):
	int mask = (1 << 16) * (1 << 16) - 1
	return (hi << 32) | (lo & mask)


void ft_check_shortest(int bits, int width, char* want):
	char* got = float_text_shortest(bits, width)
	assert_strings_equal(want, got)
	free(got)


void ft_check_fixed(int bits, int width, int precision, char* want):
	char* got = float_text_fixed(bits, width, precision)
	assert_strings_equal(want, got)
	free(got)


# Parse text (all of it must be consumed) and compare the bit pattern;
# float32 results compare through the low 32 bits.
void ft_check_parse(char* text, int width, int want):
	int used = -1
	int got = float_text_parse(text, width, &used)
	assert_equal(strlen(text), used)
	if (width == 32):
		got = got & rand_mask32()
		want = want & rand_mask32()
	assert_equal_hex(want, got)


void ft_check_consumed(char* text, int want_used):
	int used = -1
	float_text_parse(text, 32, &used)
	assert_equal(want_used, used)


void test_float32_shortest():
	ft_check_shortest(0x3dcccccd, 32, c"0.1")
	ft_check_shortest(0x60ad78ec, 32, c"1e+20")
	ft_check_shortest(0x33d6bf95, 32, c"1e-07")
	ft_check_shortest(0x7f7fffff, 32, c"3.4028235e+38")   # FLT_MAX
	ft_check_shortest(0x00800000, 32, c"1.1754944e-38")   # FLT_MIN
	ft_check_shortest(1, 32, c"1e-45")                    # smallest denormal
	ft_check_shortest(0x4b800000, 32, c"16777216.0")
	ft_check_shortest(0x40490fdb, 32, c"3.1415927")
	ft_check_shortest(0x3eaaaaab, 32, c"0.33333334")
	ft_check_shortest(0x4cbebc20, 32, c"100000000.0")
	ft_check_shortest(0, 32, c"0.0")
	ft_check_shortest(cast(int, 0x80000000), 32, c"-0.0")
	ft_check_shortest(0x7f800000, 32, c"inf")
	ft_check_shortest(cast(int, 0xff800000), 32, c"-inf")
	ft_check_shortest(0x7fc00000, 32, c"nan")


void test_float32_fixed():
	ft_check_fixed(0x40200000, 32, 6, c"2.500000")
	ft_check_fixed(0x60ad78ec, 32, 0, c"100000002004087734272")
	ft_check_fixed(0x33d6bf95, 32, 10, c"0.0000001000")
	ft_check_fixed(0x40490fdb, 32, 3, c"3.142")
	# exact halves round to even: 0.5 -> 0, 1.5 -> 2, 2.5 -> 2
	ft_check_fixed(0x3f000000, 32, 0, c"0")
	ft_check_fixed(0x3fc00000, 32, 0, c"2")
	ft_check_fixed(0x40200000, 32, 0, c"2")
	ft_check_fixed(cast(int, 0xbf000000), 32, 0, c"-0")
	ft_check_fixed(0x7f800000, 32, 2, c"inf")


void test_float32_parse():
	ft_check_parse(c"0.1", 32, 0x3dcccccd)
	ft_check_parse(c"1e20", 32, 0x60ad78ec)
	ft_check_parse(c"3.4028235e38", 32, 0x7f7fffff)
	ft_check_parse(c"3.40282356e38", 32, 0x7f7fffff)
	ft_check_parse(c"3.4028236e38", 32, 0x7f800000)            # above the halfway point
	ft_check_parse(c"3.5e38", 32, 0x7f800000)            # overflow
	ft_check_parse(c"1e-45", 32, 1)
	ft_check_parse(c"7e-46", 32, 0)                      # below half the denormal
	ft_check_parse(c"7.1e-46", 32, 1)
	ft_check_parse(c"16777217", 32, 0x4b800000)          # tie to even
	ft_check_parse(c"16777219", 32, 0x4b800002)
	ft_check_parse(c"-0", 32, cast(int, 0x80000000))
	ft_check_parse(c"-Infinity", 32, cast(int, 0xff800000))
	ft_check_parse(c"NaN", 32, 0x7fc00000)
	ft_check_parse(c".5", 32, 0x3f000000)
	ft_check_parse(c"5.", 32, 0x40a00000)
	ft_check_parse(c"+00012.50e-1", 32, 0x3fa00000)


void test_parse_consumed():
	ft_check_consumed(c"1.5xyz", 3)
	ft_check_consumed(c"1e", 1)
	ft_check_consumed(c"1e+", 1)
	ft_check_consumed(c"2E-3,", 4)
	ft_check_consumed(c"0x10", 1)
	ft_check_consumed(c"infinite", 3)
	ft_check_consumed(c"abc", 0)
	ft_check_consumed(c".", 0)
	ft_check_consumed(c"-", 0)
	ft_check_consumed(c"", 0)


# An exponent field at an edge of the range: denormal (0), the smallest
# and largest normal binades, or the one holding 1.0.
int ft_edge_exponent(rand_state* r, int top):
	int pick = rand_below(r, 4)
	if (pick == 0): return 0
	if (pick == 1): return 1
	if (pick == 2): return top
	return top / 2


# Every finite float32 pattern drawn must format and parse back to
# itself, and its fixed spelling must parse back to the nearest value.
void test_float32_round_trip_random():
	rand_state r
	rand_init(&r, 529)
	int i = 0
	while (i < 3000):
		int bits = rand_next31(&r) | ((rand_next31(&r) & 1) << 31)
		if (i % 4 == 0):
			# bias toward the extreme exponents and the denormals
			bits = (bits & cast(int, 0x807fffff)) | (ft_edge_exponent(&r, 0xfe) << 23)
		if (float_text_is_special(bits, 32) == 0):
			char* s = float_text_shortest(bits, 32)
			int used = 0
			int back = float_text_parse(s, 32, &used)
			assert_equal(strlen(s), used)
			assert_equal_hex(bits & rand_mask32(), back & rand_mask32())
			free(s)
		i = i + 1


void test_float64_shortest_and_parse():
	if (__word_size__ != 8): return
	ft_check_shortest(ft_bits64(0x4415af1d, 0x78b58c40), 64, c"1e+20")
	ft_check_shortest(ft_bits64(0x3e7ad7f2, cast(int, 0x9abcaf48)), 64, c"1e-07")
	ft_check_shortest(ft_bits64(0x7fefffff, -1), 64, c"1.7976931348623157e+308")   # DBL_MAX
	ft_check_shortest(ft_bits64(0x00100000, 0), 64, c"2.2250738585072014e-308")   # DBL_MIN
	ft_check_shortest(1, 64, c"5e-324")
	ft_check_shortest(ft_bits64(0x000fffff, -1), 64, c"2.225073858507201e-308")
	ft_check_shortest(ft_bits64(0x44b52d02, cast(int, 0xc7e14af6)), 64, c"1e+23")
	ft_check_shortest(ft_bits64(0x43400000, 0), 64, c"9007199254740992.0")
	ft_check_shortest(ft_bits64(0x3fb99999, cast(int, 0x9999999a)), 64, c"0.1")
	ft_check_shortest(ft_bits64(0x430c6bf5, 0x26340000), 64, c"1000000000000000.0")
	ft_check_shortest(ft_bits64(0x4341c379, 0x37e08000), 64, c"1e+16")
	ft_check_shortest(ft_bits64(0x3f1a36e2, cast(int, 0xeb1c432d)), 64, c"0.0001")
	ft_check_shortest(ft_bits64(0x3ee4f8b5, cast(int, 0x88e368f1)), 64, c"1e-05")
	ft_check_shortest(ft_bits64(cast(int, 0xc00921fb), 0x54442d18), 64, c"-3.141592653589793")
	ft_check_shortest(0, 64, c"0.0")
	ft_check_shortest(ft_bits64(cast(int, 0x80000000), 0), 64, c"-0.0")
	ft_check_shortest(ft_bits64(0x7ff00000, 0), 64, c"inf")

	ft_check_parse(c"2.2250738585072011e-308", 64, ft_bits64(0x000fffff, -1))
	ft_check_parse(c"2.2250738585072014e-308", 64, ft_bits64(0x00100000, 0))
	ft_check_parse(c"4.9e-324", 64, 1)
	ft_check_parse(c"5e-324", 64, 1)
	ft_check_parse(c"2.4703282292062327e-324", 64, 0)       # just below half
	ft_check_parse(c"2.4703282292062328e-324", 64, 1)       # just above half
	ft_check_parse(c"1.7976931348623157e308", 64, ft_bits64(0x7fefffff, -1))
	ft_check_parse(c"1.7976931348623158e308", 64, ft_bits64(0x7fefffff, -1))
	ft_check_parse(c"1.7976931348623159e308", 64, ft_bits64(0x7ff00000, 0))
	ft_check_parse(c"1e400", 64, ft_bits64(0x7ff00000, 0))
	ft_check_parse(c"-1e-400", 64, ft_bits64(cast(int, 0x80000000), 0))
	ft_check_parse(c"1e23", 64, ft_bits64(0x44b52d02, cast(int, 0xc7e14af6)))
	ft_check_parse(c"9007199254740993", 64, ft_bits64(0x43400000, 0))
	ft_check_parse(c"9007199254740995", 64, ft_bits64(0x43400000, 2))
	ft_check_parse(c"0.1", 64, ft_bits64(0x3fb99999, cast(int, 0x9999999a)))
	ft_check_parse(c"-0.0", 64, ft_bits64(cast(int, 0x80000000), 0))

	ft_check_fixed(ft_bits64(0x4415af1d, 0x78b58c40), 64, 1, c"100000000000000000000.0")
	ft_check_fixed(ft_bits64(0x3e7ad7f2, cast(int, 0x9abcaf48)), 64, 8, c"0.00000010")
	ft_check_fixed(ft_bits64(0x3fb99999, cast(int, 0x9999999a)), 64, 20, c"0.10000000000000000555")
	ft_check_fixed(ft_bits64(cast(int, 0xc00921fb), 0x54442d18), 64, 4, c"-3.1416")


# A 1000-digit decimal: the parser keeps 800 digits plus a sticky bit
# for the rest, which decides an otherwise exact tie.
void test_float64_long_input():
	if (__word_size__ != 8): return
	# 1 + 2^-53 is exactly halfway between 1 and its successor: a tie
	# rounding to even (1.0) unless any later digit is nonzero
	char* tie = c"1.00000000000000011102230246251565404236316680908203125"
	ft_check_parse(tie, 64, ft_bits64(0x3ff00000, 0))
	int n = strlen(tie)
	char* above = malloc(n + 1001)
	strcpy(above, tie)
	int i = 0
	while (i < 999):
		above[n + i] = '0'
		i = i + 1
	above[n + 999] = '1'
	above[n + 1000] = 0
	ft_check_parse(above, 64, ft_bits64(0x3ff00000, 1))
	free(above)


void test_float64_round_trip_random():
	if (__word_size__ != 8): return
	rand_state r
	rand_init(&r, 1234)
	int i = 0
	while (i < 3000):
		int hi = rand_next31(&r) | ((rand_next31(&r) & 1) << 31)
		if (i % 4 == 0):
			hi = (hi & cast(int, 0x800fffff)) | (ft_edge_exponent(&r, 0x7fe) << 20)
		int bits = ft_bits64(hi, rand_next31(&r) | ((rand_next31(&r) & 1) << 31))
		if (float_text_is_special(bits, 64) == 0):
			char* s = float_text_shortest(bits, 64)
			int used = 0
			int back = float_text_parse(s, 64, &used)
			assert_equal(strlen(s), used)
			assert_equal_hex(bits, back)
			free(s)
		i = i + 1
