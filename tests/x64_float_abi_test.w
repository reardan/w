# Floating-point C ABI test for the x64 target: float64 arguments travel
# in xmm0..xmm7 and float64 results come back in xmm0 through hand-written
# extern declarations. The c_import path is covered separately in
# x64_c_import_float_test.w.
import lib.lib
import lib.assert

c_lib "libc.so.6"
c_lib "libm.so.6"

extern float64 sqrt(float64 x)
extern float64 pow(float64 x, float64 y)
extern float64 fmod(float64 x, float64 y)
extern float64 fma(float64 x, float64 y, float64 z)
# Mixed classes: xmm0 for the float, edi for the int.
extern float64 ldexp(float64 x, int exp)
# Float argument with an integer result.
extern int ilogb(float64 x)


void assert_float64_bits(int want_lo, int want_hi, float64 got):
	char* p = &got
	assert_equal_hex(want_lo, load_int32(p))
	assert_equal_hex(want_hi, load_int32(p + 4))


int main(int argc, int argv):
	assert_float64_bits(0x00000000, 0x3ff80000, sqrt(2.25))       /* 1.5 */
	assert_float64_bits(0x00000000, 0x40900000, pow(2.0, 10.0))   /* 1024.0 */
	assert_float64_bits(0x00000000, 0x3ff80000, fmod(7.5, 2.0))   /* 1.5 */
	assert_float64_bits(0x00000000, 0x401e0000, fma(2.0, 3.0, 1.5)) /* 7.5 */
	assert_float64_bits(0x00000000, 0x40380000, ldexp(1.5, 4))    /* 24.0 */
	assert_equal(10, ilogb(1024.0))

	# Round-trip through W float64 variables
	float64 base = 3.0
	float64 exponent = 4.0
	assert_float64_bits(0x00000000, 0x40544000, pow(base, exponent)) /* 81.0 */

	println(c"x64 float abi OK")
	return 0
