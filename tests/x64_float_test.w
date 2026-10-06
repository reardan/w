# wbuild: arch_only=x64 expect_stdout="x64 float OK"
import lib.lib
import lib.assert
import lib.float64_format


float64 add_float64(float64 a, float64 b):
	return a + b


float64 add_int_float64(float64 a, int b):
	return a + b


int truncate_float64(float64 f):
	return f


void assert_float64_bits(int want_lo, int want_hi, float64 got):
	char* p = &got
	assert_equal_hex(want_lo, load_int32(p))
	assert_equal_hex(want_hi, load_int32(p + 4))


void assert_float32_bits(int want, float32 got):
	char* p = &got
	assert_equal_hex(want, load_int32(p))


int main(int argc, int argv):
	assert_float64_bits(cast(int, 0x9999999a), 0x3fb99999, 0.1)
	assert_float64_bits(0x00000000, 0x400c0000, 1.5 + 2.0)
	assert_float64_bits(0x00000000, 0x40100000, add_float64(1.5, 2.5))
	assert_float64_bits(0x00000000, 0x40100000, add_int_float64(1.0, 3))
	assert_equal(4, truncate_float64(4.75))

	# Round-to-nearest above 2^53: ties go to even, below-halfway values
	# round down (issue #238 made them always round up)
	assert_float64_bits(0x00000000, 0x43400000, 9007199254740993.0)
	assert_float64_bits(0x00000002, 0x43400000, 9007199254740995.0)
	# the shortest round-trip spelling of DBL_MAX must not overflow;
	# past the rounding boundary the round-up carries into the exponent
	# and correctly becomes inf
	assert_float64_bits(cast(int, 0xffffffff), 0x7fefffff, 1.7976931348623157e308)
	assert_float64_bits(0x00000000, 0x7ff00000, 1.7976931348623159e308)

	float32 narrowed = 1.25
	assert_float32_bits(0x3fa00000, narrowed)

	char* s = f64toa(3.25)
	assert_strings_equal(c"3.25", s)
	free(s)
	# issue #529: the integer part no longer goes through a word-sized
	# int, and tiny values keep their digits
	s = f64toa(1e20)
	assert_strings_equal(c"1e+20", s)
	free(s)
	s = f64toa(1e-7)
	assert_strings_equal(c"1e-07", s)
	free(s)
	s = f64toa(1.7976931348623157e308)
	assert_strings_equal(c"1.7976931348623157e+308", s)
	free(s)
	s = f64toa_fixed(1e20, 2)
	assert_strings_equal(c"100000000000000000000.00", s)
	free(s)
	s = f64toa_fixed(2.675, 2)   # 2.67499999999999982236431605997495353221893310546875
	assert_strings_equal(c"2.67", s)
	free(s)
	int used = 0
	assert_float64_bits(cast(int, 0xffffffff), 0x000fffff, parse_float64(c"2.2250738585072011e-308 rest", &used))
	assert_equal(23, used)
	assert_float64_bits(0x00000001, 0x00000000, parse_float64(c"4.9e-324", 0))

	println(c"x64 float OK")
	return 0
