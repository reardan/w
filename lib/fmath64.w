/*
lib.fmath64: float64 port of lib.fmath's shared math helpers.

float64 is a compile error on the default 32-bit target (docs/projects/float.md:
one-word stack slots cannot hold 8 bytes), so this module only compiles where
float64 does: x64-class targets. Import it only from code already gated to
those targets (as tests/x64_fmath64_test.w does), the same way
lib/float64_format.w is x64-only in practice despite carrying no explicit
guard of its own.

Names carry a 64 suffix rather than reusing lib.fmath's f-prefixed names:
imports merge into one flat global namespace, lib.fmath already owns
fis_nan/fabs/ffloor/fmod2/fsqrt for float32, and both modules may be
imported by the same x64 program (see tests/x64_c_import_float_test.w's
float64-only math.h surface for a case that would want both precisions
side by side), so the two surfaces must not collide.

One extra wrinkle a float32 port doesn't hit: on x64 `int` is 8 bytes at
runtime, but hex/binary integer *literals* are parsed by the compiler's own
tokenizer, which always runs as a 32-bit process (docs/projects/float.md,
"Bootstrap constraint") and keeps only the low 8 hex digits of any literal
token wider than that -- so a bare 0x7ff0000000000000 or 0x000fffffffffffff
does not parse to the value it looks like (verified empirically; the
32-bit-looking-mask sign-extension gotcha in the top-level CLAUDE.md is a
different, narrower issue than this truncation). Every mask/constant here
that needs more than 32 significant bits is therefore built at runtime from
clean sub-32-bit literals via shifts, the same workaround lib/sha256.w uses
for sha256_mask32().
*/
import lib.lib


# Reinterpret the float64 bit pattern as an integer. int is 8 bytes on x64
# (the only target float64 compiles on), matching float64's size exactly.
int float64_bits(float64 f):
	int* p = cast(int*, &f)
	return *p


float64 float64_from_bits(int bits):
	float64 f
	int* p = cast(int*, &f)
	*p = bits
	return f


# 1 when f is NaN: exponent all ones, mantissa nonzero. A bit test is
# required because the compiler defines nan == nan as true
# (docs/projects/float.md), so f != f cannot detect NaN.
int f64is_nan(float64 f):
	int bits = float64_bits(f)
	# 0x7ff0000000000000: exponent field (bits 52-62) all ones. Built via
	# shift, not a literal -- see the header comment.
	int exp_mask = 0x7ff << 52
	if ((bits & exp_mask) != exp_mask):
		return 0
	# 0x000fffffffffffff: the 52-bit mantissa field.
	int mantissa_mask = (1 << 52) - 1
	return (bits & mantissa_mask) != 0


# Absolute value by clearing the sign bit; passes NaN through instead of
# relying on NaN comparison ordering.
float64 fabs64(float64 f):
	# 0x7fffffffffffffff: every bit except the sign bit. (1 << 63) is the
	# sign-bit-only pattern; subtracting 1 wraps it to all-ones-below,
	# per the header comment's literal-width workaround.
	int sign_clear = (1 << 63) - 1
	return float64_from_bits(float64_bits(f) & sign_clear)


# Largest whole value not above f. Float-to-int conversion truncates
# toward zero, so negative non-integers need one step down.
float64 ffloor64(float64 f):
	int truncated = f
	float64 whole = truncated
	if (f < whole):
		return whole - 1.0
	return whole


# glm mod(): a - floor(a / b) * b, result has the sign of b. '%' on floats
# is a compile error, so a helper is the only option. Named fmod64 rather
# than fmod2's fmod-adjacent spelling: libc's fmod leaks in as an extern
# through c_import of math.h (tests/x64_c_import_float_test.w), and fmod64
# doesn't collide with it.
float64 fmod64(float64 a, float64 b):
	return a - ffloor64(a / b) * b


# Newton-Raphson square root seeded by an exponent-halving bit trick, ported
# from fsqrt to double precision. The magic constant is fsqrt's
# 0x1fbd1df5 rescaled from float32's 23-bit mantissa to float64's 52-bit
# mantissa: fsqrt's constant is (127 << 22) - 188939, i.e. the "exponent
# bits act like a scaled log2" theoretical constant (bias << (mantissa_bits
# - 1)) minus an empirical correction of 188939 / 2^22 of a mantissa ulp
# (the correction compensates for approximating log2 linearly over the
# mantissa); the same fractional correction against float64's (1023 << 51)
# gives 0x1ff7a3bea0000000, split here into clean 32-bit halves to dodge
# the literal-width limit described in the header comment. Halving the
# initial guess's relative error roughly doubles its correct bits each
# iteration; float32 needed 3 iterations to cover 23 mantissa bits from an
# initial guess good to a handful of bits, so float64's 52 bits need 5.
# Verified against libm sqrt() across a wide exponent range at <= 1 ulp
# (tests/x64_fmath64_test.w). 0.0 for f <= 0.0. Like fsqrt, the bit trick
# assumes a normalized layout (exponent field nonzero); subnormal inputs
# get a wildly-off initial guess and are outside the accuracy contract
# (fsqrt has the same gap for float32 subnormals -- confirmed empirically,
# not fixed here, since it's a pre-existing property of the ported
# algorithm rather than something specific to the float64 port).
float64 fsqrt64(float64 f):
	if (f <= 0.0):
		return 0.0
	int sign_clear = (1 << 63) - 1
	int bits = float64_bits(f) & sign_clear
	int magic = (0x1ff7a3be << 32) | (0xa000 << 16)
	float64 guess = float64_from_bits(magic + (bits >> 1))
	guess = 0.5 * (guess + f / guess)
	guess = 0.5 * (guess + f / guess)
	guess = 0.5 * (guess + f / guess)
	guess = 0.5 * (guess + f / guess)
	guess = 0.5 * (guess + f / guess)
	return guess
