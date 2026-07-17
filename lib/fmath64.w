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


########################## transcendentals ###########################
#
# float64 port of lib/fmath.w's exp/log/pow/trig section, same
# architecture (single-word kernels + Dekker-split pair arithmetic where
# a result must carry more than one word of precision), re-derived for
# double precision per docs/projects/engineering_math_baseline.md:
# every polynomial below was re-fit (Chebyshev interpolation in
# __float128 by a throwaway C fitter, coefficients rounded to float64)
# and every split constant recomputed at float64 widths -- none of the
# float32 constants survive. Each function's header states its measured
# ulp bound vs glibc's double functions (gcc -O0 -fno-fast-math
# -ffp-contract=off harness; ulp distance on the result's bit pattern
# via sign-corrected integer ordering, see the test), and the W build is
# proven bit-identical to that C model on a 37k-point deterministic
# grid before transferring the bounds.
#
# Style differences from the float32 section, both x64-only freedoms:
# - Constants are bare decimal literals: on x64 a bare decimal float
#   literal IS float64, and the compiler's decimal-to-binary conversion
#   is correctly rounded (asserted bit-for-bit for every
#   precision-critical constant in tests/x64_fmath64_test.w, and covered
#   wholesale by the grid diff above). No float64_from_bits noise.
# - The Dekker split keeps the top 21 significant bits (clears the low
#   32 mantissa bits, fdlibm __LO(x)=0 style) instead of float32's
#   12-bit split: products of two 21-bit values (42 significant bits)
#   are exact in float64's 53, with room for an 11-bit exponent word.
#   The hi+lo pair log2 core carries log2(x) to ~2^-64 relative, which
#   is what keeps fpow64 at ~1 ulp even where y*log2(x) is ~1000.


# Truncate to the top 21 significant bits (clear the low 32 mantissa
# bits): the building block for exact float64 products (21 bits x 21
# bits fits well inside a 53-bit significand).
float64 fsplit_hi64(float64 f):
	int himask = ((1 << 32) - 1) << 32
	return float64_from_bits(float64_bits(f) & himask)


# 2^t for t in [-0.5023, 0.5023], evaluated as 1 + t*h(t) with h a
# degree-11 Chebyshev fit of (2^t - 1)/t (fit error ~2^-55 absolute,
# ~2^-56 after the *t scaling), so fexp2_poly64(0.0) is exactly 1.0.
# Shared kernel of fexp264/fexp64/fpow64.
float64 fexp2_poly64(float64 t):
	float64 c0 = 6.9314718055994529e-01
	float64 c1 = 2.4022650695910072e-01
	float64 c2 = 5.5504108664821632e-02
	float64 c3 = 9.6181291076284803e-03
	float64 c4 = 1.3333558146405649e-03
	float64 c5 = 1.5403530393370328e-04
	float64 c6 = 1.5252733842604224e-05
	float64 c7 = 1.3215486809224025e-06
	float64 c8 = 1.0178056551509524e-07
	float64 c9 = 7.0548970387389927e-09
	float64 c10 = 4.4559128011303167e-10
	float64 c11 = 2.5729793869956175e-11
	return 1.0 + t * (c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * (c6 + t * (c7 + t * (c8 + t * (c9 + t * (c10 + t * c11)))))))))))


# p * 2^n for p in [0.7, 1.5): exponent-field addition on the bits, with
# +inf on overflow and a two-step scale (down by 2^(n+512), then *
# 2^-512) that rounds correctly into the subnormal range or to zero.
# n == 1024 also goes through a final float multiply so results
# straddling the largest finite float64 round to +inf exactly like the
# hardware would.
float64 fexp2_scale64(float64 p, int n):
	if (n > 1024):
		return float64_from_bits(0x7ff << 52)
	if (n == 1024):
		return float64_from_bits(float64_bits(p) + (1023 << 52)) * 2.0
	if (n < -1021):
		if (n < -1076):
			return 0.0
		float64 tiny = float64_from_bits(0x1ff << 52)    # 2^-512
		return float64_from_bits(float64_bits(p) + ((n + 512) << 52)) * tiny
	return float64_from_bits(float64_bits(p) + (n << 52))


# 2^x. Measured <= 1 ulp vs glibc exp2 over [-1080, 1030] (6.5M-point
# sweeps incl. subnormal results and the overflow edge). Edge contract:
# NaN -> NaN, x >= 1024 -> +inf (also +inf -> +inf), x < -1075ish -> 0
# (also -inf -> 0). Reduction n = round(x), t = x - n is exact
# (Sterbenz).
float64 fexp264(float64 x):
	if (f64is_nan(x)):
		return x
	if (x > 1026.0):
		return float64_from_bits(0x7ff << 52)
	if (x < -1080.0):
		return 0.0
	float64 fn = ffloor64(x + 0.5)
	int n = fn
	float64 t = x - fn
	return fexp2_scale64(fexp2_poly64(t), n)


# e^x. Measured <= 1 ulp vs glibc exp over [-746, 710] (6.5M-point
# sweeps incl. subnormal results and both edges). Edge contract:
# NaN -> NaN, overflow (x > 709.78, also +inf) -> +inf, x < -745.2ish
# (also -inf) -> 0. x*log2(e) is formed as an exact 21-bit-split product
# plus correction terms, so no accuracy is lost to the base change even
# for |x| near 710 (a plain product would cost ~2^-43 of the reduced
# argument there).
float64 fexp64(float64 x):
	if (f64is_nan(x)):
		return x
	if (x > 710.0):
		return float64_from_bits(0x7ff << 52)
	if (x < -746.0):
		return 0.0
	float64 l2eh = 1.4426946640014648e+00    # log2(e) top 21 bits
	float64 l2el = 3.7688749856360991e-07    # log2(e) - l2eh
	float64 l2e = 1.4426950408889634e+00    # log2(e) rounded
	float64 x1 = fsplit_hi64(x)
	float64 pa = x1 * l2eh
	float64 pb = (x - x1) * l2e + x1 * l2el
	float64 fn = ffloor64(pa + pb + 0.5)
	int n = fn
	float64 t = (pa - fn) + pb
	return fexp2_scale64(fexp2_poly64(t), n)


# log2(x) as a hi + lo pair for finite x > 0 (the caller filters
# specials). hi is truncated to 21 significant bits so y*hi is an exact
# product inside fpow64; hi + lo carries log2(x) to ~2^-64 relative.
# fdlibm e_pow-style, structured exactly like the float32 flog2_pair:
# normalize the mantissa to [sqrt2/2, sqrt2), take s = (m-1)/(m+1) with
# an exactly-computed low word, run the odd atanh series (degree-7 fit
# in s^2, error ~2^-69 on the r term), and track rounding residuals of
# every non-exact step in the lo word.
void flog2_pair64(float64 x, float64* hi_out, float64* lo_out):
	int bits = float64_bits(x)
	int e = 0
	if (bits < (1 << 52)):
		# subnormal input: scale by 2^54 (exact) and rebias
		float64 scale54 = 18014398509481984.0
		x = x * scale54
		bits = float64_bits(x)
		e = -54
	e = e + (bits >> 52) - 1023
	float64 m = float64_from_bits((bits & ((1 << 52) - 1)) | (1023 << 52))
	float64 sq2 = 1.4142135623730951e+00    # sqrt(2)
	if (m >= sq2):
		m = m * 0.5
		e = e + 1
	float64 u = m - 1.0    # exact (Sterbenz)
	float64 vv = m + 1.0    # rounds; exact residual recovered below
	float64 th = fsplit_hi64(vv)
	float64 tl = m - (th - 1.0)    # (m + 1) - th, exactly
	float64 s = u / vv
	float64 sh = fsplit_hi64(s)
	float64 sl = ((u - sh * th) - sh * tl) / vv
	# ln(m) = (2s/3)*(3 + s^2 + r), r = 3*sum(s^(2k)/(2k+1), k >= 2)
	float64 s2 = s * s
	float64 lc0 = 5.9999999999999998e-01
	float64 lc1 = 4.2857142857144048e-01
	float64 lc2 = 3.3333333332484216e-01
	float64 lc3 = 2.7272727503001498e-01
	float64 lc4 = 2.3076892453148620e-01
	float64 lc5 = 2.0002206531095179e-01
	float64 lc6 = 1.7559368158041094e-01
	float64 lc7 = 1.7584625206026827e-01
	float64 r = (s2 * s2) * (lc0 + s2 * (lc1 + s2 * (lc2 + s2 * (lc3 + s2 * (lc4 + s2 * (lc5 + s2 * (lc6 + s2 * lc7)))))))
	r = r + sl * (sh + s)    # s^2 correction: s^2 ~ sh^2 + sl*(sh + s)
	float64 s2h = sh * sh    # exact
	float64 t_h = fsplit_hi64(3.0 + s2h + r)
	float64 t_l = r - ((t_h - 3.0) - s2h)
	float64 u2 = sh * t_h    # exact
	float64 v2 = sl * t_h + t_l * s
	# log2(m) = cp * s * (3 + s^2 + r), cp = 2/(3 ln 2)
	float64 p_h = fsplit_hi64(u2 + v2)
	float64 p_l = v2 - (p_h - u2)
	float64 cph = 9.6179628372192383e-01    # 2/(3 ln 2) top 21 bits
	float64 cpl = 4.1020405177678161e-07    # 2/(3 ln 2) - cph
	float64 cp = 9.6179669392597555e-01    # 2/(3 ln 2) rounded
	float64 z_h = cph * p_h    # exact
	float64 z_l = cpl * p_h + p_l * cp
	float64 ef = e
	float64 t1 = fsplit_hi64(ef + z_h + z_l)
	float64 t2 = z_l - ((t1 - ef) - z_h)
	*hi_out = t1
	*lo_out = t2


# Shared special-case ladder for flog64/flog264/flog1064: NaN -> NaN,
# +-0 -> -inf, x < 0 (including -inf) -> NaN, +inf -> +inf. Returns 1
# and writes the result when x is one of those.
int flog_special64(float64 x, float64* result_out):
	if (f64is_nan(x)):
		*result_out = x
		return 1
	if (x == 0.0):
		*result_out = float64_from_bits(0xfff << 52)
		return 1
	if (float64_bits(x) < 0):
		*result_out = float64_from_bits(0x7ff8 << 48)
		return 1
	if (float64_bits(x) == (0x7ff << 52)):
		*result_out = x
		return 1
	return 0


# log base 2. Measured <= 1 ulp vs glibc log2 over all positive finite
# float64s (8M-point sweep incl. dense [0.5, 2] and subnormals); exact
# for powers of two. Edge contract: see flog_special64.
float64 flog264(float64 x):
	float64 special = 0.0
	if (flog_special64(x, &special)):
		return special
	float64 t1 = 0.0
	float64 t2 = 0.0
	flog2_pair64(x, &t1, &t2)
	return t1 + t2


# Natural log: (t1 + t2) * ln2 with a 21-bit-split ln2 so the leading
# product is exact. Measured <= 1 ulp vs glibc log over all positive
# finite float64s (8M-point sweep). Edge contract: see flog_special64.
float64 flog64(float64 x):
	float64 special = 0.0
	if (flog_special64(x, &special)):
		return special
	float64 t1 = 0.0
	float64 t2 = 0.0
	flog2_pair64(x, &t1, &t2)
	float64 ln2h = 6.9314670562744141e-01    # ln(2) top 21 bits
	float64 ln2l = 4.7493250390316726e-07    # ln(2) - ln2h
	float64 ln2 = 6.9314718055994529e-01    # ln(2) rounded
	return t1 * ln2h + (t2 * ln2 + t1 * ln2l)


# log base 10: (t1 + t2) * log10(2), split like flog64. Measured <= 2
# ulp vs glibc log10 over all positive finite float64s (8M-point sweep).
# Edge contract: see flog_special64.
float64 flog1064(float64 x):
	float64 special = 0.0
	if (flog_special64(x, &special)):
		return special
	float64 t1 = 0.0
	float64 t2 = 0.0
	flog2_pair64(x, &t1, &t2)
	float64 lgh = 3.0102992057800293e-01    # log10(2) top 21 bits
	float64 lgl = 7.5085978265526235e-08    # log10(2) - lgh
	float64 lg = 3.0102999566398120e-01    # log10(2) rounded
	return t1 * lgh + (t2 * lg + t1 * lgl)


# x^y as 2^(y * log2|x|) over the pair log2 core, so the exponent
# product keeps ~64 significant bits and the result stays accurate even
# when y*log2(x) is ~1000. Measured <= 1 ulp vs glibc pow on 10M sweep
# points: x = 2^u with y placed so y*log2(x) spans [-1080, 1030], bases
# near 1 with |y| up to ~1e12, integer y in [-40, 40] with bases of
# either sign, and moderate x/y grids. IEEE edge contract (verified
# against glibc): fpow64(x, +-0) = 1 and fpow64(1, y) = 1, even for NaN
# x/y; otherwise NaN in -> NaN out; fpow64(x, 1) = x; negative finite
# base: integer y uses the parity sign, non-integer y -> NaN; +-0 and
# +-inf bases and +-inf exponents follow IEEE 754 pow (signed
# zeros/infs included); overflow -> +-inf, underflow -> +-0.
float64 fpow64(float64 x, float64 y):
	int xbits = float64_bits(x)
	int ybits = float64_bits(y)
	int abs_mask = (1 << 63) - 1
	int one_bits = 1023 << 52
	int inf_bits = 0x7ff << 52
	# bit tests, not float compares: nan == 0.0 is true in W
	# (docs/projects/float.md), which would turn pow(2, nan) into 1
	if ((ybits & abs_mask) == 0):
		return 1.0
	if (xbits == one_bits):
		return 1.0
	if (f64is_nan(x)):
		return x
	if (f64is_nan(y)):
		return y
	if (ybits == one_bits):
		return x
	float64 ax = fabs64(x)
	if ((ybits & abs_mask) == inf_bits):
		# y = +-inf: 1 for |x| = 1, else pick 0 or inf by |x| vs 1
		if (ax == 1.0):
			return 1.0
		int bigger = 0
		if (ax > 1.0):
			bigger = 1
		if (y > 0.0):
			if (bigger):
				return float64_from_bits(inf_bits)
			return 0.0
		if (bigger):
			return 0.0
		return float64_from_bits(inf_bits)
	# y integer parity: 0 = not an integer, 1 = odd, 2 = even
	int yint = 0
	float64 ay = fabs64(y)
	float64 two53 = 9007199254740992.0    # 2^53
	if (ay >= two53):
		yint = 2    # every float64 >= 2^53 in magnitude is an even integer
	else:
		float64 fy = ffloor64(y)
		if (fy == y):
			float64 fh = fy * 0.5
			if (ffloor64(fh) == fh):
				yint = 2
			else:
				yint = 1
	if (x == 0.0):
		# +-0 base: result is 0 or inf by y's sign, negative only for
		# -0 with odd integer y
		int neg = 0
		if (xbits < 0 && yint == 1):
			neg = 1
		if (y > 0.0):
			if (neg):
				return float64_from_bits(1 << 63)
			return 0.0
		if (neg):
			return float64_from_bits(0xfff << 52)
		return float64_from_bits(inf_bits)
	if ((xbits & abs_mask) == inf_bits):
		# +-inf base, mirroring the zero rules
		int neg = 0
		if (xbits < 0 && yint == 1):
			neg = 1
		if (y > 0.0):
			if (neg):
				return float64_from_bits(0xfff << 52)
			return float64_from_bits(inf_bits)
		if (neg):
			return float64_from_bits(1 << 63)
		return 0.0
	int sgn = 0
	if (xbits < 0):
		if (yint == 0):
			return float64_from_bits(0x7ff8 << 48)
		if (yint == 1):
			sgn = 1
	float64 t1 = 0.0
	float64 t2 = 0.0
	flog2_pair64(ax, &t1, &t2)
	# y * (t1 + t2): y1*t1 is exact (both 21-bit), the rest is correction
	float64 y1 = fsplit_hi64(y)
	float64 ph = y1 * t1
	float64 pl = (y - y1) * t1 + y * t2
	float64 z = ph + pl
	if (z > 1026.0):
		if (sgn):
			return float64_from_bits(0xfff << 52)
		return float64_from_bits(inf_bits)
	if (z < -1080.0):
		if (sgn):
			return float64_from_bits(1 << 63)
		return 0.0
	float64 fn = ffloor64(z + 0.5)
	int n = fn
	float64 t = (ph - fn) + pl
	float64 res = fexp2_scale64(fexp2_poly64(t), n)
	if (sgn):
		return -res
	return res


# sin(r) for r in [-pi/4 - eps, pi/4 + eps]: r + r^3 * S(r^2), S a
# degree-5 Chebyshev fit (odd terms through r^13, like fdlibm's
# __kernel_sin). Trig kernel, ~1 ulp.
float64 fsin_poly64(float64 r):
	float64 s1 = -1.6666666666666666e-01
	float64 s2 = 8.3333333333309480e-03
	float64 s3 = -1.9841269836758582e-04
	float64 s4 = 2.7557316102556606e-06
	float64 s5 = -2.5051131845872101e-08
	float64 s6 = 1.5918129357436853e-10
	float64 u = r * r
	return r + (u * r) * (s1 + u * (s2 + u * (s3 + u * (s4 + u * (s5 + u * s6)))))


# cos(r) for r in [-pi/4 - eps, pi/4 + eps]: 1 - r^2/2 + r^4 * C(r^2)
# with the rounding residual of (1 - r^2/2) re-added so the leading
# terms lose nothing (musl __cos's trick, minus the reduced-argument
# tail word our single-word reduction doesn't carry). ~1 ulp.
float64 fcos_poly64(float64 r):
	float64 k1 = 4.1666666666666664e-02
	float64 k2 = -1.3888888888887398e-03
	float64 k3 = 2.4801587298765693e-05
	float64 k4 = -2.7557317271732398e-07
	float64 k5 = 2.0876146268946504e-09
	float64 k6 = -1.1382632464665116e-11
	float64 u = r * r
	float64 hu = u * 0.5
	float64 w = 1.0 - hu
	return w + (((1.0 - w) - hu) + (u * u) * (k1 + u * (k2 + u * (k3 + u * (k4 + u * (k5 + u * k6))))))


# Cody-Waite reduction by pi/2: writes r = x - n*pi/2 (|r| <= pi/4 +
# eps) and returns the quadrant n & 3. pi/2 is split into four parts,
# the top three truncated to 22 significant bits so fn * p_k is exact
# for |n| < 2^31 (|x| <= ~3.3e9); p4 is the remainder, correctly
# rounded against a 600-bit pi/2, so the ignored tail is ~2^-123 of
# pi/2 (~2^-92 absolute after * n) and the reduction error is
# ~2^-54*|r| + 2^-87. Beyond |x| ~ 3.3e9 the fn * p_k products start
# rounding and the absolute error in r grows like 2^-53 * |x|, reaching
# O(1) - total loss - at |x| ~ 2^52. No Payne-Hanek here by design -
# see docs/projects/engineering_math_baseline.md; the callers return
# fixed values for |x| >= 2^52 instead (every float64 there is an
# integer; no fractional phase survives to reduce).
int ftrig_reduce64(float64 x, float64* r_out):
	float64 invpio2 = 6.3661977236758138e-01    # 2/pi
	float64 p1 = 1.5707960128784180e+00    # pi/2 top 22 bits
	float64 p2 = 3.1391641641675960e-07    # next 22 bits
	float64 p3 = 6.2233719696699885e-14    # next 22 bits
	float64 p4 = 2.0222662487959506e-21    # remainder
	float64 fn = ffloor64(x * invpio2 + 0.5)
	int n = fn
	float64 r = (((x - fn * p1) - fn * p2) - fn * p3) - fn * p4
	*r_out = r
	return n & 3


# sin(x). Measured vs glibc sin: <= 1 ulp for |x| <= 100, <= 2 ulp for
# |x| <= 3.3e9 (12M-point sweeps); accuracy degrades beyond (see
# ftrig_reduce64), and |x| >= 2^52 returns 0.0 by contract. Edge
# contract: NaN -> NaN, +-inf -> NaN, +-0 -> +-0 (sign preserved;
# |x| < 2^-27 returns x, which is sin(x) correctly rounded there).
float64 fsin64(float64 x):
	if (f64is_nan(x)):
		return x
	int ab = float64_bits(x) & ((1 << 63) - 1)
	if (ab == (0x7ff << 52)):
		return float64_from_bits(0x7ff8 << 48)
	if (ab < (0x3e4 << 52)):
		return x
	if (ab >= (0x433 << 52)):
		return 0.0
	float64 r = 0.0
	int q = ftrig_reduce64(x, &r)
	if (q == 0):
		return fsin_poly64(r)
	if (q == 1):
		return fcos_poly64(r)
	if (q == 2):
		return -fsin_poly64(r)
	return -fcos_poly64(r)


# cos(x). Measured vs glibc cos: <= 2 ulp for |x| <= 3.3e9 (<= 1 ulp on
# the reduction-free kernel range |x| <= pi/4; 12M-point sweeps);
# degrades beyond (see ftrig_reduce64), and |x| >= 2^52 returns 1.0 by
# contract. Edge contract: NaN -> NaN, +-inf -> NaN, cos(+-0) = 1.
float64 fcos64(float64 x):
	if (f64is_nan(x)):
		return x
	int ab = float64_bits(x) & ((1 << 63) - 1)
	if (ab == (0x7ff << 52)):
		return float64_from_bits(0x7ff8 << 48)
	if (ab >= (0x433 << 52)):
		return 1.0
	float64 r = 0.0
	int q = ftrig_reduce64(x, &r)
	if (q == 0):
		return fcos_poly64(r)
	if (q == 1):
		return -fsin_poly64(r)
	if (q == 2):
		return -fcos_poly64(r)
	return fsin_poly64(r)


# tan(x) = sin/cos (or -cos/sin in odd quadrants) over the shared
# kernels. Measured vs glibc tan: <= 2 ulp for |x| <= pi/4, <= 3 ulp
# for |x| <= 100, <= 4 ulp for |x| <= 3.3e9 (12M-point sweeps);
# degrades beyond (see ftrig_reduce64), and |x| >= 2^52 returns 0.0 by
# contract. Edge contract: NaN -> NaN, +-inf -> NaN, +-0 -> +-0
# (|x| < 2^-27 returns x, correctly rounded there). Near odd multiples
# of pi/2 the result is huge but finite, like glibc's.
float64 ftan64(float64 x):
	if (f64is_nan(x)):
		return x
	int ab = float64_bits(x) & ((1 << 63) - 1)
	if (ab == (0x7ff << 52)):
		return float64_from_bits(0x7ff8 << 48)
	if (ab < (0x3e4 << 52)):
		return x
	if (ab >= (0x433 << 52)):
		return 0.0
	float64 r = 0.0
	int q = ftrig_reduce64(x, &r)
	if (q == 0 || q == 2):
		return fsin_poly64(r) / fcos_poly64(r)
	return -(fcos_poly64(r) / fsin_poly64(r))


# atan(x). Cephes-style range reduction like the float32 fatan:
# |x| > tan(3pi/8) folds to pi/2 - atan(1/x), |x| > tan(pi/8) to
# pi/4 + atan((x-1)/(x+1)), then a degree-11 odd Chebyshev polynomial
# on the rest. Measured <= 2 ulp vs glibc atan over all finite float64s
# (6M-point sweep). Edge contract: NaN -> NaN, +-inf -> +-pi/2,
# +-0 -> +-0.
float64 fatan64(float64 x):
	if (f64is_nan(x)):
		return x
	int sgn = 0
	if (float64_bits(x) < 0):
		sgn = 1
	float64 ax = fabs64(x)
	float64 pio2 = 1.5707963267948966e+00
	if (float64_bits(ax) == (0x7ff << 52)):
		if (sgn):
			return -pio2
		return pio2
	float64 t3p8 = 2.4142135623730949e+00    # tan(3pi/8)
	float64 tp8 = 4.1421356237309503e-01    # tan(pi/8)
	float64 base = 0.0
	float64 w = ax
	if (ax > t3p8):
		base = pio2
		w = -(1.0 / ax)
	else if (ax > tp8):
		base = 7.8539816339744828e-01    # pi/4
		w = (ax - 1.0) / (ax + 1.0)
	float64 a0 = -3.3333333333333331e-01
	float64 a1 = 1.9999999999999804e-01
	float64 a2 = -1.4285714285659828e-01
	float64 a3 = 1.1111111105155411e-01
	float64 a4 = -9.0909087534991190e-02
	float64 a5 = 7.6922963749813333e-02
	float64 a6 = -6.6664248848256863e-02
	float64 a7 = 5.8789289873420608e-02
	float64 a8 = -5.2304541933703950e-02
	float64 a9 = 4.5515928681113281e-02
	float64 a10 = -3.4570552915429556e-02
	float64 a11 = 1.6285746807996566e-02
	float64 z = w * w
	float64 p = a0 + z * (a1 + z * (a2 + z * (a3 + z * (a4 + z * (a5 + z * (a6 + z * (a7 + z * (a8 + z * (a9 + z * (a10 + z * a11))))))))))
	float64 res = base + (w + (z * w) * p)
	if (sgn):
		return -res
	return res


# atan2(y, x): quadrant-correct atan(y/x). Measured <= 3 ulp vs glibc
# atan2 (8M-point sweep over mixed-magnitude finite pairs). Edge
# contract follows IEEE/glibc, verified bit-exactly in the tests:
# NaN in -> NaN out; atan2(+-0, x > 0 or +0) = +-0;
# atan2(+-0, x < 0 or -0) = +-pi; atan2(y != 0, +-0) = +-pi/2;
# x = +inf -> +-0, x = -inf -> +-pi (finite y); y = +-inf -> +-pi/2
# (finite x); (+-inf, +inf) = +-pi/4, (+-inf, -inf) = +-3pi/4.
# y/x overflow and underflow fall out correctly (pi/2- and pi-limits).
float64 fatan264(float64 y, float64 x):
	if (f64is_nan(y)):
		return y
	if (f64is_nan(x)):
		return x
	int xbits = float64_bits(x)
	int ybits = float64_bits(y)
	int sy = 0
	if (ybits < 0):
		sy = 1
	float64 pi = 3.1415926535897931e+00
	float64 pio2 = 1.5707963267948966e+00
	int abs_mask = (1 << 63) - 1
	int inf_bits = 0x7ff << 52
	int x_inf = 0
	if ((xbits & abs_mask) == inf_bits):
		x_inf = 1
	int y_inf = 0
	if ((ybits & abs_mask) == inf_bits):
		y_inf = 1
	if (y_inf):
		float64 base = pio2
		if (x_inf):
			if (xbits < 0):
				base = 2.3561944901923448e+00    # 3pi/4
			else:
				base = 7.8539816339744828e-01    # pi/4
		if (sy):
			return -base
		return base
	if (x_inf):
		if (xbits < 0):
			if (sy):
				return -pi
			return pi
		if (sy):
			return float64_from_bits(1 << 63)
		return 0.0
	if (y == 0.0):
		if (x < 0.0 || xbits < 0):
			if (sy):
				return -pi
			return pi
		return y
	if (x == 0.0):
		if (sy):
			return -pio2
		return pio2
	if (x > 0.0):
		return fatan64(y / x)
	float64 m = fatan64(fabs64(y / x))
	float64 pi_lo = 1.2246467991473532e-16    # pi - pi_hi
	float64 res = (pi - m) + pi_lo
	if (sy):
		return -res
	return res


# (asin(x) - x) / (x * z) for z = x^2 in [0, 0.2501]: degree-13
# Chebyshev fit, shared by fasin64 and facos64
# (asin(x) = x + x*z*P(z)).
float64 fasin_poly64(float64 z):
	float64 c0 = 1.6666666666666666e-01
	float64 c1 = 7.5000000000001191e-02
	float64 c2 = 4.4642857142550188e-02
	float64 c3 = 3.0381944475693704e-02
	float64 c4 = 2.2372157435623815e-02
	float64 c5 = 1.7352816768546473e-02
	float64 c6 = 1.3963775787848137e-02
	float64 c7 = 1.1566511821890942e-02
	float64 c8 = 9.6214027473448295e-03
	float64 c9 = 9.3221015010827735e-03
	float64 c10 = 3.0350071727267623e-03
	float64 c11 = 1.9579201619744684e-02
	float64 c12 = -1.9277545928584557e-02
	float64 c13 = 2.9635026263548549e-02
	return c0 + z * (c1 + z * (c2 + z * (c3 + z * (c4 + z * (c5 + z * (c6 + z * (c7 + z * (c8 + z * (c9 + z * (c10 + z * (c11 + z * (c12 + z * c13))))))))))))


# asin(x). |x| <= 0.5 uses the kernel directly; |x| in (0.5, 1] uses
# asin(x) = pi/2 - 2*asin(sqrt((1-x)/2)) with pi/2 as a hi+lo pair so
# the constant costs nothing. Measured <= 2 ulp vs glibc asin over
# [-1, 1] (8M-point sweep incl. dense [0.99, 1]). Edge contract:
# NaN -> NaN, |x| > 1 -> NaN, asin(+-1) = +-pi/2, asin(+-0) = +-0.
float64 fasin64(float64 x):
	if (f64is_nan(x)):
		return x
	int sgn = 0
	if (float64_bits(x) < 0):
		sgn = 1
	float64 ax = fabs64(x)
	if (ax > 1.0):
		return float64_from_bits(0x7ff8 << 48)
	float64 res = 0.0
	if (ax <= 0.5):
		float64 z = ax * ax
		res = ax + (ax * z) * fasin_poly64(z)
	else:
		float64 z = (1.0 - ax) * 0.5
		float64 s = fsqrt64(z)
		float64 t = s + (s * z) * fasin_poly64(z)
		float64 pio2hi = 1.5707963267948966e+00
		float64 pio2lo = 6.1232339957367660e-17
		res = (pio2hi - 2.0 * t) + pio2lo
	if (sgn):
		return -res
	return res


# acos(x). |x| <= 0.5 is pi/2 - asin(x); x in (0.5, 1] is
# 2*asin(sqrt((1-x)/2)) (cancellation-free near 1); x in [-1, -0.5) is
# pi - that. Measured <= 1 ulp vs glibc acos over [-1, 1] (8M-point
# sweep). Edge contract: NaN -> NaN, |x| > 1 -> NaN, acos(1) = +0,
# acos(-1) = pi.
float64 facos64(float64 x):
	if (f64is_nan(x)):
		return x
	int sgn = 0
	if (float64_bits(x) < 0):
		sgn = 1
	float64 ax = fabs64(x)
	if (ax > 1.0):
		return float64_from_bits(0x7ff8 << 48)
	if (ax <= 0.5):
		float64 z = x * x
		float64 t = x + (x * z) * fasin_poly64(z)
		float64 pio2hi = 1.5707963267948966e+00
		float64 pio2lo = 6.1232339957367660e-17
		return (pio2hi - t) + pio2lo
	float64 z = (1.0 - ax) * 0.5
	float64 s = fsqrt64(z)
	float64 t = s + (s * z) * fasin_poly64(z)
	if (sgn == 0):
		return 2.0 * t
	float64 pihi = 3.1415926535897931e+00
	float64 pilo = 1.2246467991473532e-16
	return (pihi - 2.0 * t) + pilo
