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
	if ((bits & exp_mask) != exp_mask): return 0
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
	if (f < whole): return whole - 1.0
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
	if (f <= 0.0): return 0.0
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
	if (n > 1024): return float64_from_bits(0x7ff << 52)
	if (n == 1024): return float64_from_bits(float64_bits(p) + (1023 << 52)) * 2.0
	if (n < -1021):
		if (n < -1076): return 0.0
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
	if (x > 1026.0): return float64_from_bits(0x7ff << 52)
	if (x < -1080.0): return 0.0
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
	if (x > 710.0): return float64_from_bits(0x7ff << 52)
	if (x < -746.0): return 0.0
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
	if ((ybits & abs_mask) == 0): return 1.0
	if (xbits == one_bits): return 1.0
	if (f64is_nan(x)):
		return x
	if (f64is_nan(y)):
		return y
	if (ybits == one_bits):
		return x
	float64 ax = fabs64(x)
	if ((ybits & abs_mask) == inf_bits):
		# y = +-inf: 1 for |x| = 1, else pick 0 or inf by |x| vs 1
		if (ax == 1.0): return 1.0
		int bigger = 0
		if (ax > 1.0): bigger = 1
		if (y > 0.0):
			if (bigger): return float64_from_bits(inf_bits)
			return 0.0
		if (bigger): return 0.0
		return float64_from_bits(inf_bits)
	# y integer parity: 0 = not an integer, 1 = odd, 2 = even
	int yint = 0
	float64 ay = fabs64(y)
	float64 two53 = 9007199254740992.0    # 2^53
	if (ay >= two53): yint = 2    # every float64 >= 2^53 in magnitude is an even integer
	else:
		float64 fy = ffloor64(y)
		if (fy == y):
			float64 fh = fy * 0.5
			if (ffloor64(fh) == fh): yint = 2
			else: yint = 1
	if (x == 0.0):
		# +-0 base: result is 0 or inf by y's sign, negative only for
		# -0 with odd integer y
		int neg = 0
		if (xbits < 0 && yint == 1): neg = 1
		if (y > 0.0):
			if (neg): return float64_from_bits(1 << 63)
			return 0.0
		if (neg): return float64_from_bits(0xfff << 52)
		return float64_from_bits(inf_bits)
	if ((xbits & abs_mask) == inf_bits):
		# +-inf base, mirroring the zero rules
		int neg = 0
		if (xbits < 0 && yint == 1): neg = 1
		if (y > 0.0):
			if (neg): return float64_from_bits(0xfff << 52)
			return float64_from_bits(inf_bits)
		if (neg): return float64_from_bits(1 << 63)
		return 0.0
	int sgn = 0
	if (xbits < 0):
		if (yint == 0): return float64_from_bits(0x7ff8 << 48)
		if (yint == 1): sgn = 1
	float64 t1 = 0.0
	float64 t2 = 0.0
	flog2_pair64(ax, &t1, &t2)
	# y * (t1 + t2): y1*t1 is exact (both 21-bit), the rest is correction
	float64 y1 = fsplit_hi64(y)
	float64 ph = y1 * t1
	float64 pl = (y - y1) * t1 + y * t2
	float64 z = ph + pl
	if (z > 1026.0):
		if (sgn): return float64_from_bits(0xfff << 52)
		return float64_from_bits(inf_bits)
	if (z < -1080.0):
		if (sgn): return float64_from_bits(1 << 63)
		return 0.0
	float64 fn = ffloor64(z + 0.5)
	int n = fn
	float64 t = (ph - fn) + pl
	float64 res = fexp2_scale64(fexp2_poly64(t), n)
	if (sgn): return -res
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
	if (ab == (0x7ff << 52)): return float64_from_bits(0x7ff8 << 48)
	if (ab < (0x3e4 << 52)):
		return x
	if (ab >= (0x433 << 52)): return 0.0
	float64 r = 0.0
	int q = ftrig_reduce64(x, &r)
	if (q == 0): return fsin_poly64(r)
	if (q == 1): return fcos_poly64(r)
	if (q == 2): return -fsin_poly64(r)
	return -fcos_poly64(r)


# cos(x). Measured vs glibc cos: <= 2 ulp for |x| <= 3.3e9 (<= 1 ulp on
# the reduction-free kernel range |x| <= pi/4; 12M-point sweeps);
# degrades beyond (see ftrig_reduce64), and |x| >= 2^52 returns 1.0 by
# contract. Edge contract: NaN -> NaN, +-inf -> NaN, cos(+-0) = 1.
float64 fcos64(float64 x):
	if (f64is_nan(x)):
		return x
	int ab = float64_bits(x) & ((1 << 63) - 1)
	if (ab == (0x7ff << 52)): return float64_from_bits(0x7ff8 << 48)
	if (ab >= (0x433 << 52)): return 1.0
	float64 r = 0.0
	int q = ftrig_reduce64(x, &r)
	if (q == 0): return fcos_poly64(r)
	if (q == 1): return -fsin_poly64(r)
	if (q == 2): return -fcos_poly64(r)
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
	if (ab == (0x7ff << 52)): return float64_from_bits(0x7ff8 << 48)
	if (ab < (0x3e4 << 52)):
		return x
	if (ab >= (0x433 << 52)): return 0.0
	float64 r = 0.0
	int q = ftrig_reduce64(x, &r)
	if (q == 0 || q == 2): return fsin_poly64(r) / fcos_poly64(r)
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
	if (float64_bits(x) < 0): sgn = 1
	float64 ax = fabs64(x)
	float64 pio2 = 1.5707963267948966e+00
	if (float64_bits(ax) == (0x7ff << 52)):
		if (sgn): return -pio2
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
	if (sgn): return -res
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
	if (ybits < 0): sy = 1
	float64 pi = 3.1415926535897931e+00
	float64 pio2 = 1.5707963267948966e+00
	int abs_mask = (1 << 63) - 1
	int inf_bits = 0x7ff << 52
	int x_inf = 0
	if ((xbits & abs_mask) == inf_bits): x_inf = 1
	int y_inf = 0
	if ((ybits & abs_mask) == inf_bits): y_inf = 1
	if (y_inf):
		float64 base = pio2
		if (x_inf):
			if (xbits < 0): base = 2.3561944901923448e+00    # 3pi/4
			else: base = 7.8539816339744828e-01    # pi/4
		if (sy): return -base
		return base
	if (x_inf):
		if (xbits < 0):
			if (sy): return -pi
			return pi
		if (sy): return float64_from_bits(1 << 63)
		return 0.0
	if (y == 0.0):
		if (x < 0.0 || xbits < 0):
			if (sy): return -pi
			return pi
		return y
	if (x == 0.0):
		if (sy): return -pio2
		return pio2
	if (x > 0.0): return fatan64(y / x)
	float64 m = fatan64(fabs64(y / x))
	float64 pi_lo = 1.2246467991473532e-16    # pi - pi_hi
	float64 res = (pi - m) + pi_lo
	if (sy): return -res
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
	if (float64_bits(x) < 0): sgn = 1
	float64 ax = fabs64(x)
	if (ax > 1.0): return float64_from_bits(0x7ff8 << 48)
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
	if (sgn): return -res
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
	if (float64_bits(x) < 0): sgn = 1
	float64 ax = fabs64(x)
	if (ax > 1.0): return float64_from_bits(0x7ff8 << 48)
	if (ax <= 0.5):
		float64 z = x * x
		float64 t = x + (x * z) * fasin_poly64(z)
		float64 pio2hi = 1.5707963267948966e+00
		float64 pio2lo = 6.1232339957367660e-17
		return (pio2hi - t) + pio2lo
	float64 z = (1.0 - ax) * 0.5
	float64 s = fsqrt64(z)
	float64 t = s + (s * z) * fasin_poly64(z)
	if (sgn == 0): return 2.0 * t
	float64 pihi = 3.1415926535897931e+00
	float64 pilo = 1.2246467991473532e-16
	return (pihi - 2.0 * t) + pilo


######################## Python math extras ##########################
#
# The rest of Python's math module surface that has no float64 home
# yet (docs/projects/stdlib_python_parity.md, chunk P3.6): IEEE
# predicates and helpers, hypot, isclose, expm1/log1p, the hyperbolic
# family, erf/erfc and gamma/lgamma. Integer factorial/comb/perm/isqrt
# live in libs/standard/numeric/intmath.w (they are word-sized and
# compile on every target, unlike this x64-only module).
#
# Accuracy strategy: most of these functions are evaluated with a
# double-double ("dd") tail -- a float64 pair hi + lo carrying ~2^-100
# of relative precision through the steps that would otherwise each
# cost half an ulp -- so the final answer is rounded once. The
# polynomial kernels were fitted by Chebyshev interpolation in mpmath at
# 50 digits and rounded to float64 (fit errors noted per kernel). Each
# public function's header gives the bound measured against mpmath
# references (tens of thousands of points per function, see
# lib/fmath64_test.w for the embedded spot checks). Where Python's math
# module raises (domain or range errors), these return the IEEE / C99
# value instead: NaN for a domain error, +-inf for a pole or overflow.


# 1 when f is +inf or -inf.
int f64is_inf(float64 f):
	int abs_mask = (1 << 63) - 1
	return (float64_bits(f) & abs_mask) == (0x7ff << 52)


# 1 when f is neither infinite nor NaN.
int f64is_finite(float64 f):
	int exp_mask = 0x7ff << 52
	return (float64_bits(f) & exp_mask) != exp_mask


# |mag| with the sign bit of sgn (Python math.copysign); works on
# zeros, infinities and NaNs alike since it only moves the sign bit.
float64 fcopysign64(float64 mag, float64 sgn):
	int sign_bit = 1 << 63
	int abs_mask = sign_bit - 1
	return float64_from_bits((float64_bits(mag) & abs_mask) | (float64_bits(sgn) & sign_bit))


# f * 2^n, exact unless the result over- or underflows; overflow gives
# +-inf and a subnormal result is rounded once (Python math.ldexp,
# minus the OverflowError). Zeros, infinities and NaN pass through.
float64 fldexp64(float64 f, int n):
	int sign_bit = 1 << 63
	int abs_mask = sign_bit - 1
	int bits = float64_bits(f)
	int mag = bits & abs_mask
	if (mag == 0 || mag >= (0x7ff << 52) || n == 0): return f
	if (mag < (1 << 52)):
		# subnormal input: normalize first (2^54 is exact)
		float64 scale54 = 18014398509481984.0
		f = f * scale54
		bits = float64_bits(f)
		mag = bits & abs_mask
		n = n - 54
	int e = mag >> 52
	if (n > 2100): n = 2100
	if (n < -2100): n = -2100
	int ne = e + n
	if (ne >= 2047):
		return float64_from_bits((bits & sign_bit) | (0x7ff << 52))
	if (ne >= 1):
		return float64_from_bits((bits & sign_bit) | (ne << 52) | (mag & ((1 << 52) - 1)))
	if (ne < -60):
		return float64_from_bits(bits & sign_bit)
	# subnormal result: build the value 2^1000 too large (still normal)
	# and let one multiply by 2^-1000 round it into place
	float64 big = float64_from_bits((bits & sign_bit) | ((ne + 1000) << 52) | (mag & ((1 << 52) - 1)))
	float64 tiny = float64_from_bits((1023 - 1000) << 52)
	return big * tiny


# A float64 pair hi + lo with |lo| <= ulp(hi)/2: the double-double
# value the helpers below compute with.
struct f64dd:
	float64 hi
	float64 lo


# a with the low 27 mantissa bits cleared: a 26-bit head whose products
# with another split head are exact. A bit mask rather than Veltkamp's
# multiply-by-(2^27+1) split, so it cannot overflow for huge a.
float64 fm64_split(float64 a):
	int mask = ~((1 << 27) - 1)
	return float64_from_bits(float64_bits(a) & mask)


# a + b exactly, as rounded sum plus error (Knuth's TwoSum; any order).
f64dd fm64_two_sum(float64 a, float64 b):
	float64 s = a + b
	float64 bb = s - a
	float64 err = (a - (s - bb)) + (b - bb)
	return f64dd(s, err)


# a + b as a normalized pair when |a| >= |b| (Dekker's FastTwoSum).
f64dd fm64_fast_two_sum(float64 a, float64 b):
	float64 s = a + b
	return f64dd(s, b - (s - a))


# a * b as rounded product plus error. With the 26/27-bit mask split
# every partial product except al*bl is exact, so the pair is good to
# ~2^-106 relative (not bit-exact, which nothing here needs).
f64dd fm64_two_prod(float64 a, float64 b):
	float64 p = a * b
	float64 ah = fm64_split(a)
	float64 al = a - ah
	float64 bh = fm64_split(b)
	float64 bl = b - bh
	float64 err = (((ah * bh - p) + ah * bl) + al * bh) + al * bl
	return f64dd(p, err)


f64dd fm64_dd(float64 hi):
	return f64dd(hi, 0.0)


f64dd fm64_dd_add(f64dd a, f64dd b):
	f64dd s = fm64_two_sum(a.hi, b.hi)
	return fm64_fast_two_sum(s.hi, s.lo + (a.lo + b.lo))


f64dd fm64_dd_neg(f64dd a):
	return f64dd(-a.hi, -a.lo)


f64dd fm64_dd_mul(f64dd a, f64dd b):
	f64dd p = fm64_two_prod(a.hi, b.hi)
	return fm64_fast_two_sum(p.hi, p.lo + (a.hi * b.lo + a.lo * b.hi))


f64dd fm64_dd_div(f64dd a, f64dd b):
	float64 q = a.hi / b.hi
	f64dd qb = fm64_dd_mul(fm64_dd(q), b)
	f64dd r = fm64_dd_add(a, fm64_dd_neg(qb))
	return fm64_fast_two_sum(q, r.hi / b.hi)


# sqrt(a) for a dd a with a.hi a positive normal float64: fsqrt64's
# <= 1 ulp guess plus one Newton step on the exact residual, so the
# pair is good to ~2^-100 and its rounded hi is the correctly rounded
# root in all but astronomically rare halfway cases.
f64dd fm64_dd_sqrt(f64dd a):
	float64 s = fsqrt64(a.hi)
	f64dd sq = fm64_two_prod(s, s)
	float64 resid = ((a.hi - sq.hi) - sq.lo) + a.lo
	return fm64_fast_two_sum(s, resid / (2.0 * s))


# (expm1(r) - r - r^2/2) / r^3 for |r| <= 0.35: degree-11 Chebyshev fit
# (fit error ~2^-67 relative). Kernel of fm64_exp_reduced.
float64 fm64_expm1_q(float64 r):
	float64 c0 = 1.66666666666666657e-01
	float64 c1 = 4.16666666666666644e-02
	float64 c2 = 8.33333333333333322e-03
	float64 c3 = 1.38888888888888894e-03
	float64 c4 = 1.98412698412627695e-04
	float64 c5 = 2.48015873015828834e-05
	float64 c6 = 2.75573192486172083e-06
	float64 c7 = 2.75573192393783351e-07
	float64 c8 = 2.50520696122346768e-08
	float64 c9 = 2.08767327576227868e-09
	float64 c10 = 1.60871709079406270e-10
	float64 c11 = 1.14883233675480086e-11
	return c0 + r * (c1 + r * (c2 + r * (c3 + r * (c4 + r * (c5 + r * (c6 + r * (c7 + r * (c8 + r * (c9 + r * (c10 + r * c11))))))))))


# erf(x)/x - 1 as a function of z = x^2 for |x| < 0.84375: degree-11
# Chebyshev fit (error ~2^-63 absolute), last Horner step in dd.
f64dd fm64_erf_small(float64 z):
	float64 c0 = 1.28379167095512586e-01
	float64 c1 = -3.76126389031837483e-01
	float64 c2 = 1.12837916709547445e-01
	float64 c3 = -2.68661706450309991e-02
	float64 c4 = 5.22397762408074225e-03
	float64 c5 = -8.54832691425111966e-04
	float64 c6 = 1.20553274212826825e-04
	float64 c7 = -1.49254635702876747e-05
	float64 c8 = 1.64579143497461033e-06
	float64 c9 = -1.63030950846888690e-07
	float64 c10 = 1.42055948505040564e-08
	float64 c11 = -8.87970270498584819e-10
	float64 r = c1 + z * (c2 + z * (c3 + z * (c4 + z * (c5 + z * (c6 + z * (c7 + z * (c8 + z * (c9 + z * (c10 + z * c11)))))))))
	return fm64_dd_add(fm64_dd(c0), fm64_two_prod(z, r))


# (erf(1 + s) - ERX - c0) / s for s in [-0.15625, 0.25], ERX = erf(1)
# rounded to float64 and c0 = -2.48013129463580059e-17 the constant term
# the caller adds back: degree-15 Chebyshev fit (error ~2^-67).
float64 fm64_erf_mid(float64 s):
	float64 c1 = 4.15107497420594718e-01
	float64 c2 = -4.15107497420594718e-01
	float64 c3 = 1.38369165806864924e-01
	float64 c4 = 6.91845829034318793e-02
	float64 c5 = -6.91845829034363202e-02
	float64 c6 = 4.61230552702055450e-03
	float64 c7 = 1.51547181600861485e-02
	float64 c8 = -4.77703073753645100e-03
	float64 c9 = -1.88518836263136926e-03
	float64 c10 = 1.22628829397842024e-03
	float64 c11 = 8.55220926120472209e-05
	float64 c12 = -2.00072774091895379e-04
	float64 c13 = 1.87998491665890765e-05
	float64 c14 = 2.38012083414225658e-05
	float64 c15 = -6.62704254585298409e-06
	return c1 + s * (c2 + s * (c3 + s * (c4 + s * (c5 + s * (c6 + s * (c7 + s * (c8 + s * (c9 + s * (c10 + s * (c11 + s * (c12 + s * (c13 + s * (c14 + s * c15)))))))))))))


# erfc(x) * e^(x^2) for x in [1.25, 2] as a polynomial in u = x - 1.625
# (degree 15, fit error ~2^-62 relative). h2..h5 cover [2, 2.75],
# [2.75, 3.5], [3.5, 4.5] and [4.5, 6] the same way around each
# interval's midpoint.
f64dd fm64_erfc_h1(float64 u):
	float64 c0 = 3.02261209363485939e-01
	float64 c1 = -1.46030236664183355e-01
	float64 c2 = 6.49620747841880147e-02
	float64 c3 = -2.69779100932519174e-02
	float64 c4 = 1.05614854413221479e-02
	float64 c5 = -3.92619850043713498e-03
	float64 c6 = 1.39380429297023488e-03
	float64 c7 = -4.74647578580383444e-04
	float64 c8 = 1.55625487000146402e-04
	float64 c9 = -4.92791425668372287e-05
	float64 c10 = 1.51094890545245356e-05
	float64 c11 = -4.49573913390436646e-06
	float64 c12 = 1.29970218248959849e-06
	float64 c13 = -3.66246373498579328e-07
	float64 c14 = 1.04808990051265887e-07
	float64 c15 = -2.80882261523424910e-08
	float64 r = c1 + u * (c2 + u * (c3 + u * (c4 + u * (c5 + u * (c6 + u * (c7 + u * (c8 + u * (c9 + u * (c10 + u * (c11 + u * (c12 + u * (c13 + u * (c14 + u * c15)))))))))))))
	return fm64_dd_add(fm64_dd(c0), fm64_two_prod(u, r))


f64dd fm64_erfc_h2(float64 u):
	float64 c0 = 2.20505692204906678e-01
	float64 c1 = -8.09771291222059209e-02
	float64 c2 = 2.81850105396676126e-02
	float64 c3 = -9.35848606032984448e-03
	float64 c4 = 2.97930307319157518e-03
	float64 c5 = -9.13056504629191495e-04
	float64 c6 = 2.70264624928975470e-04
	float64 c7 = -7.74794334154884029e-05
	float64 c8 = 2.15627418251040553e-05
	float64 c9 = -5.83733314211213122e-06
	float64 c10 = 1.53982727957164456e-06
	float64 c11 = -3.96247374522338664e-07
	float64 c12 = 9.96894426624109483e-08
	float64 c13 = -2.52973261745794787e-08
	float64 c14 = 6.09202190779749291e-09
	float64 r = c1 + u * (c2 + u * (c3 + u * (c4 + u * (c5 + u * (c6 + u * (c7 + u * (c8 + u * (c9 + u * (c10 + u * (c11 + u * (c12 + u * (c13 + u * c14))))))))))))
	return fm64_dd_add(fm64_dd(c0), fm64_two_prod(u, r))


f64dd fm64_erfc_h3(float64 u):
	float64 c0 = 1.72444352102173598e-01
	float64 c1 = -5.06019664569275218e-02
	float64 c2 = 1.43132069242750473e-02
	float64 c3 = -3.91546321237856362e-03
	float64 c4 = 1.03869219280123062e-03
	float64 c5 = -2.67820043957485432e-04
	float64 c6 = 6.72515182555272082e-05
	float64 c7 = -1.64740138719580817e-05
	float64 c8 = 3.94256074908242052e-06
	float64 c9 = -9.23006642933284353e-07
	float64 c10 = 2.11585811277627227e-07
	float64 c11 = -4.75635604341191890e-08
	float64 c12 = 1.07357235434146990e-08
	float64 c13 = -2.32418102017890565e-09
	float64 r = c1 + u * (c2 + u * (c3 + u * (c4 + u * (c5 + u * (c6 + u * (c7 + u * (c8 + u * (c9 + u * (c10 + u * (c11 + u * (c12 + u * c13)))))))))))
	return fm64_dd_add(fm64_dd(c0), fm64_two_prod(u, r))


f64dd fm64_erfc_h4(float64 u):
	float64 c0 = 1.36999457625061383e-01
	float64 c1 = -3.23835060950214554e-02
	float64 c2 = 7.46543324497557070e-03
	float64 c3 = -1.68118207674605616e-03
	float64 c4 = 3.70352468995545857e-04
	float64 c5 = -7.99088803080731354e-05
	float64 c6 = 1.69056492582338744e-05
	float64 c7 = -3.51036660193122650e-06
	float64 c8 = 7.16045655931281092e-07
	float64 c9 = -1.43596910234794227e-07
	float64 c10 = 2.83320635534228814e-08
	float64 c11 = -5.50092653458702338e-09
	float64 c12 = 1.05264202820732481e-09
	float64 c13 = -2.05093660892093746e-10
	float64 c14 = 3.81153452868556328e-11
	float64 r = c1 + u * (c2 + u * (c3 + u * (c4 + u * (c5 + u * (c6 + u * (c7 + u * (c8 + u * (c9 + u * (c10 + u * (c11 + u * (c12 + u * (c13 + u * c14))))))))))))
	return fm64_dd_add(fm64_dd(c0), fm64_two_prod(u, r))


f64dd fm64_erfc_h5(float64 u):
	float64 c0 = 1.05612735468891800e-01
	float64 c1 = -1.94454446721486485e-02
	float64 c2 = 3.52415094011139952e-03
	float64 c3 = -6.29101491042543723e-04
	float64 c4 = 1.10684056068920719e-04
	float64 c5 = -1.92040786720549184e-05
	float64 c6 = 3.28754768166225602e-06
	float64 c7 = -5.55558100483517081e-07
	float64 c8 = 9.27169033848955973e-08
	float64 c9 = -1.52876217236510867e-08
	float64 c10 = 2.49141637508325836e-09
	float64 c11 = -4.01439816207208959e-10
	float64 c12 = 6.38952677852622868e-11
	float64 c13 = -1.00749758505726210e-11
	float64 c14 = 1.66027715793600739e-12
	float64 c15 = -2.56202253868298013e-13
	float64 r = c1 + u * (c2 + u * (c3 + u * (c4 + u * (c5 + u * (c6 + u * (c7 + u * (c8 + u * (c9 + u * (c10 + u * (c11 + u * (c12 + u * (c13 + u * (c14 + u * c15)))))))))))))
	return fm64_dd_add(fm64_dd(c0), fm64_two_prod(u, r))


# x * erfc(x) * e^(x^2) for x in [6, 28] as a polynomial in w = 1/x^2
# (degree 11, fit error ~2^-62 relative).
f64dd fm64_erfc_tail(float64 w):
	float64 c0 = 5.64189583547756279e-01
	float64 c1 = -2.82094791773859099e-01
	float64 c2 = 4.23142187645398959e-01
	float64 c3 = -1.05785546247877749e+00
	float64 c4 = 3.70249239396965280e+00
	float64 c5 = -1.66609266421606250e+01
	float64 c6 = 9.16026102456523432e+01
	float64 c7 = -5.92923556188237399e+02
	float64 c8 = 4.31593017418263844e+03
	float64 c9 = -3.20544326886884737e+04
	float64 c10 = 1.99252001340207382e+05
	float64 c11 = -7.03071872058032663e+05
	float64 r = c1 + w * (c2 + w * (c3 + w * (c4 + w * (c5 + w * (c6 + w * (c7 + w * (c8 + w * (c9 + w * (c10 + w * c11)))))))))
	return fm64_dd_add(fm64_dd(c0), fm64_two_prod(w, r))


# lgamma(x) / ((x - 1)(x - 2)) for x in [0.75, 1.25] as a polynomial in
# u = x - 1 (degree 19, fit error ~2^-62 relative). g2 covers
# [1.25, 1.75] around 1.5 and g3 [1.75, 2.5] around 2.125. Factoring the
# zeros out keeps lgamma's relative accuracy right up to x = 1 and 2.
f64dd fm64_lgamma_g1(float64 u):
	float64 c0 = 5.77215664901532866e-01
	float64 c1 = -2.45251368522580365e-01
	float64 c2 = 1.55434265863951232e-01
	float64 c3 = -1.15146542563833637e-01
	float64 c4 = 9.22390084647493752e-02
	float64 c5 = -7.73181685324805107e-02
	float64 c6 = 6.67317282548900576e-02
	float64 c7 = -5.87779413062692463e-02
	float64 c8 = 5.25563226538665260e-02
	float64 c9 = -4.75431310880403551e-02
	float64 c10 = 4.34109985865616180e-02
	float64 c11 = -3.99430657409833648e-02
	float64 c12 = 3.69854416866934807e-02
	float64 c13 = -3.44394466880270228e-02
	float64 c14 = 3.23165904635920806e-02
	float64 c15 = -3.03629374585932497e-02
	float64 c16 = 2.73393769018478137e-02
	float64 c17 = -2.58511391183658089e-02
	float64 c18 = 3.42489947698940908e-02
	float64 c19 = -3.26230837619844102e-02
	float64 r = c1 + u * (c2 + u * (c3 + u * (c4 + u * (c5 + u * (c6 + u * (c7 + u * (c8 + u * (c9 + u * (c10 + u * (c11 + u * (c12 + u * (c13 + u * (c14 + u * (c15 + u * (c16 + u * (c17 + u * (c18 + u * c19)))))))))))))))))
	return fm64_dd_add(fm64_dd(c0), fm64_two_prod(u, r))


f64dd fm64_lgamma_g2(float64 u):
	float64 c0 = 4.83128950540980873e-01
	float64 c1 = -1.45959895914306081e-01
	float64 c2 = 6.29114010745656094e-02
	float64 c3 = -3.13084875010114227e-02
	float64 c4 = 1.67970986309611513e-02
	float64 c5 = -9.42562244832710269e-03
	float64 c6 = 5.44645787338804855e-03
	float64 c7 = -3.21207409542658600e-03
	float64 c8 = 1.92291433351254003e-03
	float64 c9 = -1.16441333179615803e-03
	float64 c10 = 7.11583600018341552e-04
	float64 c11 = -4.38033902282171177e-04
	float64 c12 = 2.70128070025725249e-04
	float64 c13 = -1.68167926237287245e-04
	float64 c14 = 1.16718765132274463e-04
	float64 c15 = -7.33270118067836572e-05
	float64 r = c1 + u * (c2 + u * (c3 + u * (c4 + u * (c5 + u * (c6 + u * (c7 + u * (c8 + u * (c9 + u * (c10 + u * (c11 + u * (c12 + u * (c13 + u * (c14 + u * c15)))))))))))))
	return fm64_dd_add(fm64_dd(c0), fm64_two_prod(u, r))


f64dd fm64_lgamma_g3(float64 u):
	float64 c0 = 4.10736721993556431e-01
	float64 c1 = -9.26199246144818050e-02
	float64 c2 = 2.87514871004540332e-02
	float64 c3 = -1.01816895048961985e-02
	float64 c4 = 3.87069525402477166e-03
	float64 c5 = -1.53704509279015979e-03
	float64 c6 = 6.28350949688709142e-04
	float64 c7 = -2.62196667846717837e-04
	float64 c8 = 1.11077287498260259e-04
	float64 c9 = -4.76043909572537063e-05
	float64 c10 = 2.05885483279941075e-05
	float64 c11 = -8.97158879758525034e-06
	float64 c12 = 3.93258137154447248e-06
	float64 c13 = -1.72134007424373758e-06
	float64 c14 = 7.61623168850300500e-07
	float64 c15 = -3.84032306434531004e-07
	float64 c16 = 1.71251106706861399e-07
	float64 r = c1 + u * (c2 + u * (c3 + u * (c4 + u * (c5 + u * (c6 + u * (c7 + u * (c8 + u * (c9 + u * (c10 + u * (c11 + u * (c12 + u * (c13 + u * (c14 + u * (c15 + u * c16))))))))))))))
	return fm64_dd_add(fm64_dd(c0), fm64_two_prod(u, r))


# hypot(x, y) = sqrt(x^2 + y^2) without intermediate overflow or
# underflow (Python math.hypot for two arguments). The squares are summed
# as a dd and the root takes a Newton correction, so the result is
# within 0.5 ulp plus a hair (measured <= 0.50 ulp vs mpmath, 40k
# pairs across the whole exponent range). Edge
# contract (IEEE / Python): an infinite argument gives +inf even when the
# other is NaN; otherwise NaN in -> NaN out.
float64 fhypot64(float64 x, float64 y):
	if (f64is_inf(x) || f64is_inf(y)): return float64_from_bits(0x7ff << 52)
	if (f64is_nan(x)):
		return x
	if (f64is_nan(y)):
		return y
	float64 a = fabs64(x)
	float64 b = fabs64(y)
	if (a < b):
		float64 tmp = a
		a = b
		b = tmp
	if (b == 0.0): return a
	float64 two_m60 = 8.6736173798840355e-19    # 2^-60
	if (b < a * two_m60): return a
	int sc = 0
	float64 two_500 = 3.2733906078961419e+150    # 2^500
	float64 two_m500 = 3.0549363634996047e-151    # 2^-500
	if (a > two_500):
		a = fldexp64(a, -600)
		b = fldexp64(b, -600)
		sc = 600
	else if (b < two_m500):
		a = fldexp64(a, 600)
		b = fldexp64(b, 600)
		sc = -600
	f64dd s = fm64_dd_add(fm64_two_prod(a, a), fm64_two_prod(b, b))
	f64dd r = fm64_dd_sqrt(s)
	return fldexp64(r.hi + r.lo, sc)


# Python math.isclose(a, b, rel_tol=rel_tol, abs_tol=abs_tol): 1 when
# |a - b| <= max(rel_tol * max(|a|, |b|), abs_tol). Equal values
# (including equal infinities) are always close; NaN is close to
# nothing; an infinity is close only to itself. Python raises on a
# negative tolerance; this returns 0 for a negative or NaN tolerance.
int fisclose_tol64(float64 a, float64 b, float64 rel_tol, float64 abs_tol):
	# NaN checks come first: nan == nan is true in W (docs/projects/float.md)
	if (f64is_nan(a) || f64is_nan(b)): return 0
	if (f64is_nan(rel_tol) || f64is_nan(abs_tol)): return 0
	if (rel_tol < 0.0 || abs_tol < 0.0): return 0
	if (a == b): return 1
	if (f64is_inf(a) || f64is_inf(b)): return 0
	float64 diff = fabs64(b - a)
	if (diff <= fabs64(rel_tol * b)): return 1
	if (diff <= fabs64(rel_tol * a)): return 1
	if (diff <= abs_tol): return 1
	return 0


# Python math.isclose(a, b) with its defaults rel_tol=1e-09, abs_tol=0.0.
int fisclose64(float64 a, float64 b):
	return fisclose_tol64(a, b, 1e-09, 0.0)


# Core of the exp family: for finite x with |x| <= ~1100, returns
# e = expm1(r) as a dd and writes k such that e^x = 2^k * (1 + e), with
# |r| <= ~0.347. Reduction is Cody-Waite by ln2 (ln2hi has 32
# significant bits, so k * ln2hi is exact and x - k * ln2hi is exact by
# Sterbenz), and the reduction's rounding residual c is folded back in
# to first order. The pair is good to ~2^-62 relative.
f64dd fm64_exp_reduced(float64 x, int* k_out):
	float64 ln2hi = 6.93147180369123816e-01
	float64 ln2lo = 1.90821492927058770e-10
	float64 invln2 = 1.44269504088896339e+00
	float64 r = x
	float64 c = 0.0
	int k = 0
	if (fabs64(x) > 0.34657359027997264):
		float64 fk = ffloor64(x * invln2 + 0.5)
		k = fk
		float64 hi = x - fk * ln2hi
		float64 lo = fk * ln2lo
		r = hi - lo
		c = (hi - r) - lo
	# expm1(r) = r + r^2/2 + r^3 q(r), summed as a pair
	f64dd r2 = fm64_two_prod(r, r)
	float64 tail = r * r2.hi * fm64_expm1_q(r)
	f64dd inner = fm64_fast_two_sum(r2.hi * 0.5, r2.lo * 0.5 + tail)
	f64dd e = fm64_two_sum(r, inner.hi)
	float64 lo2 = e.lo + inner.lo
	# expm1(r + c) ~ e + c * (1 + e)
	lo2 = lo2 + (c + c * e.hi)
	*k_out = k
	return fm64_fast_two_sum(e.hi, lo2)


# e^(x + dx) split as m * 2^n with m in ~[0.7, 1.42], for finite x with
# |x| <= ~1100 and a tiny correction dx (|dx| <= ~2^-40 |x|). Lets a
# caller multiply by another factor before the final scaling, so
# results that over- or underflow on their own (sinh near 710, erfc's
# e^(-x^2) tail, complex exp) round only once. m is within ~0.5 ulp.
# Shared with libs/standard/numeric/complex.w.
f64dd fm64_exp_split_dd(float64 x, float64 dx, int* n_out):
	int k = 0
	f64dd e = fm64_exp_reduced(x, &k)
	f64dd u = fm64_dd_add(fm64_dd(1.0), e)
	*n_out = k
	return fm64_fast_two_sum(u.hi, u.lo + u.hi * dx)


float64 fm64_exp_split(float64 x, float64 dx, int* n_out):
	f64dd u = fm64_exp_split_dd(x, dx, n_out)
	return u.hi + u.lo


# e^x - 1 as a dd for finite |x| <= ~700 (callers filter specials).
f64dd fm64_expm1_dd(float64 x):
	int k = 0
	f64dd e = fm64_exp_reduced(x, &k)
	if (k == 0): return e
	f64dd u = fm64_dd_add(fm64_dd(1.0), e)
	f64dd p = f64dd(fldexp64(u.hi, k), fldexp64(u.lo, k))
	return fm64_dd_add(p, fm64_dd(-1.0))


# e^x - 1 without cancellation for small x (Python math.expm1). Measured
# <= 0.54 ulp vs mpmath over [-40, 709.78] (80k points, dense near 0). Edge
# contract: NaN -> NaN, overflow (x > 709.78, also +inf) -> +inf,
# x < -38 (also -inf) -> -1, +-0 -> +-0.
float64 fexpm164(float64 x):
	if (f64is_nan(x)):
		return x
	if (x > 710.0): return float64_from_bits(0x7ff << 52)
	if (x < -38.0): return -1.0
	float64 two_m54 = 5.5511151231257827e-17
	if (fabs64(x) < two_m54): return x
	int k = 0
	f64dd e = fm64_exp_reduced(x, &k)
	if (k == 0): return e.hi + e.lo
	f64dd u = fm64_dd_add(fm64_dd(1.0), e)
	if (k > 1000): return fldexp64(u.hi + u.lo, k)
	f64dd p = f64dd(fldexp64(u.hi, k), fldexp64(u.lo, k))
	f64dd s = fm64_dd_add(p, fm64_dd(-1.0))
	return s.hi + s.lo


# log1p(x) as a dd for finite x > -1. Tiny |x| (< 2^-20) uses the
# series through x^4; otherwise u = 1 + x is formed with its exact
# rounding error c (fdlibm's trick), log(u) comes from the hi + lo log2
# core (~2^-64 relative), and c/u corrects for the rounding of u.
f64dd fm64_log1p_dd(float64 x):
	float64 two_m20 = 9.5367431640625e-07
	if (fabs64(x) < two_m20):
		float64 third = 3.33333333333333315e-01
		float64 corr = x * x * (-0.5 + x * (third - x * 0.25))
		return fm64_fast_two_sum(x, corr)
	float64 u = 1.0 + x
	float64 c = 0.0
	if (x >= 1.0): c = 1.0 - (u - x)
	else: c = x - (u - 1.0)
	float64 t1 = 0.0
	float64 t2 = 0.0
	flog2_pair64(u, &t1, &t2)
	float64 ln2h = 6.9314670562744141e-01    # ln(2) top 21 bits
	float64 ln2l = 4.7493250390316726e-07    # ln(2) - ln2h
	float64 ln2 = 6.9314718055994529e-01
	float64 p = t1 * ln2h    # exact: 21 x 21 bits
	float64 pl = (t2 * ln2 + t1 * ln2l) + c / u
	return fm64_fast_two_sum(p, pl)


# log1p(a.hi + a.lo) = log1p(a.hi) + a.lo / (1 + a.hi), to first order.
f64dd fm64_log1p_dd2(f64dd a):
	f64dd l = fm64_log1p_dd(a.hi)
	return fm64_dd_add(l, fm64_dd(a.lo / (1.0 + a.hi)))


# ln(v) as a dd for finite v > 0.
f64dd fm64_log_dd(float64 v):
	float64 t1 = 0.0
	float64 t2 = 0.0
	flog2_pair64(v, &t1, &t2)
	f64dd ln2 = f64dd(6.93147180559945286e-01, 2.31904681384629956e-17)
	return fm64_dd_mul(fm64_fast_two_sum(t1, t2), ln2)


# log(1 + x) accurate for small x (Python math.log1p). Measured <= 0.50
# ulp vs mpmath over (-1, 1e300] (100k points, dense near 0 and -1). Edge
# contract: NaN -> NaN, x < -1 (also -inf) -> NaN, -1 -> -inf,
# +inf -> +inf, +-0 -> +-0.
float64 flog1p64(float64 x):
	if (f64is_nan(x)):
		return x
	if (x == -1.0): return float64_from_bits(0xfff << 52)
	if (x < -1.0): return float64_from_bits(0x7ff8 << 48)
	if (f64is_inf(x)):
		return x
	float64 two_m54 = 5.5511151231257827e-17
	if (fabs64(x) < two_m54): return x
	f64dd r = fm64_log1p_dd(x)
	return r.hi + r.lo


# sinh(x) (Python math.sinh). |x| < 22 uses t = expm1(|x|) as a dd and
# sinh = (t + t/(1 + t)) / 2, cancellation-free near 0; beyond, e^|x|/2
# scaled so 710 < |x| < 710.48 still returns the finite result.
# Measured <= 0.52 ulp vs mpmath over [-711, 711] (60k points). Edge
# contract: NaN -> NaN, +-inf -> +-inf, +-0 -> +-0, overflow -> +-inf.
float64 fsinh64(float64 x):
	if (f64is_nan(x)):
		return x
	float64 ax = fabs64(x)
	float64 two_m27 = 7.4505805969238281e-09
	if (ax < two_m27): return x
	float64 res = 0.0
	if (ax < 22.0):
		f64dd t = fm64_expm1_dd(ax)
		f64dd q = fm64_dd_div(t, fm64_dd_add(fm64_dd(1.0), t))
		f64dd s = fm64_dd_add(t, q)
		res = 0.5 * (s.hi + s.lo)
	else if (ax > 711.0):
		res = float64_from_bits(0x7ff << 52)
	else:
		int n = 0
		float64 m = fm64_exp_split(ax, 0.0, &n)
		res = fldexp64(m, n - 1)
	return fcopysign64(res, x)


# cosh(x) (Python math.cosh): 1 + t^2 / (2 (1 + t)) with t = expm1(|x|)
# as a dd for |x| < 22, e^|x|/2 beyond. Measured <= 0.51 ulp vs mpmath
# over [-711, 711] (60k points). Edge contract: NaN -> NaN, +-inf -> +inf,
# overflow -> +inf, cosh(+-0) = 1.
float64 fcosh64(float64 x):
	if (f64is_nan(x)):
		return x
	float64 ax = fabs64(x)
	float64 two_m27 = 7.4505805969238281e-09
	if (ax < two_m27): return 1.0
	if (ax < 22.0):
		f64dd t = fm64_expm1_dd(ax)
		f64dd q = fm64_dd_div(fm64_dd_mul(t, t), fm64_dd_add(fm64_dd(1.0), t))
		f64dd c = fm64_dd_add(fm64_dd(1.0), f64dd(q.hi * 0.5, q.lo * 0.5))
		return c.hi + c.lo
	if (ax > 711.0): return float64_from_bits(0x7ff << 52)
	int n = 0
	float64 m = fm64_exp_split(ax, 0.0, &n)
	return fldexp64(m, n - 1)


# tanh(x) (Python math.tanh) = t / (t + 2) with t = expm1(2|x|) as a
# dd; |x| >= 22 rounds to +-1. Measured <= 0.51 ulp vs mpmath over
# [-25, 25] (50k points). Edge contract: NaN -> NaN, +-inf -> +-1, +-0 -> +-0.
float64 ftanh64(float64 x):
	if (f64is_nan(x)):
		return x
	float64 ax = fabs64(x)
	float64 two_m27 = 7.4505805969238281e-09
	if (ax < two_m27): return x
	if (ax >= 22.0): return fcopysign64(1.0, x)
	f64dd t = fm64_expm1_dd(2.0 * ax)
	f64dd r = fm64_dd_div(t, fm64_dd_add(t, fm64_dd(2.0)))
	return fcopysign64(r.hi + r.lo, x)


# ln(2 * ax) as a float64, for ax > 2^28 where asinh/acosh reduce to it.
float64 fm64_log_twice(float64 ax):
	float64 t1 = 0.0
	float64 t2 = 0.0
	flog2_pair64(ax, &t1, &t2)
	f64dd s = fm64_dd_add(fm64_two_sum(t1, 1.0), fm64_dd(t2))
	f64dd ln2 = f64dd(6.93147180559945286e-01, 2.31904681384629956e-17)
	f64dd r = fm64_dd_mul(s, ln2)
	return r.hi + r.lo


# asinh(x) (Python math.asinh) = log1p(|x| + x^2 / (1 + sqrt(1 + x^2)))
# with every step in dd; ln(2|x|) for |x| > 2^28. Measured <= 0.50 ulp
# vs mpmath over [-1e300, 1e300] (60k points, dense near 0). Edge contract:
# NaN -> NaN, +-inf -> +-inf, +-0 -> +-0.
float64 fasinh64(float64 x):
	if (f64is_nan(x) || f64is_inf(x)):
		return x
	float64 ax = fabs64(x)
	float64 two_m27 = 7.4505805969238281e-09
	if (ax < two_m27): return x
	if (ax > 268435456.0): return fcopysign64(fm64_log_twice(ax), x)
	f64dd x2 = fm64_two_prod(ax, ax)
	f64dd root = fm64_dd_sqrt(fm64_dd_add(fm64_dd(1.0), x2))
	f64dd arg = fm64_dd_add(fm64_dd(ax), fm64_dd_div(x2, fm64_dd_add(fm64_dd(1.0), root)))
	f64dd r = fm64_log1p_dd2(arg)
	return fcopysign64(r.hi + r.lo, x)


# acosh(x) (Python math.acosh) = log1p(t + sqrt(t (t + 2))), t = x - 1,
# in dd; ln(2x) for x > 2^28. Measured <= 0.50 ulp vs mpmath over
# [1, 1e300] (40k points, dense near 1). Edge contract: NaN -> NaN, x < 1 (also
# -inf) -> NaN, acosh(1) = +0, +inf -> +inf.
float64 facosh64(float64 x):
	if (f64is_nan(x)):
		return x
	if (x < 1.0): return float64_from_bits(0x7ff8 << 48)
	if (x == 1.0): return 0.0
	if (f64is_inf(x)):
		return x
	if (x > 268435456.0): return fm64_log_twice(x)
	f64dd t = fm64_two_sum(x, -1.0)
	f64dd w = fm64_dd_mul(t, fm64_dd_add(t, fm64_dd(2.0)))
	f64dd arg = fm64_dd_add(t, fm64_dd_sqrt(w))
	f64dd r = fm64_log1p_dd2(arg)
	return r.hi + r.lo


# atanh(x) (Python math.atanh) = log1p(2|x| / (1 - |x|)) / 2 in dd.
# Measured <= 0.50 ulp vs mpmath over (-1, 1) (100k points, dense near
# 0 and +-1).
# Edge contract: NaN -> NaN, |x| > 1 -> NaN, +-1 -> +-inf, +-0 -> +-0.
float64 fatanh64(float64 x):
	if (f64is_nan(x)):
		return x
	float64 ax = fabs64(x)
	if (ax > 1.0): return float64_from_bits(0x7ff8 << 48)
	if (ax == 1.0): return fcopysign64(float64_from_bits(0x7ff << 52), x)
	float64 two_m27 = 7.4505805969238281e-09
	if (ax < two_m27): return x
	f64dd den = fm64_two_sum(1.0, -ax)
	f64dd arg = fm64_dd_div(fm64_dd(2.0 * ax), den)
	f64dd r = fm64_log1p_dd2(arg)
	return fcopysign64(0.5 * (r.hi + r.lo), x)


# erfc(ax) for ax in [1.25, 28): e^(-ax^2) * H(ax) with H one of the
# fitted erfc(x) e^(x^2) pieces, and e^(-ax^2) formed from ax^2 as an
# exact pair so the argument costs no accuracy even near ax^2 ~ 745.
float64 fm64_erfc_big(float64 ax):
	f64dd hd = fm64_dd(0.0)
	if (ax < 2.0): hd = fm64_erfc_h1(ax - 1.625)
	else if (ax < 2.75): hd = fm64_erfc_h2(ax - 2.375)
	else if (ax < 3.5): hd = fm64_erfc_h3(ax - 3.125)
	else if (ax < 4.5): hd = fm64_erfc_h4(ax - 4.0)
	else if (ax < 6.0): hd = fm64_erfc_h5(ax - 5.25)
	else: hd = fm64_dd_div(fm64_erfc_tail(1.0 / (ax * ax)), fm64_dd(ax))
	f64dd sq = fm64_two_prod(ax, ax)
	int n = 0
	f64dd m = fm64_exp_split_dd(-sq.hi, -sq.lo, &n)
	f64dd v = fm64_dd_mul(m, hd)
	return fldexp64(v.hi + v.lo, n)


# erf(x) (Python math.erf). fdlibm's interval split (|x| < 0.84375 odd
# polynomial, [0.84375, 1.25) expansion around erf(1), 1 - erfc beyond,
# +-1 from 6 on) with re-fitted kernels. Measured <= 0.7 ulp vs mpmath
# over [-7, 7] (60k points). Edge contract: NaN -> NaN, +-inf -> +-1, +-0 -> +-0.
float64 ferf64(float64 x):
	if (f64is_nan(x)):
		return x
	float64 ax = fabs64(x)
	if (ax < 0.84375):
		if (x == 0.0): return x    # keeps -0.0's sign through the pair sum
		# x * x may underflow to 0 for tiny x; the kernel then returns
		# its constant 2/sqrt(pi) - 1, which is still the right slope
		f64dd e = fm64_dd_add(fm64_dd(x), fm64_dd_mul(fm64_dd(x), fm64_erf_small(x * x)))
		return e.hi + e.lo
	if (ax < 1.25):
		float64 erx = 8.42700792949714894e-01    # erf(1) rounded
		float64 c0 = -2.48013129463580059e-17    # erf(1) - erx
		float64 s = ax - 1.0
		f64dd p = fm64_two_prod(s, fm64_erf_mid(s))
		return fcopysign64(erx + (p.hi + (p.lo + c0)), x)
	if (ax >= 6.0): return fcopysign64(1.0, x)
	return fcopysign64(1.0 - fm64_erfc_big(ax), x)


# erfc(x) = 1 - erf(x) without cancellation for large x (Python
# math.erfc), sharing ferf64's kernels; the small and middle ranges
# finish in dd. Measured <= 1.2 ulp vs mpmath over [-7, 27.3] (60k
# points, results down into the subnormal range). Edge contract: NaN -> NaN, +inf -> +0,
# -inf -> 2, x >= 28 -> +0 (underflow).
float64 ferfc64(float64 x):
	if (f64is_nan(x)):
		return x
	float64 ax = fabs64(x)
	if (ax < 0.84375):
		float64 two_m56 = 1.3877787807814457e-17
		if (ax < two_m56): return 1.0 - x
		f64dd e = fm64_dd_add(fm64_dd(x), fm64_dd_mul(fm64_dd(x), fm64_erf_small(x * x)))
		f64dd r = fm64_dd_add(fm64_dd(1.0), fm64_dd_neg(e))
		return r.hi + r.lo
	if (ax < 1.25):
		float64 erx = 8.42700792949714894e-01
		float64 c0 = -2.48013129463580059e-17
		float64 s = ax - 1.0
		f64dd p = fm64_dd_add(fm64_two_prod(s, fm64_erf_mid(s)), fm64_dd(c0))
		f64dd r = fm64_dd(0.0)
		if (x > 0.0): r = fm64_dd_add(fm64_dd(1.0 - erx), fm64_dd_neg(p))
		else: r = fm64_dd_add(fm64_two_sum(1.0, erx), p)
		return r.hi + r.lo
	if (x < 0.0):
		if (ax >= 6.0): return 2.0
		return 2.0 - fm64_erfc_big(ax)
	if (ax >= 28.0): return 0.0
	return fm64_erfc_big(ax)


# sin(pi * x) for finite x >= 0 below 2^52. The reduction x mod 2 and the
# quadrant split are exact, so accuracy does not degrade with x; pi * u
# is carried as a pair and its low word applied to first order.
float64 fm64_sinpi(float64 x):
	float64 h = x * 0.5
	float64 r = 2.0 * (h - ffloor64(h))
	float64 fq = ffloor64(r * 2.0 + 0.5)
	int q = fq
	float64 u = r - fq * 0.5
	f64dd v = fm64_dd_mul(f64dd(3.14159265358979312e+00, 1.22464679914735321e-16), fm64_dd(u))
	float64 sv = fsin_poly64(v.hi)
	float64 cv = fcos_poly64(v.hi)
	if (q == 1): return cv - v.lo * sv
	if (q == 2): return -(sv + v.lo * cv)
	if (q == 3): return -(cv - v.lo * sv)
	return sv + v.lo * cv


# Lanczos sum S(x) for x > 0 as a dd: the g = 6.024680040776729583740234375,
# N = 13 rational approximation CPython's math.gamma uses (num/den with
# den = x (x + 1) ... (x + 11)), here with numerator coefficients as
# float64 pairs and dd Horner so S keeps ~2^-100 instead of the ~6 ulp
# plain float64 evaluation loses. Approximation error itself is
# <= 3e-17 relative (checked with mpmath).
f64dd fm64_lanczos_sum(float64 x):
	float64[13] nh
	float64[13] nl
	float64[13] dn
	nh[0] = 2.35313768804107590e+10
	nl[0] = 7.16404038924451619e-07
	nh[1] = 4.29198036426491013e+10
	nl[1] = -2.48836631970299804e-06
	nh[2] = 3.57119592373556671e+10
	nl[2] = 9.35182372951547140e-07
	nh[3] = 1.79210344260372086e+10
	nl[3] = 1.14279084950445898e-06
	nh[4] = 6.03954258635202789e+09
	nl[4] = 1.11997885394307298e-07
	nh[5] = 1.43972040731172156e+09
	nl[5] = 1.10323989674357408e-07
	nh[6] = 2.48874557862054169e+08
	nl[6] = -1.26665486467898951e-08
	nh[7] = 3.14264155854001939e+07
	nl[7] = 4.50941990417380726e-10
	nh[8] = 2.87637062893537246e+06
	nl[8] = -1.56828169615627445e-11
	nh[9] = 1.86056265395223483e+05
	nl[9] = 1.18298654404988219e-11
	nh[10] = 8.07167200236581630e+03
	nl[10] = -8.66044150292844465e-14
	nh[11] = 2.10824277751579359e+02
	nl[11] = -1.32466953032111929e-14
	nh[12] = 2.50662827463100024e+00
	nl[12] = 2.85525529377937354e-17
	dn[0] = 0.0
	dn[1] = 39916800.0
	dn[2] = 120543840.0
	dn[3] = 150917976.0
	dn[4] = 105258076.0
	dn[5] = 45995730.0
	dn[6] = 13339535.0
	dn[7] = 2637558.0
	dn[8] = 357423.0
	dn[9] = 32670.0
	dn[10] = 1925.0
	dn[11] = 66.0
	dn[12] = 1.0
	f64dd num = fm64_dd(0.0)
	f64dd den = fm64_dd(0.0)
	f64dd xd = fm64_dd(x)
	if (x < 8.0):
		int i = 12
		while (i >= 0):
			num = fm64_dd_add(fm64_dd_mul(num, xd), f64dd(nh[i], nl[i]))
			den = fm64_dd_add(fm64_dd_mul(den, xd), fm64_dd(dn[i]))
			i = i - 1
	else:
		# Horner in 1/x keeps large x from overflowing x^12
		int j = 0
		while (j <= 12):
			num = fm64_dd_add(fm64_dd_div(num, xd), f64dd(nh[j], nl[j]))
			den = fm64_dd_add(fm64_dd_div(den, xd), fm64_dd(dn[j]))
			j = j + 1
	return fm64_dd_div(num, den)


# log2 of the Lanczos power term as a dd: E = (x - 0.5) log2(y) - y log2(e)
# with y = x + g - 0.5 carried exactly as a pair, so that
# Gamma(x) ~ S(x) * 2^E. Good to ~2^-64 relative (the log2 core's
# precision), i.e. <= 2^-53.7 absolute at x ~ 171.
f64dd fm64_lanczos_exponent(float64 x):
	float64 gmhalf = 5.52468004077672958e+00    # g - 0.5, exact
	f64dd y = fm64_two_sum(x, gmhalf)
	float64 t1 = 0.0
	float64 t2 = 0.0
	flog2_pair64(y.hi, &t1, &t2)
	f64dd log2e = f64dd(1.44269504088896339e+00, 2.03552737409310331e-17)
	f64dd lg = fm64_fast_two_sum(t1, t2 + y.lo * log2e.hi / y.hi)
	f64dd a = fm64_two_sum(x, -0.5)
	f64dd pa = fm64_dd_mul(a, lg)
	f64dd pb = fm64_dd_mul(y, log2e)
	return fm64_dd_add(pa, fm64_dd_neg(pb))


# Gamma(x) (Python math.gamma). Positive x: the Lanczos sum in dd times
# 2^E, with E's fractional part through fexp2_poly64 and the integer part
# applied by fldexp64 (so overflow near 171.62 rounds once). Negative
# non-integer x: reflection Gamma(x) = pi / (x sinpi(-x) Gamma(-x)).
# Integer x in [1, 23] is exact. Measured vs mpmath: <= 0.8 ulp for
# x > 0, <= 2 ulp for x < 0 (60k + 40k points, all magnitudes down to
# underflow).
# Edge contract (C99 tgamma; Python raises instead): NaN -> NaN,
# +inf -> +inf, -inf -> NaN, +-0 -> +-inf, negative integer -> NaN,
# x > 171.62 -> +inf, x < -184 -> +-0 with Gamma's sign.
float64 fgamma64(float64 x):
	if (f64is_nan(x)):
		return x
	if (f64is_inf(x)):
		if (x > 0.0): return x
		return float64_from_bits(0x7ff8 << 48)
	float64 ax = fabs64(x)
	float64 two_m54 = 5.5511151231257827e-17
	if (ax < two_m54): return 1.0 / x
	if (x >= 172.0): return float64_from_bits(0x7ff << 52)
	if (x <= -4503599627370496.0): return float64_from_bits(0x7ff8 << 48)    # every such x is an integer
	float64 fl = ffloor64(x)
	if (fl == x):
		if (x < 0.0): return float64_from_bits(0x7ff8 << 48)
		if (x <= 23.0):
			# (x - 1)! is exact in float64 through 22!
			float64 f = 1.0
			float64 i = 2.0
			while (i < x):
				f = f * i
				i = i + 1.0
			return f
	if (x <= -184.0):
		# |Gamma(x)| < 2^-1100: underflows to a zero carrying Gamma's
		# sign, positive when floor(x) is even
		float64 half = fl * 0.5
		if (ffloor64(half) == half): return 0.0
		return float64_from_bits(1 << 63)
	f64dd s = fm64_lanczos_sum(ax)
	f64dd e = fm64_lanczos_exponent(ax)
	# 2^E = 2^n * e^(t ln 2), t = E - n in [-0.5, 0.5], with the
	# fractional power through the dd exp core
	float64 fn = ffloor64(e.hi + 0.5)
	f64dd ln2 = f64dd(6.93147180559945286e-01, 2.31904681384629956e-17)
	f64dd t = fm64_dd_mul(fm64_fast_two_sum(e.hi - fn, e.lo), ln2)
	int k = 0
	f64dd p = fm64_exp_split_dd(t.hi, t.lo, &k)
	int n = fn
	n = n + k
	if (x > 0.0):
		f64dd v = fm64_dd_mul(s, p)
		return fldexp64(v.hi + v.lo, n)
	f64dd d = fm64_dd_mul(fm64_dd_mul(fm64_two_prod(x, fm64_sinpi(ax)), s), p)
	f64dd q = fm64_dd_div(f64dd(3.14159265358979312e+00, 1.22464679914735321e-16), d)
	return fldexp64(q.hi + q.lo, -n)


# log2(v) for a dd v with v.hi positive and finite.
f64dd fm64_log2_dd(f64dd v):
	float64 t1 = 0.0
	float64 t2 = 0.0
	flog2_pair64(v.hi, &t1, &t2)
	float64 log2e = 1.44269504088896339e+00
	return fm64_fast_two_sum(t1, t2 + v.lo * log2e / v.hi)


# ln Gamma(x) for finite x > 0 as a dd. Near the zeros at 1 and 2
# ([0.75, 2.5)) it is (x - 1)(x - 2) g(x) with g a fitted piece, so the
# relative accuracy holds right up to them; elsewhere it is
# (E + log2 S(x)) ln 2 from the Lanczos pieces, whose dd evaluation keeps
# the cancellation between E and log2 S harmless; x >= 2^52 uses
# x (ln x - 1), the rest of Stirling's series being below an ulp there.
f64dd fm64_lgamma_pos(float64 x):
	f64dd ln2 = f64dd(6.93147180559945286e-01, 2.31904681384629956e-17)
	if (x >= 4503599627370496.0):
		f64dd l = fm64_log_dd(x)
		f64dd lm1 = fm64_dd_add(l, fm64_dd(-1.0))
		float64 two_1000 = 1.0715086071862673e+301    # 2^1000
		if (x > two_1000): return fm64_dd(x * (lm1.hi + lm1.lo))    # may overflow to +inf
		return fm64_dd_mul(fm64_dd(x), lm1)
	if (x >= 0.75 && x < 2.5):
		f64dd g = fm64_dd(0.0)
		if (x < 1.25): g = fm64_lgamma_g1(x - 1.0)
		else if (x < 1.75): g = fm64_lgamma_g2(x - 1.5)
		else: g = fm64_lgamma_g3(x - 2.125)
		f64dd pr = fm64_dd_mul(fm64_two_sum(x, -1.0), fm64_two_sum(x, -2.0))
		return fm64_dd_mul(pr, g)
	f64dd s = fm64_lanczos_sum(x)
	f64dd e = fm64_lanczos_exponent(x)
	f64dd l2 = fm64_dd_add(e, fm64_log2_dd(s))
	return fm64_dd_mul(l2, ln2)


# ln |Gamma(x)| (Python math.lgamma). Measured vs mpmath: <= 1 ulp for
# x > 0 (100k points up to 1e300, dense around the zeros at 1 and 2);
# for x < 0 the reflection log(pi / |x sinpi(x)|) - lgamma(-x) is
# evaluated in dd and 99.6% of 40k points are within 2 ulp, but next to
# lgamma's negative-axis zeros (near -2.457, -2.747, -3.144, ...) the
# error is bounded in absolute rather than relative terms (~1e-17
# absolute; up to ~150 ulp of a result near 0.004), as in C libms
# without special expansions there.
# Edge contract: NaN -> NaN, +-inf -> +inf, +-0 and negative integers
# -> +inf (poles), overflow (x > ~2.5e305) -> +inf.
float64 flgamma64(float64 x):
	if (f64is_nan(x)):
		return x
	if (f64is_inf(x)): return float64_from_bits(0x7ff << 52)
	float64 ax = fabs64(x)
	float64 two_m54 = 5.5511151231257827e-17
	if (ax < two_m54):
		if (ax == 0.0): return float64_from_bits(0x7ff << 52)
		return -flog64(ax)
	if (x > 0.0):
		f64dd r = fm64_lgamma_pos(x)
		return r.hi + r.lo
	if (ax >= 4503599627370496.0): return float64_from_bits(0x7ff << 52)
	if (ffloor64(x) == x): return float64_from_bits(0x7ff << 52)
	# lgamma(x) = ln(pi) - ln|x sinpi(x)| - lgamma(-x)
	f64dd d = fm64_two_prod(ax, fabs64(fm64_sinpi(ax)))
	f64dd ld = fm64_dd_add(fm64_log_dd(d.hi), fm64_dd(d.lo / d.hi))
	f64dd lnpi = f64dd(1.14472988584940016e+00, 1.02659511627078264e-17)
	f64dd r = fm64_dd_add(fm64_dd_add(lnpi, fm64_dd_neg(ld)), fm64_dd_neg(fm64_lgamma_pos(ax)))
	return r.hi + r.lo
