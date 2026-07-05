# Floating-point C ABI through c_import on the x64 target: math.h imports
# with real float64 signatures and the generated shims follow the SysV
# xmm register convention (c_import must precede other declarations, so
# this lives apart from the extern-based x64_float_abi_test.w).
import lib.lib
import lib.assert

c_import "libm.so.6" c"/usr/include/math.h"


void assert_float64_bits(int want_lo, int want_hi, float64 got):
	char* p = &got
	assert_equal_hex(want_lo, load_int32(p))
	assert_equal_hex(want_hi, load_int32(p + 4))


int main(int argc, int argv):
	assert_float64_bits(0x00000000, 0x40080000, floor(3.5))       /* 3.0 */
	assert_float64_bits(0x00000000, 0x40080000, ceil(2.25))       /* 3.0 */
	assert_float64_bits(0x00000000, 0x40040000, fmax(1.5, 2.5))   /* 2.5 */
	assert_float64_bits(0x00000000, 0x3ff80000, sqrt(2.25))       /* 1.5 */
	assert_float64_bits(0x00000000, 0x40900000, pow(2.0, 10.0))   /* 1024.0 */
	println(c"x64 c_import float OK")
	return 0
