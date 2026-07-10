/*
lib.fmath: shared float32 math helpers.

Extracted from graphics/math.w (issue #186) so numeric consumers such as
lib/stats.w don't carry private copies. float32-only and pure W, so every
target is covered: float64 is a compile error on the default 32-bit
target, and nothing here needs libc.

Imports merge into one flat global namespace and lib/math.w already owns
unprefixed abs/min/max, so these use an f prefix, mirroring C. fmod2 dodges
libc's fmod, which leaks in as an extern through c_import of math.h.
*/
import lib.lib


# Reinterpret the float32 bit pattern as an integer.
int float_bits(float f):
	int32* p = cast(int32*, &f)
	return *p


float float_from_bits(int bits):
	float f
	int32* p = cast(int32*, &f)
	*p = bits
	return f


# 1 when f is NaN: exponent all ones, mantissa nonzero. A bit test is
# required because the compiler defines nan == nan as true
# (docs/projects/float.md), so f != f cannot detect NaN.
int fis_nan(float f):
	int bits = float_bits(f)
	if ((bits & 0x7f800000) != 0x7f800000):
		return 0
	return (bits & 0x007fffff) != 0


# Absolute value by clearing the sign bit; passes NaN through instead of
# relying on NaN comparison ordering.
float fabs(float f):
	return float_from_bits(float_bits(f) & 0x7fffffff)


# Largest whole value not above f. Float-to-int conversion truncates
# toward zero, so negative non-integers need one step down.
float ffloor(float f):
	int truncated = f
	float whole = truncated
	if (f < whole):
		return whole - 1.0
	return whole


# glm mod(): a - floor(a / b) * b, result has the sign of b. '%' on
# floats is a compile error, so a helper is the only option.
float fmod2(float a, float b):
	return a - ffloor(a / b) * b


# Newton-Raphson square root seeded by an exponent-halving bit trick;
# three iterations reach full float32 precision. 0.0 for f <= 0.0.
float fsqrt(float f):
	if (f <= 0.0):
		return 0.0
	int bits = float_bits(f) & 0x7fffffff
	float guess = float_from_bits(0x1fbd1df5 + (bits >> 1))
	guess = 0.5 * (guess + f / guess)
	guess = 0.5 * (guess + f / guess)
	guess = 0.5 * (guess + f / guess)
	return guess
