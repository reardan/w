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


########################## transcendentals ###########################
#
# exp/log/pow/trig family in pure float32 W, per
# docs/projects/engineering_math_baseline.md. Every polynomial and split
# constant below was generated (Chebyshev fit / high-precision split in
# long double) and ulp-swept against glibc's float functions by a
# throwaway C harness; each function's header comment states the
# measured bound. Ulp distances are measured on the result's bit
# pattern via a sign-corrected integer ordering (see fmath_test.w).
#
# Two W-on-x64 rules shape the style of this section:
# - A bare decimal literal is float64 on the x64 target and promotes the
#   whole operation to double, silently changing the rounding versus the
#   32-bit target. Every constant that participates in float arithmetic
#   is therefore materialized as a float32 local first, and every
#   precision-critical constant is built with float_from_bits so both
#   targets compute bit-identical results.
# - nan == nan is true (docs/projects/float.md), so NaN tests go through
#   fis_nan.
#
# Cody-Waite / Dekker conventions: fsplit_hi truncates a float32 to its
# top 12 significant bits, so products of two truncated values (24-bit
# significands) are exact in float32. Pairs of such constants (hi + lo)
# carry ~2^-36 of a constant; the pair log2 core below carries
# log2(x) to ~2^-30 relative accuracy in two floats, which is what lets
# fpow stay within ~1 ulp without float64.


# Truncate to the top 12 significant bits (clear the low 12 mantissa
# bits): the building block for exact float32 products (12 bits x 12
# bits fits in a 24-bit significand).
float fsplit_hi(float f):
	return float_from_bits(float_bits(f) & cast(int, 0xfffff000))


# 2^t for t in [-0.5023, 0.5023], evaluated as 1 + t*h(t) with h a
# degree-6 Chebyshev fit of (2^t - 1)/t (fit error ~2^-31 relative), so
# fexp2_poly(0.0) is exactly 1.0. Shared kernel of fexp2/fexp/fpow.
float fexp2_poly(float t):
	float c0 = float_from_bits(0x3f317218)	# 6.9314718e-1
	float c1 = float_from_bits(0x3e75fdf0)	# 2.4022651e-1
	float c2 = float_from_bits(0x3d635847)	# 5.5504110e-2
	float c3 = float_from_bits(0x3c1d950c)	# 9.6180551e-3
	float c4 = float_from_bits(0x3aaec3ce)	# 1.3333501e-3
	float c5 = float_from_bits(0x3922216f)	# 1.5461979e-4
	float c6 = float_from_bits(0x378053a3)	# 1.5297735e-5
	float one = 1.0
	return one + t * (c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * c6))))))


# p * 2^n for p in [0.7, 1.5): exponent-field addition on the bits, with
# +inf on overflow and a two-step scale (down to 2^-63ish, then * 2^-64)
# that rounds correctly into the subnormal range or to zero. n == 128
# also goes through a final float multiply so results straddling the
# largest finite float round to +inf exactly like the hardware would.
float fexp2_scale(float p, int n):
	if (n > 128):
		return float_from_bits(0x7f800000)
	if (n == 128):
		float two = 2.0
		return float_from_bits(float_bits(p) + (127 << 23)) * two
	if (n < -125):
		if (n < -151):
			return 0.0
		float tiny = float_from_bits(0x1f800000)	# 2^-64
		return float_from_bits(float_bits(p) + ((n + 64) << 23)) * tiny
	return float_from_bits(float_bits(p) + (n << 23))


# 2^x. Measured <= 1 ulp vs glibc exp2f over [-152, 130] (4.5M-point
# sweep), including subnormal results. Edge contract: NaN -> NaN,
# x >= 128 -> +inf (also +inf -> +inf), x < -150ish -> 0 (also
# -inf -> 0). Reduction n = round(x), t = x - n is exact (Sterbenz).
float fexp2(float x):
	if (fis_nan(x)):
		return x
	float top = 130.0
	if (x > top):
		return float_from_bits(0x7f800000)
	float bottom = -152.0
	if (x < bottom):
		return 0.0
	float half = 0.5
	float fn = ffloor(x + half)
	int n = fn
	float t = x - fn
	return fexp2_scale(fexp2_poly(t), n)


# e^x. Measured <= 1 ulp vs glibc expf over [-105, 89] (4M-point sweep),
# including subnormal results. Edge contract: NaN -> NaN, overflow
# (x > 88.73, also +inf) -> +inf, x < -103.98ish (also -inf) -> 0.
# x*log2(e) is formed as an exact 12-bit-split product plus correction
# terms, so no accuracy is lost to the base change even for large x.
float fexp(float x):
	if (fis_nan(x)):
		return x
	float top = 89.0
	if (x > top):
		return float_from_bits(0x7f800000)
	float bottom = -105.0
	if (x < bottom):
		return 0.0
	float l2eh = float_from_bits(0x3fb8a000)	# log2(e) top 12 bits
	float l2el = float_from_bits(0x39a3b296)	# log2(e) - l2eh
	float l2e = float_from_bits(0x3fb8aa3b)	# log2(e) rounded
	float x1 = fsplit_hi(x)
	float pa = x1 * l2eh
	float pb = (x - x1) * l2e + x1 * l2el
	float half = 0.5
	float fn = ffloor(pa + pb + half)
	int n = fn
	float t = (pa - fn) + pb
	return fexp2_scale(fexp2_poly(t), n)


# log2(x) as a hi + lo pair for finite x > 0 (the caller filters
# specials). hi is truncated to 12 significant bits so y*hi is an exact
# product inside fpow; hi + lo carries log2(x) to ~2^-30 relative.
# fdlibm e_pow-style: normalize the mantissa to [sqrt2/2, sqrt2), take
# s = (m-1)/(m+1) with an exactly-computed low word, run the odd atanh
# series (whose correction terms are tiny enough for single precision),
# and track rounding residuals of every non-exact step in the lo word.
void flog2_pair(float x, float* hi_out, float* lo_out):
	int bits = float_bits(x)
	int e = 0
	if (bits < 0x00800000):
		# subnormal input: scale by 2^25 (exact) and rebias
		float scale25 = float_from_bits(0x4c000000)
		x = x * scale25
		bits = float_bits(x)
		e = -25
	e = e + (bits >> 23) - 127
	float m = float_from_bits((bits & 0x007fffff) | 0x3f800000)
	float sq2 = float_from_bits(0x3fb504f3)	# sqrt(2)
	float half = 0.5
	if (m >= sq2):
		m = m * half
		e = e + 1
	float one = 1.0
	float u = m - one	# exact (Sterbenz)
	float vv = m + one	# rounds; exact residual recovered below
	float th = fsplit_hi(vv)
	float tl = m - (th - one)	# (m + 1) - th, exactly
	float s = u / vv
	float sh = fsplit_hi(s)
	float sl = ((u - sh * th) - sh * tl) / vv
	# ln(m) = (2s/3)*(3 + s^2 + r), r = 3*sum(s^(2k)/(2k+1), k >= 2)
	float s2 = s * s
	float lc1 = float_from_bits(0x3f19999a)	# 3/5
	float lc2 = float_from_bits(0x3edb6db7)	# 3/7
	float lc3 = float_from_bits(0x3eaaaaab)	# 3/9
	float lc4 = float_from_bits(0x3e8ba2e9)	# 3/11
	float r = (s2 * s2) * (lc1 + s2 * (lc2 + s2 * (lc3 + s2 * lc4)))
	r = r + sl * (sh + s)	# s^2 correction: s^2 ~ sh^2 + sl*(sh + s)
	float s2h = sh * sh	# exact
	float three = 3.0
	float t_h = fsplit_hi(three + s2h + r)
	float t_l = r - ((t_h - three) - s2h)
	float u2 = sh * t_h	# exact
	float v2 = sl * t_h + t_l * s
	# log2(m) = cp * s * (3 + s^2 + r), cp = 2/(3 ln 2)
	float p_h = fsplit_hi(u2 + v2)
	float p_l = v2 - (p_h - u2)
	float cph = float_from_bits(0x3f763000)	# 2/(3 ln 2) top 12 bits
	float cpl = float_from_bits(0x3904ee1d)	# 2/(3 ln 2) - cph
	float cp = float_from_bits(0x3f76384f)	# 2/(3 ln 2) rounded
	float z_h = cph * p_h	# exact
	float z_l = cpl * p_h + p_l * cp
	float ef = e
	float t1 = fsplit_hi(ef + z_h + z_l)
	float t2 = z_l - ((t1 - ef) - z_h)
	*hi_out = t1
	*lo_out = t2


# Shared special-case ladder for flog/flog2/flog10: NaN -> NaN,
# +-0 -> -inf, x < 0 (including -inf) -> NaN, +inf -> +inf. Returns 1
# and writes the result when x is one of those.
int flog_special(float x, float* result_out):
	if (fis_nan(x)):
		*result_out = x
		return 1
	if (x == 0.0):
		*result_out = float_from_bits(cast(int, 0xff800000))
		return 1
	if (float_bits(x) < 0):
		*result_out = float_from_bits(0x7fc00000)
		return 1
	if (float_bits(x) == 0x7f800000):
		*result_out = x
		return 1
	return 0


# log base 2. Measured <= 1 ulp vs glibc log2f over all positive finite
# floats (4.3M-point sweep incl. dense [0.5, 2]); exact for powers of
# two. Edge contract: see flog_special.
float flog2(float x):
	float special = 0.0
	if (flog_special(x, &special)):
		return special
	float t1 = 0.0
	float t2 = 0.0
	flog2_pair(x, &t1, &t2)
	return t1 + t2


# Natural log: (t1 + t2) * ln2 with a 12-bit-split ln2 so the leading
# product is exact. Measured <= 1 ulp vs glibc logf over all positive
# finite floats. Edge contract: see flog_special.
float flog(float x):
	float special = 0.0
	if (flog_special(x, &special)):
		return special
	float t1 = 0.0
	float t2 = 0.0
	flog2_pair(x, &t1, &t2)
	float ln2h = float_from_bits(0x3f317000)	# ln(2) top 12 bits
	float ln2l = float_from_bits(0x3805fdf4)	# ln(2) - ln2h
	float ln2 = float_from_bits(0x3f317218)	# ln(2) rounded
	return t1 * ln2h + (t2 * ln2 + t1 * ln2l)


# log base 10: (t1 + t2) * log10(2), split like flog. Measured <= 2 ulp
# vs glibc log10f over all positive finite floats. Edge contract: see
# flog_special.
float flog10(float x):
	float special = 0.0
	if (flog_special(x, &special)):
		return special
	float t1 = 0.0
	float t2 = 0.0
	flog2_pair(x, &t1, &t2)
	float lgh = float_from_bits(0x3e9a2000)	# log10(2) top 12 bits
	float lgl = float_from_bits(0x369a84fc)	# log10(2) - lgh
	float lg = float_from_bits(0x3e9a209b)	# log10(2) rounded
	return t1 * lgh + (t2 * lg + t1 * lgl)


# x^y as 2^(y * log2|x|) over the pair log2 core, so the exponent
# product keeps ~30 significant bits and the result stays accurate even
# when y*log2(x) is large. Measured <= 1 ulp vs glibc powf on 6M+ sweep
# points: positive bases with normal results, bases near 1 with |y| up
# to 1e5+, and integer y in [-20, 20] with bases of either sign.
# IEEE edge contract (verified against glibc):
#   fpow(x, +-0) = 1 and fpow(1, y) = 1, even for NaN x/y; otherwise
#   NaN in -> NaN out; fpow(x, 1) = x; negative finite base: integer y
#   uses the parity sign, non-integer y -> NaN; +-0 and +-inf bases and
#   +-inf exponents follow IEEE 754 pow (signed zeros/infs included);
#   overflow -> +-inf, underflow -> +-0.
float fpow(float x, float y):
	float one = 1.0
	int xbits = float_bits(x)
	int ybits = float_bits(y)
	# bit tests, not float compares: nan == 0.0 is true in W
	# (docs/projects/float.md), which would turn pow(2, nan) into 1
	if ((ybits & 0x7fffffff) == 0):
		return one
	if (xbits == 0x3f800000):
		return one
	if (fis_nan(x)):
		return x
	if (fis_nan(y)):
		return y
	if (ybits == 0x3f800000):
		return x
	float ax = fabs(x)
	if ((ybits & 0x7fffffff) == 0x7f800000):
		# y = +-inf: 1 for |x| = 1, else pick 0 or inf by |x| vs 1
		if (ax == one):
			return one
		int bigger = 0
		if (ax > one):
			bigger = 1
		if (y > 0.0):
			if (bigger):
				return float_from_bits(0x7f800000)
			return 0.0
		if (bigger):
			return 0.0
		return float_from_bits(0x7f800000)
	# y integer parity: 0 = not an integer, 1 = odd, 2 = even
	int yint = 0
	float ay = fabs(y)
	float two24 = float_from_bits(0x4b800000)	# 2^24
	if (ay >= two24):
		yint = 2	# every float >= 2^24 in magnitude is an even integer
	else:
		float fy = ffloor(y)
		if (fy == y):
			float half = 0.5
			float fh = fy * half
			if (ffloor(fh) == fh):
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
				return float_from_bits(cast(int, 0x80000000))
			return 0.0
		if (neg):
			return float_from_bits(cast(int, 0xff800000))
		return float_from_bits(0x7f800000)
	if ((xbits & 0x7fffffff) == 0x7f800000):
		# +-inf base, mirroring the zero rules
		int neg = 0
		if (xbits < 0 && yint == 1):
			neg = 1
		if (y > 0.0):
			if (neg):
				return float_from_bits(cast(int, 0xff800000))
			return float_from_bits(0x7f800000)
		if (neg):
			return float_from_bits(cast(int, 0x80000000))
		return 0.0
	int sgn = 0
	if (xbits < 0):
		if (yint == 0):
			return float_from_bits(0x7fc00000)
		if (yint == 1):
			sgn = 1
	float t1 = 0.0
	float t2 = 0.0
	flog2_pair(ax, &t1, &t2)
	# y * (t1 + t2): y1*t1 is exact (both 12-bit), the rest is correction
	float y1 = fsplit_hi(y)
	float ph = y1 * t1
	float pl = (y - y1) * t1 + y * t2
	float z = ph + pl
	float ztop = 130.0
	if (z > ztop):
		if (sgn):
			return float_from_bits(cast(int, 0xff800000))
		return float_from_bits(0x7f800000)
	float zbottom = -152.0
	if (z < zbottom):
		if (sgn):
			return float_from_bits(cast(int, 0x80000000))
		return 0.0
	float half2 = 0.5
	float fn = ffloor(z + half2)
	int n = fn
	float t = (ph - fn) + pl
	float res = fexp2_scale(fexp2_poly(t), n)
	if (sgn):
		return -res
	return res


# sin(r) for r in [-pi/4 - eps, pi/4 + eps]: r + r^3 * S(r^2), S a
# degree-3 Chebyshev fit (odd terms through r^9). Trig kernel, ~1 ulp.
float fsin_poly(float r):
	float s1 = float_from_bits(cast(int, 0xbe2aaaab))	# -1.6666667e-1
	float s2 = float_from_bits(0x3c088887)	# 8.3333319e-3
	float s3 = float_from_bits(cast(int, 0xb95009d0))	# -1.9840081e-4
	float s4 = float_from_bits(0x3636ddc8)	# 2.7249207e-6
	float u = r * r
	return r + (u * r) * (s1 + u * (s2 + u * (s3 + u * s4)))


# cos(r) for r in [-pi/4 - eps, pi/4 + eps]: 1 - r^2/2 + r^4 * C(r^2)
# with the rounding residual of (1 - r^2/2) re-added so the leading
# terms lose nothing (musl __cosdf's trick). ~1 ulp.
float fcos_poly(float r):
	float k1 = float_from_bits(0x3d2aaaab)	# 4.1666668e-2
	float k2 = float_from_bits(cast(int, 0xbab60b60))	# -1.3888888e-3
	float k3 = float_from_bits(0x37d00ae0)	# 2.4800596e-5
	float k4 = float_from_bits(cast(int, 0xb4929154))	# -2.7300359e-7
	float u = r * r
	float half = 0.5
	float hu = u * half
	float one = 1.0
	float w = one - hu
	return w + (((one - w) - hu) + (u * u) * (k1 + u * (k2 + u * (k3 + u * k4))))


# Cody-Waite reduction by pi/2: writes r = x - n*pi/2 (|r| <= pi/4 +
# eps) and returns the quadrant n & 3. pi/2 is split into four parts,
# the top three truncated to 11 significant bits so fn * p_k is exact
# for |n| <= 2^13 (|x| <= ~12867); only fn * p4 (2.6e-12 of pi/2)
# rounds. Beyond |x| ~ 2^13.65 the products start rounding and accuracy
# degrades; far beyond (|x| > ~2^24) n overflows the reduction entirely
# and results are meaningless (but finite). No Payne-Hanek here by
# design - see docs/projects/engineering_math_baseline.md.
int ftrig_reduce(float x, float* r_out):
	float invpio2 = float_from_bits(0x3f22f983)	# 2/pi
	float p1 = float_from_bits(0x3fc90000)	# pi/2 top 11 bits
	float p2 = float_from_bits(0x39fda000)	# next 11 bits
	float p3 = float_from_bits(0x33a22000)	# next 11 bits
	float p4 = float_from_bits(0x2c34611a)	# remainder, 2.5633441e-12
	float half = 0.5
	float fn = ffloor(x * invpio2 + half)
	int n = fn
	float r = (((x - fn * p1) - fn * p2) - fn * p3) - fn * p4
	*r_out = r
	return n & 3


# sin(x). Measured vs glibc sinf: <= 1 ulp for |x| <= 100, <= 2 ulp for
# |x| <= 12800 (4M-point sweeps each); accuracy degrades beyond
# |x| ~ 2^13.6 (see ftrig_reduce). Edge contract: NaN -> NaN,
# +-inf -> NaN, +-0 -> +-0 (sign preserved; |x| < 2^-12 returns x,
# which is sin(x) correctly rounded there).
float fsin(float x):
	if (fis_nan(x)):
		return x
	int ab = float_bits(x) & 0x7fffffff
	if (ab == 0x7f800000):
		return float_from_bits(0x7fc00000)
	if (ab < 0x39800000):
		return x
	float r = 0.0
	int q = ftrig_reduce(x, &r)
	if (q == 0):
		return fsin_poly(r)
	if (q == 1):
		return fcos_poly(r)
	if (q == 2):
		return -fsin_poly(r)
	return -fcos_poly(r)


# cos(x). Measured vs glibc cosf: <= 1 ulp for |x| <= 100, <= 2 ulp for
# |x| <= 12800; degrades beyond |x| ~ 2^13.6 (see ftrig_reduce). Edge
# contract: NaN -> NaN, +-inf -> NaN, cos(+-0) = 1.
float fcos(float x):
	if (fis_nan(x)):
		return x
	int ab = float_bits(x) & 0x7fffffff
	if (ab == 0x7f800000):
		return float_from_bits(0x7fc00000)
	float r = 0.0
	int q = ftrig_reduce(x, &r)
	if (q == 0):
		return fcos_poly(r)
	if (q == 1):
		return -fsin_poly(r)
	if (q == 2):
		return -fcos_poly(r)
	return fsin_poly(r)


# tan(x) = sin/cos (or -cos/sin in odd quadrants) over the shared
# kernels. Measured vs glibc tanf: <= 3 ulp for |x| <= 100, <= 4 ulp
# for |x| <= 12800; degrades beyond |x| ~ 2^13.6 (see ftrig_reduce).
# Edge contract: NaN -> NaN, +-inf -> NaN, +-0 -> +-0 (|x| < 2^-12
# returns x, correctly rounded there). Near odd multiples of pi/2 the
# result is huge but finite, like glibc's.
float ftan(float x):
	if (fis_nan(x)):
		return x
	int ab = float_bits(x) & 0x7fffffff
	if (ab == 0x7f800000):
		return float_from_bits(0x7fc00000)
	if (ab < 0x39800000):
		return x
	float r = 0.0
	int q = ftrig_reduce(x, &r)
	if (q == 0 || q == 2):
		return fsin_poly(r) / fcos_poly(r)
	return -(fcos_poly(r) / fsin_poly(r))


# atan(x). Cephes-style range reduction: |x| > tan(3pi/8) folds to
# pi/2 - atan(1/x), |x| > tan(pi/8) to pi/4 + atan((x-1)/(x+1)), then a
# degree-4 odd Chebyshev polynomial on the rest. Measured <= 3 ulp vs
# glibc atanf over all finite floats (4M-point sweep). Edge contract:
# NaN -> NaN, +-inf -> +-pi/2, +-0 -> +-0.
float fatan(float x):
	if (fis_nan(x)):
		return x
	int sgn = 0
	if (float_bits(x) < 0):
		sgn = 1
	float ax = fabs(x)
	float pio2 = float_from_bits(0x3fc90fdb)
	if (float_bits(ax) == 0x7f800000):
		if (sgn):
			return -pio2
		return pio2
	float t3p8 = float_from_bits(0x401a827a)	# tan(3pi/8)
	float tp8 = float_from_bits(0x3ed413cd)	# tan(pi/8)
	float one = 1.0
	float base = 0.0
	float w = ax
	if (ax > t3p8):
		base = pio2
		w = -(one / ax)
	else if (ax > tp8):
		base = float_from_bits(0x3f490fdb)	# pi/4
		w = (ax - one) / (ax + one)
	float a0 = float_from_bits(cast(int, 0xbeaaaaaa))	# -3.3333331e-1
	float a1 = float_from_bits(0x3e4ccb98)	# 1.9999540e-1
	float a2 = float_from_bits(cast(int, 0xbe120ffd))	# -1.4263912e-1
	float a3 = float_from_bits(0x3ddc05a4)	# 1.0743263e-1
	float a4 = float_from_bits(cast(int, 0xbd841a8e))	# -6.4503774e-2
	float z = w * w
	float p = a0 + z * (a1 + z * (a2 + z * (a3 + z * a4)))
	float res = base + (w + (z * w) * p)
	if (sgn):
		return -res
	return res


# atan2(y, x): quadrant-correct atan(y/x). Measured <= 3 ulp vs glibc
# atan2f (6M-point sweep over mixed-magnitude finite pairs). Edge
# contract follows IEEE/glibc, verified bit-exactly in the tests:
# NaN in -> NaN out; atan2(+-0, x > 0 or +0) = +-0;
# atan2(+-0, x < 0 or -0) = +-pi; atan2(y != 0, +-0) = +-pi/2;
# x = +inf -> +-0, x = -inf -> +-pi (finite y); y = +-inf -> +-pi/2
# (finite x); (+-inf, +inf) = +-pi/4, (+-inf, -inf) = +-3pi/4.
# y/x overflow and underflow fall out correctly (pi/2- and pi-limits).
float fatan2(float y, float x):
	if (fis_nan(y)):
		return y
	if (fis_nan(x)):
		return x
	int xbits = float_bits(x)
	int ybits = float_bits(y)
	int sy = 0
	if (ybits < 0):
		sy = 1
	float pi = float_from_bits(0x40490fdb)
	float pio2 = float_from_bits(0x3fc90fdb)
	int x_inf = 0
	if ((xbits & 0x7fffffff) == 0x7f800000):
		x_inf = 1
	int y_inf = 0
	if ((ybits & 0x7fffffff) == 0x7f800000):
		y_inf = 1
	if (y_inf):
		float base = pio2
		if (x_inf):
			if (xbits < 0):
				base = float_from_bits(0x4016cbe4)	# 3pi/4
			else:
				base = float_from_bits(0x3f490fdb)	# pi/4
		if (sy):
			return -base
		return base
	if (x_inf):
		if (xbits < 0):
			if (sy):
				return -pi
			return pi
		if (sy):
			return float_from_bits(cast(int, 0x80000000))
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
		return fatan(y / x)
	float m = fatan(fabs(y / x))
	float pi_lo = float_from_bits(cast(int, 0xb3bbbd2e))	# pi - pi_hi
	float res = (pi - m) + pi_lo
	if (sy):
		return -res
	return res


# (asin(x) - x) / (x * z) for z = x^2 in [0, 0.2501]: degree-6
# Chebyshev fit, shared by fasin and facos (asin(x) = x + x*z*P(z)).
float fasin_poly(float z):
	float c0 = float_from_bits(0x3e2aaaab)	# 1.6666667e-1
	float c1 = float_from_bits(0x3d99998f)	# 7.4999921e-2
	float c2 = float_from_bits(0x3d36e07b)	# 4.4647675e-2
	float c3 = float_from_bits(0x3cf7f686)	# 3.0268919e-2
	float c4 = float_from_bits(0x3cc1718c)	# 2.3613714e-2
	float c5 = float_from_bits(0x3c2d20fe)	# 1.0566948e-2
	float c6 = float_from_bits(0x3cfdd538)	# 3.0985460e-2
	return c0 + z * (c1 + z * (c2 + z * (c3 + z * (c4 + z * (c5 + z * c6)))))


# asin(x). |x| <= 0.5 uses the kernel directly; |x| in (0.5, 1] uses
# asin(x) = pi/2 - 2*asin(sqrt((1-x)/2)) with pi/2 as a hi+lo pair so
# the constant costs nothing. Measured <= 2 ulp vs glibc asinf over
# [-1, 1] (5M-point sweep incl. dense [0.5, 1]). Edge contract:
# NaN -> NaN, |x| > 1 -> NaN, asin(+-1) = +-pi/2, asin(+-0) = +-0.
float fasin(float x):
	if (fis_nan(x)):
		return x
	int sgn = 0
	if (float_bits(x) < 0):
		sgn = 1
	float ax = fabs(x)
	float one = 1.0
	if (ax > one):
		return float_from_bits(0x7fc00000)
	float half = 0.5
	float res = 0.0
	if (ax <= half):
		float z = ax * ax
		res = ax + (ax * z) * fasin_poly(z)
	else:
		float z = (one - ax) * half
		float s = fsqrt(z)
		float t = s + (s * z) * fasin_poly(z)
		float pio2hi = float_from_bits(0x3fc90fdb)
		float pio2lo = float_from_bits(cast(int, 0xb33bbd2e))
		float two = 2.0
		res = (pio2hi - two * t) + pio2lo
	if (sgn):
		return -res
	return res


# acos(x). |x| <= 0.5 is pi/2 - asin(x); x in (0.5, 1] is
# 2*asin(sqrt((1-x)/2)) (cancellation-free near 1); x in [-1, -0.5) is
# pi - that. Measured <= 2 ulp vs glibc acosf over [-1, 1] (5M-point
# sweep). Edge contract: NaN -> NaN, |x| > 1 -> NaN, acos(1) = +0,
# acos(-1) = pi.
float facos(float x):
	if (fis_nan(x)):
		return x
	int sgn = 0
	if (float_bits(x) < 0):
		sgn = 1
	float ax = fabs(x)
	float one = 1.0
	if (ax > one):
		return float_from_bits(0x7fc00000)
	float half = 0.5
	if (ax <= half):
		float z = x * x
		float t = x + (x * z) * fasin_poly(z)
		float pio2hi = float_from_bits(0x3fc90fdb)
		float pio2lo = float_from_bits(cast(int, 0xb33bbd2e))
		return (pio2hi - t) + pio2lo
	float z = (one - ax) * half
	float s = fsqrt(z)
	float t = s + (s * z) * fasin_poly(z)
	float two = 2.0
	if (sgn == 0):
		return two * t
	float pihi = float_from_bits(0x40490fdb)
	float pilo = float_from_bits(cast(int, 0xb3bbbd2e))
	return (pihi - two * t) + pilo
