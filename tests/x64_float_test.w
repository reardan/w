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
	assert_equal_hex(want_lo, load_i(p, 4))
	assert_equal_hex(want_hi, load_i(p + 4, 4))


void assert_float32_bits(int want, float32 got):
	char* p = &got
	assert_equal_hex(want, load_i(p, 4))


int main(int argc, int argv):
	assert_float64_bits(0x9999999a, 0x3fb99999, 0.1)
	assert_float64_bits(0x00000000, 0x400c0000, 1.5 + 2.0)
	assert_float64_bits(0x00000000, 0x40100000, add_float64(1.5, 2.5))
	assert_float64_bits(0x00000000, 0x40100000, add_int_float64(1.0, 3))
	assert_equal(4, truncate_float64(4.75))

	float32 narrowed = 1.25
	assert_float32_bits(0x3fa00000, narrowed)

	char* s = f64toa(3.25)
	assert_strings_equal("3.250000", s)
	free(s)

	println2("x64 float OK")
	return 0
