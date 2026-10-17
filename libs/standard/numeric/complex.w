/*
libs.standard.numeric.complex: complex numbers over float64, after
Python's complex type and cmath module (docs/projects/
stdlib_python_parity.md, chunk P3.6).

	import libs.standard.numeric.complex

	complex z = complex(3.0, 4.0)
	complex w = z * complex_conj(z) + complex(1.0, 0.0)
	float64 r = complex_abs(z)          # 5.0
	complex s = complex_sqrt(complex(-4.0, 0.0))    # 0 + 2j

float64 only exists on 64-bit targets (docs/projects/float.md), so this
module is x64-only like lib/fmath64.w, whose kernels it uses.

`complex` is a two-field struct passed and returned by value, and the
binary operators + - * / are overloaded for complex operands
(docs/projects/operator_overloading.md); the named functions
complex_add/sub/mul/div do the same thing for call sites that prefer
them. Mixed complex/float64 arithmetic goes through complex(x, 0.0) or
complex_scale.

Semantics follow CPython: * is the textbook formula (no infinity
recovery), / is Smith's algorithm (plus C11 Annex G recovery of
infinities and zeros), and the cmath functions use the principal
branch with the branch cuts and signed-zero behavior of cmath (sqrt
and log cut along the negative real axis, the sign of a zero imaginary
part picking the side). Measured against mpmath per part: sqrt within
1.6 ulp, exp and log within 2.7, bounded by fsin64/fcos64/fatan264. Where Python raises -- division by zero, log(0) --
these return IEEE values instead: complex division by zero gives
nan + nanj, and log(0) gives -inf + phase j.
*/
import lib.fmath64


struct complex:
	float64 re
	float64 im


complex complex_add(complex a, complex b):
	return complex(a.re + b.re, a.im + b.im)


complex complex_sub(complex a, complex b):
	return complex(a.re - b.re, a.im - b.im)


# (a.re + a.im j)(b.re + b.im j), the plain formula CPython uses.
complex complex_mul(complex a, complex b):
	return complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)


# a / b by Smith's algorithm (scale by the larger of |b.re|, |b.im| so
# no intermediate overflows needlessly), exactly as CPython does, then
# the C11 Annex G (G.5.2) recovery that CPython 3.13 lacks: a result
# that came out nan + nanj from an infinite numerator over a finite
# divisor is an infinity, and a finite numerator over an infinite
# divisor a (signed) zero. Division by 0 + 0j returns nan + nanj
# (Python raises ZeroDivisionError).
complex complex_div(complex a, complex b):
	float64 abr = fabs64(b.re)
	float64 abi = fabs64(b.im)
	float64 nan = float64_from_bits(0x7ff8 << 48)
	float64 rr = nan
	float64 ri = nan
	# NaN checks first: W's float comparisons are not IEEE for NaN
	# (docs/projects/float.md)
	if (f64is_nan(b.re) || f64is_nan(b.im)):
		return complex(nan, nan)
	if (abr >= abi):
		if (abr == 0.0): return complex(nan, nan)
		float64 ratio = b.im / b.re
		float64 denom = b.re + b.im * ratio
		rr = (a.re + a.im * ratio) / denom
		ri = (a.im - a.re * ratio) / denom
	else:
		float64 ratio = b.re / b.im
		float64 denom = b.re * ratio + b.im
		rr = (a.re * ratio + a.im) / denom
		ri = (a.im * ratio - a.re) / denom
	if (f64is_nan(rr) && f64is_nan(ri)):
		float64 inf = float64_from_bits(0x7ff << 52)
		if ((f64is_inf(a.re) || f64is_inf(a.im)) && f64is_finite(b.re) && f64is_finite(b.im)):
			float64 x = 0.0
			if (f64is_inf(a.re)): x = 1.0
			x = fcopysign64(x, a.re)
			float64 y = 0.0
			if (f64is_inf(a.im)): y = 1.0
			y = fcopysign64(y, a.im)
			rr = inf * (x * b.re + y * b.im)
			ri = inf * (y * b.re - x * b.im)
		else if ((f64is_inf(b.re) || f64is_inf(b.im)) && f64is_finite(a.re) && f64is_finite(a.im)):
			float64 x = 0.0
			if (f64is_inf(b.re)): x = 1.0
			x = fcopysign64(x, b.re)
			float64 y = 0.0
			if (f64is_inf(b.im)): y = 1.0
			y = fcopysign64(y, b.im)
			rr = 0.0 * (a.re * x + a.im * y)
			ri = 0.0 * (a.im * x - a.re * y)
	return complex(rr, ri)


complex operator+(complex a, complex b):
	return complex_add(a, b)


complex operator-(complex a, complex b):
	return complex_sub(a, b)


complex operator*(complex a, complex b):
	return complex_mul(a, b)


complex operator/(complex a, complex b):
	return complex_div(a, b)


complex complex_neg(complex a):
	return complex(-a.re, -a.im)


# a * s for a real s, componentwise.
complex complex_scale(complex a, float64 s):
	return complex(a.re * s, a.im * s)


# Complex conjugate (Python z.conjugate()).
complex complex_conj(complex a):
	return complex(a.re, -a.im)


# |a| (Python abs(z)): fhypot64, so no spurious overflow, within ~0.5
# ulp, and +inf whenever either part is infinite even if the other is NaN.
float64 complex_abs(complex a):
	return fhypot64(a.re, a.im)


# Argument in [-pi, pi] (cmath.phase): atan2(im, re), signed zeros
# selecting +-pi on the negative real axis.
float64 complex_phase(complex a):
	return fatan264(a.im, a.re)


# cmath.polar: writes |a| and phase(a).
void complex_polar(complex a, float64* r_out, float64* phi_out):
	*r_out = complex_abs(a)
	*phi_out = complex_phase(a)


# cmath.rect: r (cos phi + j sin phi). phi == +-0 gives exactly
# (r, phi * sign(r)), so an infinite r gets no NaN imaginary part, as
# in CPython. NaN phi gives (r, nan) for infinite r and nan + nanj
# otherwise; an infinite phi gives nan + nanj (Python raises).
complex complex_rect(float64 r, float64 phi):
	float64 nan = float64_from_bits(0x7ff8 << 48)
	if (f64is_nan(phi)):
		if (f64is_inf(r)): return complex(r, phi)
		return complex(nan, nan)
	if (phi == 0.0): return complex(r, phi * fcopysign64(1.0, r))
	if (f64is_nan(r)): return complex(nan, nan)
	return complex(r * fcos64(phi), r * fsin64(phi))


# e^a (cmath.exp) = e^re (cos im + j sin im). e^re is kept as m * 2^n
# so the result stays finite when e^re alone would overflow (re up to
# ~710 + ln 2) and rounds once when it underflows. Special values follow
# C99 Annex G / cmath: im = +-0 keeps its zero, e^(-inf + yj) is a signed
# zero, e^(+inf + yj) an infinity (NaN imaginary part for infinite or
# NaN y), NaN otherwise.
complex complex_exp(complex a):
	float64 x = a.re
	float64 y = a.im
	float64 nan = float64_from_bits(0x7ff8 << 48)
	float64 inf = float64_from_bits(0x7ff << 52)
	if (f64is_finite(x) == 0 || f64is_finite(y) == 0):
		if (f64is_nan(x)):
			if (f64is_nan(y) == 0 && y == 0.0): return complex(nan, y)
			return complex(nan, nan)
		if (f64is_inf(x)):
			if (x > 0.0):
				if (f64is_finite(y) == 0): return complex(inf, nan)
				if (y == 0.0): return complex(inf, y)
				return complex(inf * fcos64(y), inf * fsin64(y))
			if (f64is_finite(y) == 0): return complex(0.0, 0.0)
			return complex(0.0 * fcos64(y), 0.0 * fsin64(y))
		return complex(nan, nan)
	if (x > 712.0):
		if (y == 0.0): return complex(inf, y)
		return complex(inf * fcos64(y), inf * fsin64(y))
	if (x < -746.0):
		return complex(0.0 * fcos64(y), 0.0 * fsin64(y))
	int n = 0
	float64 m = fm64_exp_split(x, 0.0, &n)
	if (y == 0.0): return complex(fldexp64(m, n), y)
	return complex(fldexp64(m * fcos64(y), n), fldexp64(m * fsin64(y), n))


# ln|a| for finite a, not 0: half the log of re^2 + im^2 summed as a
# float64 pair (after power-of-two scaling far from 1), through log1p of
# the pair minus 1 when |a| is near 1 so the real part keeps full
# relative accuracy there.
float64 complex_log_abs(float64 x, float64 y):
	float64 a = fabs64(x)
	float64 b = fabs64(y)
	if (a < b):
		float64 tmp = a
		a = b
		b = tmp
	int sc = 0
	float64 two_500 = 3.2733906078961419e+150    # 2^500
	float64 two_m500 = 3.0549363634996047e-151    # 2^-500
	if (a > two_500):
		a = fldexp64(a, -600)
		b = fldexp64(b, -600)
		sc = 600
	else if (a < two_m500):
		a = fldexp64(a, 600)
		b = fldexp64(b, 600)
		sc = -600
	f64dd s = fm64_dd_add(fm64_two_prod(a, a), fm64_two_prod(b, b))
	f64dd l = fm64_dd(0.0)
	if (sc == 0 && s.hi > 0.5 && s.hi < 3.0):
		l = fm64_log1p_dd2(fm64_dd_add(s, fm64_dd(-1.0)))
	else:
		l = fm64_dd_add(fm64_log_dd(s.hi), fm64_dd(s.lo / s.hi))
	if (sc != 0):
		# ln(2^(2 sc)) = 2 sc ln2, folded in before halving
		f64dd ln2 = f64dd(6.93147180559945286e-01, 2.31904681384629956e-17)
		float64 k = 2 * sc
		l = fm64_dd_add(l, fm64_dd_mul(fm64_dd(k), ln2))
	return 0.5 * (l.hi + l.lo)


# Principal natural log (cmath.log): ln|a| + j phase(a), the cut along
# the negative real axis with -0.0 imaginary parts mapping to -pi.
# Edge contract: log(+-0 + yj) for y = +-0 is -inf + phase j (Python
# raises ValueError); an infinite part gives +inf real part; NaN
# otherwise propagates.
complex complex_log(complex a):
	float64 x = a.re
	float64 y = a.im
	float64 nan = float64_from_bits(0x7ff8 << 48)
	float64 inf = float64_from_bits(0x7ff << 52)
	if (f64is_inf(x) || f64is_inf(y)):
		if (f64is_nan(x) || f64is_nan(y)): return complex(inf, nan)
		return complex(inf, fatan264(y, x))
	if (f64is_nan(x) || f64is_nan(y)): return complex(nan, nan)
	if (x == 0.0 && y == 0.0): return complex(-inf, fatan264(y, x))
	return complex(complex_log_abs(x, y), fatan264(y, x))


# Principal square root (cmath.sqrt), Kahan's method as in CPython:
# s = sqrt((|re| + |a|) / 2) and d = |im| / (2 s), the larger one on the
# real axis for re >= 0 and on the imaginary axis (with im's sign) for
# re < 0, so the result is accurate in both parts and the cut along the
# negative real axis follows the sign of a zero imaginary part. The
# root of (|re| + |a|) / 2 is taken in float64-pair precision. Edge contract
# (C99 Annex G): sqrt(+-0 + yj) for y = +-0 is (+0, y); an infinite
# imaginary part gives +inf + im j even with a NaN real part;
# sqrt(-inf + yj) = 0 + inf j (sign of y), sqrt(+inf + yj) = inf + 0j
# (sign of y); a NaN with -inf gives nan +- inf j, with +inf inf + nan j.
complex complex_sqrt(complex a):
	float64 x = a.re
	float64 y = a.im
	float64 nan = float64_from_bits(0x7ff8 << 48)
	float64 inf = float64_from_bits(0x7ff << 52)
	if (f64is_inf(y)): return complex(inf, y)
	if (f64is_inf(x)):
		if (x > 0.0):
			if (f64is_nan(y)): return complex(inf, y)
			return complex(inf, fcopysign64(0.0, y))
		if (f64is_nan(y)): return complex(nan, inf)
		return complex(0.0, fcopysign64(inf, y))
	if (f64is_nan(x) || f64is_nan(y)): return complex(nan, nan)
	if (x == 0.0 && y == 0.0): return complex(0.0, y)
	float64 ax = fabs64(x)
	float64 ay = fabs64(y)
	# scale far-from-1 inputs by 2^-+600 (the root by 2^-+300) so
	# |re| + |a| neither overflows nor goes subnormal
	float64 m = ax
	if (ay > m): m = ay
	int sc = 0
	float64 sx = ax
	float64 sy = ay
	float64 two_500 = 3.2733906078961419e+150    # 2^500
	float64 two_m500 = 3.0549363634996047e-151    # 2^-500
	if (m > two_500):
		sx = fldexp64(ax, -600)
		sy = fldexp64(ay, -600)
		sc = 300
	else if (m < two_m500):
		sx = fldexp64(ax, 600)
		sy = fldexp64(ay, 600)
		sc = -300
	f64dd t = fm64_two_sum(sx, fhypot64(sx, sy))
	f64dd r = fm64_dd_sqrt(f64dd(t.hi * 0.5, t.lo * 0.5))
	float64 s = fldexp64(r.hi + r.lo, sc)
	float64 d = ay / (2.0 * s)
	if (x >= 0.0): return complex(s, fcopysign64(d, y))
	return complex(d, fcopysign64(s, y))


# cmath.isclose(a, b, rel_tol=rel_tol, abs_tol=abs_tol):
# |a - b| <= max(rel_tol * max(|a|, |b|), abs_tol), with equal values
# (including equal infinities) always close and NaN never close.
# Negative or NaN tolerances return 0 (Python raises).
int complex_isclose_tol(complex a, complex b, float64 rel_tol, float64 abs_tol):
	if (f64is_nan(a.re) || f64is_nan(a.im) || f64is_nan(b.re) || f64is_nan(b.im)): return 0
	if (f64is_nan(rel_tol) || f64is_nan(abs_tol)): return 0
	if (rel_tol < 0.0 || abs_tol < 0.0): return 0
	if (a.re == b.re && a.im == b.im): return 1
	if (f64is_inf(a.re) || f64is_inf(a.im) || f64is_inf(b.re) || f64is_inf(b.im)): return 0
	float64 diff = complex_abs(complex_sub(a, b))
	if (diff <= rel_tol * complex_abs(a)): return 1
	if (diff <= rel_tol * complex_abs(b)): return 1
	if (diff <= abs_tol): return 1
	return 0


# cmath.isclose(a, b) with the defaults rel_tol=1e-09, abs_tol=0.0.
int complex_isclose(complex a, complex b):
	return complex_isclose_tol(a, b, 1e-09, 0.0)
