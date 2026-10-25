# Differential fixture for tests/wllvm_test.w: C math calls. Natively
# these externs bind libm through the dynamic linker; the freestanding
# LLVM build lowers them inline (docs/projects/llvm.md). Every result is
# compared bit for bit, including signed zeros, infinities and NaN
# payloads; the exit status names a failing check. Not a standalone test
# (no wbuild directive).
import lib.lib
import lib.assert

c_lib "libm.so.6"

extern float64 sqrt(float64 x)
extern float32 sqrtf(float32 x)
extern float64 fabs(float64 x)
extern float32 fabsf(float32 x)
extern float64 floor(float64 x)
extern float64 ceil(float64 x)
extern float64 trunc(float64 x)
extern float32 floorf(float32 x)
extern float32 ceilf(float32 x)
extern float32 truncf(float32 x)
extern float64 fmin(float64 x, float64 y)
extern float64 fmax(float64 x, float64 y)
extern float64 copysign(float64 x, float64 y)


int bits64(float64 x):
	return load_int64(cast(char*, &x))


int bits32(float32 x):
	return load_int32(cast(char*, &x))


# A 64-bit pattern from its 32-bit halves (lo below bit 31).
int wide(int hi, int lo):
	return (hi << 32) | lo


float64 from64(int bits):
	float64 x
	save_int64(cast(char*, &x), bits)
	return x


float32 from32(int bits):
	float32 x
	save_int32(cast(char*, &x), bits)
	return x


int checks


void same64(int want, float64 got):
	checks = checks + 1
	# The exit status names the failing check.
	if (bits64(got) != want): exit(checks)


void same32(int want, float32 got):
	checks = checks + 1
	if (bits32(got) != want): exit(checks)


int main():
	float64 negative_half = -0.5
	float64 huge = from64(wide(0x43400000, 1))
	float64 infinity = from64(wide(0x7ff00000, 0))
	float64 payload = from64(wide(0x7ff00000, 0x1234))
	same64(bits64(1.5), sqrt(2.25))
	same32(bits32(from32(0x3fc00000)), sqrtf(2.25))
	same64(0, fabs(from64(1 << 63)))
	same32(0x40200000, fabsf(from32(cast(int, 0xc0200000))))
	same64(bits64(-1.0), floor(negative_half))
	same64(1 << 63, ceil(negative_half))
	same64(1 << 63, trunc(negative_half))
	same64(bits64(3.0), floor(3.5))
	same64(bits64(4.0), ceil(3.5))
	same64(bits64(-3.0), trunc(-3.75))
	same64(bits64(huge), floor(huge))
	same64(bits64(infinity), ceil(infinity))
	same64(wide(0x7ff80000, 0x1234), floor(payload))
	same32(bits32(from32(0x40400000)), floorf(3.75))
	same32(bits32(from32(cast(int, 0xc0800000))), floorf(-3.25))
	same32(bits32(from32(0x40800000)), ceilf(3.25))
	same32(bits32(from32(cast(int, 0x80000000))), truncf(-0.25))
	same64(bits64(1.5), fmin(1.5, 2.5))
	same64(bits64(2.5), fmax(1.5, 2.5))
	same64(bits64(2.5), fmax(from64(wide(0x7ff80000, 0)), 2.5))
	same64(bits64(-2.0), copysign(2.0, negative_half))
	println(c"math ok")
	return 0
