# Floating-point C ABI smoke test that runs on both targets: call libm's
# float32 entry points through extern declarations. On x86 the arguments
# pass on the stack and the result comes back in st(0); on x64 they use
# xmm registers. float64 externs are x64-only and live in
# x64_float_abi_test.w.
import lib.lib
import lib.assert

c_lib "libc.so.6"
c_lib "libm.so.6"

extern float32 sqrtf(float32 x)
extern float32 powf(float32 x, float32 y)
extern float32 fminf(float32 x, float32 y)
extern float32 fmaxf(float32 x, float32 y)
# Mixed classes: the float goes to the float ABI slot, the int to the
# integer slot (xmm0 + edi on x64).
extern float32 ldexpf(float32 x, int exp)
# Float argument with an integer result.
extern int ilogbf(float32 x)


void assert_float32_bits(int want, float32 got):
	char* p = &got
	assert_equal_hex(want, load_int32(p))


int main(int argc, int argv):
	assert_float32_bits(0x40000000, sqrtf(4.0))          /* 2.0 */
	assert_float32_bits(0x43800000, powf(2.0, 8.0))      /* 256.0 */
	assert_float32_bits(0x3fc00000, fminf(1.5, 2.5))     /* 1.5 */
	assert_float32_bits(0x40200000, fmaxf(1.5, 2.5))     /* 2.5 */
	assert_float32_bits(0x41400000, ldexpf(1.5, 3))      /* 12.0 */
	assert_equal(8, ilogbf(256.0))

	# Round-trip through a W float32 variable
	float32 x = 2.25
	assert_float32_bits(0x3fc00000, sqrtf(x))            /* 1.5 */

	println(c"float abi OK")
	return 0
