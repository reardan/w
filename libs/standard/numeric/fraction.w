# Exact rational numbers with Python `fractions.Fraction` semantics
# (docs/projects/stdlib_python_parity.md P3.5), built on
# libs/standard/numeric/bigint.w.
#
# VALUES ARE IMMUTABLE. Every operation returns a freshly allocated
# fraction* (or bigint*) that the caller releases with fraction_free()
# (bigint_free()); inputs are never modified and may alias each other.
# Where Python raises (zero denominator, division by zero, 0 ** negative,
# unparsable strings, limit_denominator(max < 1)) the call returns 0 (null).
#
# Invariant: den > 0 and gcd(|num|, den) == 1; zero is 0/1.
#
# Parsing accepts Python's Fraction(str) grammar: surrounding whitespace,
# an optional sign, then either "n/d" (whitespace allowed around '/') or a
# decimal literal with optional fraction part and exponent ("1.25",
# ".5", "-2e3", "2.5E+1"); single underscores may separate digits. The
# exponent must fit in [-FRACTION_MAX_EXP, FRACTION_MAX_EXP] (Python has no
# bound; W refuses larger ones instead of computing a huge power of ten).
import lib.lib
import lib.memory
import lib.mem
import libs.standard.numeric.bigint


const int FRACTION_MAX_EXP = 100000000


struct fraction:
	bigint* num    # numerator, carries the sign
	bigint* den    # denominator, always > 0


# ---- construction -----------------------------------------------------------

# Builds num/den taking ownership of both, reducing to lowest terms and
# moving the sign to the numerator. Null (freeing both) when den is zero.
fraction* fraction_make(bigint* num, bigint* den):
	if (bigint_is_zero(den) != 0):
		bigint_free(num)
		bigint_free(den)
		return 0
	if (bigint_sign(den) < 0):
		bigint* nn = bigint_neg(num)
		bigint* nd = bigint_neg(den)
		bigint_free(num)
		bigint_free(den)
		num = nn
		den = nd
	bigint* g = bigint_gcd(num, den)
	if (bigint_cmp_int(g, 1) != 0):
		bigint* rn = bigint_floordiv(num, g)
		bigint* rd = bigint_floordiv(den, g)
		bigint_free(num)
		bigint_free(den)
		num = rn
		den = rd
	bigint_free(g)
	return new fraction(num, den)


# Wraps an already coprime num/den (den > 0), taking ownership.
fraction* fraction_make_coprime(bigint* num, bigint* den):
	return new fraction(num, den)


void fraction_free(fraction* f):
	if (f == 0): return
	bigint_free(f.num)
	bigint_free(f.den)
	free(cast(char*, f))


fraction* fraction_from_int(int v):
	return new fraction(bigint_from_int(v), bigint_from_int(1))


# Fraction(n, d) for word-sized ints; null when d is zero.
fraction* fraction_from_ints(int n, int d):
	return fraction_make(bigint_from_int(n), bigint_from_int(d))


fraction* fraction_from_bigint(bigint* v):
	return new fraction(bigint_copy(v), bigint_from_int(1))


# Fraction(n, d) for bigints (copied); null when d is zero.
fraction* fraction_from_bigints(bigint* n, bigint* d):
	return fraction_make(bigint_copy(n), bigint_copy(d))


fraction* fraction_copy(fraction* f):
	return new fraction(bigint_copy(f.num), bigint_copy(f.den))


# Borrowed views of the normalized parts (Python .numerator/.denominator).
bigint* fraction_numerator(fraction* f):
	return f.num


bigint* fraction_denominator(fraction* f):
	return f.den


# ---- parsing ----------------------------------------------------------------

int fraction_is_space(char c):
	return (c == ' ') || (c == '\t') || (c == '\n') || (c == '\r') || (c == 11) || (c == 12)


int fraction_is_digit(char c):
	return (c >= '0') && (c <= '9')


# Scans digits with single underscores between them (\d+(_\d+)*) starting
# at s[*pos], appending the digits to out[*olen]. Returns the number of
# digits taken; on a malformed underscore *pos is set to -1.
int fraction_scan_digits(char* s, int end, int* pos, char* out, int* olen):
	int i = *pos
	int count = 0
	while (i < end):
		char c = s[i]
		if (fraction_is_digit(c) != 0):
			out[*olen] = c
			*olen = *olen + 1
			count = count + 1
			i = i + 1
		else if ((c == '_') && (count > 0) && (i + 1 < end) && (fraction_is_digit(s[i + 1]) != 0)):
			i = i + 1
		else:
			*pos = i
			return count
	*pos = i
	return count


# 10 ** e as a bigint (e >= 0).
bigint* fraction_pow10(int e):
	bigint* ten = bigint_from_int(10)
	bigint* r = bigint_pow(ten, e)
	bigint_free(ten)
	return r


# Parses a digit buffer of length n (n may be 0, meaning zero).
bigint* fraction_digits_value(char* buf, int n):
	if (n == 0): return bigint_zero()
	buf[n] = 0
	return bigint_parse(buf, 10)


# Python Fraction(s). Null on a syntax error or a zero denominator.
fraction* fraction_parse(char* s):
	int end = strlen(s)
	int i = 0
	while ((i < end) && (fraction_is_space(s[i]) != 0)): i = i + 1
	while ((end > i) && (fraction_is_space(s[end - 1]) != 0)): end = end - 1
	int neg = 0
	if ((i < end) && ((s[i] == '+') || (s[i] == '-'))):
		if (s[i] == '-'): neg = 1
		i = i + 1
	# Lookahead: a digit, or '.' followed by a digit.
	if (i >= end): return 0
	if (fraction_is_digit(s[i]) == 0):
		if ((s[i] != '.') || (i + 1 >= end) || (fraction_is_digit(s[i + 1]) == 0)): return 0
	char* buf = cast(char*, malloc(end - i + 2))
	int blen = 0
	int ndig = fraction_scan_digits(s, end, &i, buf, &blen)
	bigint* num = 0
	bigint* den = 0
	int ok = 1
	# Optional "/ denom" with whitespace around the slash.
	int j = i
	while ((j < end) && (fraction_is_space(s[j]) != 0)): j = j + 1
	if ((ndig > 0) && (j < end) && (s[j] == '/')):
		j = j + 1
		while ((j < end) && (fraction_is_space(s[j]) != 0)): j = j + 1
		num = fraction_digits_value(buf, blen)
		blen = 0
		int dd = fraction_scan_digits(s, end, &j, buf, &blen)
		if ((dd == 0) || (j != end)): ok = 0
		else: den = fraction_digits_value(buf, blen)
	else:
		int intlen = blen
		int fraclen = 0
		if ((i < end) && (s[i] == '.')):
			i = i + 1
			fraclen = fraction_scan_digits(s, end, &i, buf, &blen)
		int e = 0
		if ((i < end) && ((s[i] == 'e') || (s[i] == 'E'))):
			i = i + 1
			int eneg = 0
			if ((i < end) && ((s[i] == '+') || (s[i] == '-'))):
				if (s[i] == '-'): eneg = 1
				i = i + 1
			int estart = blen
			int ed = fraction_scan_digits(s, end, &i, buf, &blen)
			if (ed == 0): ok = 0
			int k = estart
			while ((ok != 0) && (k < blen)):
				e = e * 10 + (buf[k] - '0')
				if (e > FRACTION_MAX_EXP): ok = 0
				k = k + 1
			blen = estart
			if (eneg != 0): e = 0 - e
		if (i != end): ok = 0
		if (ok != 0):
			num = fraction_digits_value(buf, intlen + fraclen)
			int scale = e - fraclen
			if (scale >= 0):
				bigint* p = fraction_pow10(scale)
				bigint* t = bigint_mul(num, p)
				bigint_free(num)
				bigint_free(p)
				num = t
				den = bigint_from_int(1)
			else:
				den = fraction_pow10(0 - scale)
	free(buf)
	if (ok == 0):
		bigint_free(num)
		bigint_free(den)
		return 0
	if (neg != 0):
		bigint* nn = bigint_neg(num)
		bigint_free(num)
		num = nn
	return fraction_make(num, den)


# ---- formatting -------------------------------------------------------------

# Python str(f): "n/d", or just "n" when the denominator is 1.
char* fraction_to_string(fraction* f):
	char* n = bigint_to_string(f.num)
	if (bigint_cmp_int(f.den, 1) == 0): return n
	char* d = bigint_to_string(f.den)
	int nl = strlen(n)
	int dl = strlen(d)
	char* out = cast(char*, malloc(nl + dl + 2))
	mem_copy(out, n, nl)
	out[nl] = '/'
	char* dst = &out[nl + 1]
	mem_copy(dst, d, dl)
	out[nl + dl + 1] = 0
	free(n)
	free(d)
	return out


# ---- predicates and comparison ----------------------------------------------

int fraction_sign(fraction* f):
	return bigint_sign(f.num)


int fraction_is_zero(fraction* f):
	return bigint_is_zero(f.num)


int fraction_is_integer(fraction* f):
	return bigint_cmp_int(f.den, 1) == 0


# -1, 0 or 1.
int fraction_cmp(fraction* a, fraction* b):
	bigint* l = bigint_mul(a.num, b.den)
	bigint* r = bigint_mul(b.num, a.den)
	int c = bigint_cmp(l, r)
	bigint_free(l)
	bigint_free(r)
	return c


int fraction_eq(fraction* a, fraction* b):
	return (bigint_eq(a.num, b.num) != 0) && (bigint_eq(a.den, b.den) != 0)


# ---- arithmetic -------------------------------------------------------------

fraction* fraction_neg(fraction* a):
	return new fraction(bigint_neg(a.num), bigint_copy(a.den))


fraction* fraction_abs(fraction* a):
	return new fraction(bigint_abs(a.num), bigint_copy(a.den))


# a + s*b for s = 1 or -1.
fraction* fraction_addsub(fraction* a, fraction* b, int s):
	bigint* l = bigint_mul(a.num, b.den)
	bigint* r = bigint_mul(b.num, a.den)
	bigint* n = 0
	if (s > 0): n = bigint_add(l, r)
	else: n = bigint_sub(l, r)
	bigint_free(l)
	bigint_free(r)
	return fraction_make(n, bigint_mul(a.den, b.den))


fraction* fraction_add(fraction* a, fraction* b):
	return fraction_addsub(a, b, 1)


fraction* fraction_sub(fraction* a, fraction* b):
	return fraction_addsub(a, b, 0 - 1)


fraction* fraction_mul(fraction* a, fraction* b):
	return fraction_make(bigint_mul(a.num, b.num), bigint_mul(a.den, b.den))


# a / b; null when b is zero.
fraction* fraction_div(fraction* a, fraction* b):
	if (bigint_is_zero(b.num) != 0): return 0
	return fraction_make(bigint_mul(a.num, b.den), bigint_mul(a.den, b.num))


# Python divmod(a, b): *q = a // b (a bigint), *r = a - q*b with b's sign.
# Returns 0 (setting nothing) when b is zero; q or r may be null.
int fraction_divmod(fraction* a, fraction* b, bigint** q, fraction** r):
	if (bigint_is_zero(b.num) != 0): return 0
	bigint* x = bigint_mul(a.num, b.den)
	bigint* y = bigint_mul(a.den, b.num)
	bigint* qq = 0
	bigint* rr = 0
	bigint_divmod(x, y, &qq, &rr)
	bigint_free(x)
	bigint_free(y)
	if (q != 0): *q = qq
	else: bigint_free(qq)
	if (r != 0): *r = fraction_make(rr, bigint_mul(a.den, b.den))
	else: bigint_free(rr)
	return 1


# a // b as a bigint; null when b is zero.
bigint* fraction_floordiv(fraction* a, fraction* b):
	bigint* q = 0
	fraction_divmod(a, b, &q, 0)
	return q


# a % b (zero or with b's sign); null when b is zero.
fraction* fraction_mod(fraction* a, fraction* b):
	fraction* r = 0
	fraction_divmod(a, b, 0, &r)
	return r


# a ** e for an integer e; a negative e inverts. Null for 0 ** negative.
fraction* fraction_pow(fraction* a, int e):
	if (e >= 0):
		return new fraction(bigint_pow(a.num, e), bigint_pow(a.den, e))
	if (bigint_is_zero(a.num) != 0): return 0
	int m = 0 - e
	bigint* n = bigint_pow(a.den, m)
	bigint* d = bigint_pow(a.num, m)
	if (bigint_sign(d) < 0):
		bigint* nn = bigint_neg(n)
		bigint* nd = bigint_neg(d)
		bigint_free(n)
		bigint_free(d)
		n = nn
		d = nd
	return new fraction(n, d)


# ---- rounding ---------------------------------------------------------------

# math.floor(f)
bigint* fraction_floor(fraction* f):
	return bigint_floordiv(f.num, f.den)


# math.ceil(f) == -((-n) // d)
bigint* fraction_ceil(fraction* f):
	bigint* n = bigint_neg(f.num)
	bigint* q = bigint_floordiv(n, f.den)
	bigint* r = bigint_neg(q)
	bigint_free(n)
	bigint_free(q)
	return r


# math.trunc(f): rounds toward zero.
bigint* fraction_trunc(fraction* f):
	if (bigint_sign(f.num) < 0): return fraction_ceil(f)
	return fraction_floor(f)


# Python round(f): nearest integer, ties to even.
bigint* fraction_round(fraction* f):
	bigint* fl = 0
	bigint* rem = 0
	bigint_divmod(f.num, f.den, &fl, &rem)
	bigint* twice = bigint_mul_int(rem, 2)
	int c = bigint_cmp(twice, f.den)
	bigint_free(twice)
	bigint_free(rem)
	if ((c > 0) || ((c == 0) && (bigint_is_odd(fl) != 0))):
		bigint* t = bigint_add_int(fl, 1)
		bigint_free(fl)
		fl = t
	return fl


# Python round(f, ndigits): rounds to a multiple of 10 ** -ndigits, ties
# to even.
fraction* fraction_round_digits(fraction* f, int ndigits):
	int m = ndigits
	if (m < 0): m = 0 - m
	bigint* shift = fraction_pow10(m)
	fraction* sf = fraction_from_bigint(shift)
	fraction* scaled = 0
	if (ndigits > 0): scaled = fraction_mul(f, sf)
	else: scaled = fraction_div(f, sf)
	bigint* r = fraction_round(scaled)
	fraction_free(scaled)
	fraction_free(sf)
	fraction* out = 0
	if (ndigits > 0):
		out = fraction_make(r, shift)
	else:
		out = new fraction(bigint_mul(r, shift), bigint_from_int(1))
		bigint_free(r)
		bigint_free(shift)
	return out


# Python Fraction.limit_denominator(max_den): the closest fraction with
# denominator <= max_den. Null when max_den < 1.
fraction* fraction_limit_denominator(fraction* f, int max_den):
	if (max_den < 1): return 0
	if (bigint_cmp_int(f.den, max_den) <= 0): return fraction_copy(f)
	bigint* maxd = bigint_from_int(max_den)
	bigint* p0 = bigint_from_int(0)
	bigint* q0 = bigint_from_int(1)
	bigint* p1 = bigint_from_int(1)
	bigint* q1 = bigint_from_int(0)
	bigint* n = bigint_copy(f.num)
	bigint* d = bigint_copy(f.den)
	int done = 0
	while (done == 0):
		bigint* a = bigint_floordiv(n, d)
		bigint* aq1 = bigint_mul(a, q1)
		bigint* q2 = bigint_add(q0, aq1)
		bigint_free(aq1)
		if (bigint_cmp(q2, maxd) > 0):
			bigint_free(a)
			bigint_free(q2)
			done = 1
		else:
			bigint* ap1 = bigint_mul(a, p1)
			bigint* p2 = bigint_add(p0, ap1)
			bigint_free(ap1)
			bigint_free(p0)
			bigint_free(q0)
			p0 = p1
			q0 = q1
			p1 = p2
			q1 = q2
			bigint* ad = bigint_mul(a, d)
			bigint* nd = bigint_sub(n, ad)
			bigint_free(ad)
			bigint_free(n)
			n = d
			d = nd
			bigint_free(a)
	# k = (max_den - q0) // q1
	bigint* t = bigint_sub(maxd, q0)
	bigint* k = bigint_floordiv(t, q1)
	bigint_free(t)
	bigint* kq1 = bigint_mul(k, q1)
	bigint* bq = bigint_add(q0, kq1)
	bigint_free(kq1)
	# 2 * d * (q0 + k*q1) <= f.den picks p1/q1, else the bound candidate.
	bigint* lhs0 = bigint_mul(d, bq)
	bigint* lhs = bigint_mul_int(lhs0, 2)
	bigint_free(lhs0)
	fraction* out = 0
	if (bigint_cmp(lhs, f.den) <= 0):
		out = new fraction(bigint_copy(p1), bigint_copy(q1))
		bigint_free(bq)
	else:
		bigint* kp1 = bigint_mul(k, p1)
		bigint* bp = bigint_add(p0, kp1)
		bigint_free(kp1)
		out = new fraction(bp, bq)
	bigint_free(lhs)
	bigint_free(k)
	bigint_free(maxd)
	bigint_free(p0)
	bigint_free(q0)
	bigint_free(p1)
	bigint_free(q1)
	bigint_free(n)
	bigint_free(d)
	return out
