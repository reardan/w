# Arbitrary-precision decimal floating point with Python `decimal`
# semantics (docs/projects/stdlib_python_parity.md P3.5): the General
# Decimal Arithmetic specification as CPython implements it, ported from
# Lib/_pydecimal.py on top of libs/standard/numeric/bigint.w.
#
# VALUES ARE IMMUTABLE. Every operation returns a freshly allocated
# decimal* that the caller releases with decimal_free(); inputs are never
# modified and may alias each other.
#
# CONTEXT. Arithmetic takes an explicit decimal_context* (there is no
# thread-global getcontext()). decimal_context_new() gives Python's
# DefaultContext: prec 28, ROUND_HALF_EVEN, Emin -999999, Emax 999999,
# clamp 0. Its fields are public and may be changed directly.
#
# SIGNALS. Traps are not supported: every condition behaves as if
# untrapped, i.e. like Python with Context(traps=[]). A raised condition
# ORs its DECIMAL_* bit into ctx.flags and the operation returns the
# specification's default result (NaN for an invalid operation, a signed
# Infinity for division by zero or overflow, ...). Python's
# ConversionSyntax, DivisionImpossible, DivisionUndefined and
# InvalidContext all set DECIMAL_INVALID_OPERATION, as in Python's flags.
# FloatOperation does not exist (there are no float conversions).
#
# EXPONENT RANGE. Python exponents are unbounded; here they are word-sized
# ints. decimal_parse rejects literals whose exponent magnitude exceeds
# DECIMAL_MAX_EXP, and contexts must keep Emax <= DECIMAL_MAX_EMAX and
# Emin >= -DECIMAL_MAX_EMAX (libmpdec's 32-bit limits) so that exponent
# arithmetic cannot overflow on the 32-bit target.
#
# Representation: a coefficient digit string (no leading zeros; "0" for
# zero), an exponent, a sign bit (0 or 1, so -0 exists) and a kind
# (finite, infinity, quiet NaN, signaling NaN). NaN payloads are kept as
# their digit string ("" when absent).
import lib.lib
import lib.memory
import libs.standard.numeric.bigint


const int DECIMAL_FINITE = 0
const int DECIMAL_INF = 1
const int DECIMAL_QNAN = 2
const int DECIMAL_SNAN = 3

# Rounding modes.
const int DECIMAL_ROUND_HALF_EVEN = 0
const int DECIMAL_ROUND_HALF_UP = 1
const int DECIMAL_ROUND_HALF_DOWN = 2
const int DECIMAL_ROUND_DOWN = 3
const int DECIMAL_ROUND_UP = 4
const int DECIMAL_ROUND_CEILING = 5
const int DECIMAL_ROUND_FLOOR = 6
const int DECIMAL_ROUND_05UP = 7

# Signal flags (bits of decimal_context.flags).
const int DECIMAL_CLAMPED = 1
const int DECIMAL_INVALID_OPERATION = 2
const int DECIMAL_DIVISION_BY_ZERO = 4
const int DECIMAL_INEXACT = 8
const int DECIMAL_ROUNDED = 16
const int DECIMAL_SUBNORMAL = 32
const int DECIMAL_OVERFLOW = 64
const int DECIMAL_UNDERFLOW = 128

# decimal_cmp's answer when either operand is a NaN.
const int DECIMAL_UNORDERED = 2

const int DECIMAL_MAX_EXP = 999999999
const int DECIMAL_MAX_EMAX = 425000000


struct decimal:
	int sign       # 0 positive, 1 negative
	char* digits   # coefficient (or NaN payload) digits, NUL-terminated
	int len        # strlen(digits)
	int exp        # exponent of a finite value; 0 otherwise
	int kind       # DECIMAL_FINITE, DECIMAL_INF, DECIMAL_QNAN, DECIMAL_SNAN


struct decimal_context:
	int prec       # significant digits, >= 1
	int rounding   # DECIMAL_ROUND_*
	int emin       # <= 0
	int emax       # >= 0
	int clamp      # 0 or 1 (IEEE 754 fold-down)
	int flags      # DECIMAL_* signals raised so far


decimal* decimal_from_bigint(bigint* v);
decimal* decimal_from_bigint_scaled(bigint* v, int exp);
decimal* decimal_parse_clean(char* s, int n);
bigint* decimal_to_bigint_rounded(decimal* a, int rounding);


# ---- context ----------------------------------------------------------------

# Python's DefaultContext without traps.
decimal_context* decimal_context_new():
	return new decimal_context(28, DECIMAL_ROUND_HALF_EVEN, 0 - 999999, 999999, 0, 0)


void decimal_context_free(decimal_context* ctx):
	free(cast(char*, ctx))


decimal_context* decimal_context_copy(decimal_context* ctx):
	return new decimal_context(ctx.prec, ctx.rounding, ctx.emin, ctx.emax, ctx.clamp, ctx.flags)


void decimal_context_clear_flags(decimal_context* ctx):
	ctx.flags = 0


int decimal_etiny(decimal_context* ctx):
	return ctx.emin - ctx.prec + 1


int decimal_etop(decimal_context* ctx):
	return ctx.emax - ctx.prec + 1


void decimal_raise(decimal_context* ctx, int flag):
	ctx.flags = ctx.flags | flag


# ---- digit strings ----------------------------------------------------------

char* decimal_str_alloc(int n):
	char* s = cast(char*, malloc(n + 1))
	s[n] = 0
	return s


void decimal_copy_chars(char* dst, char* src, int n):
	int i = 0
	while (i < n):
		dst[i] = src[i]
		i = i + 1


# Copy of s[0 .. n) followed by z zeros.
char* decimal_str_pad(char* s, int n, int z):
	char* r = decimal_str_alloc(n + z)
	if (n > 0): decimal_copy_chars(r, s, n)
	int i = 0
	while (i < z):
		r[n + i] = '0'
		i = i + 1
	return r


char* decimal_str_dup(char* s, int n):
	return decimal_str_pad(s, n, 0)


# 1 when s[pos ..) is all zeros (or empty).
int decimal_all_zeros(char* s, int pos):
	while (s[pos] != 0):
		if (s[pos] != '0'): return 0
		pos = pos + 1
	return 1


# 1 when s[pos ..) is "5" followed only by zeros.
int decimal_exact_half(char* s, int pos):
	if (s[pos] != '5'): return 0
	return decimal_all_zeros(s, pos + 1)


# Decimal digit string of value(s[0 .. n)) + 1, as a new string.
char* decimal_str_incr(char* s, int n):
	char* r = decimal_str_alloc(n + 1)
	r[0] = '0'
	if (n > 0): decimal_copy_chars(&r[1], s, n)
	int i = n
	int carry = 1
	while ((carry != 0) && (i >= 0)):
		if (r[i] == '9'):
			r[i] = '0'
		else:
			r[i] = r[i] + 1
			carry = 0
		i = i - 1
	if (r[0] == '0'):
		char* t = decimal_str_dup(&r[1], n)
		free(r)
		return t
	return r


# ---- construction -----------------------------------------------------------

# Wraps digits (ownership transfers). Finite coefficients lose leading
# zeros (empty becomes "0"); NaN payloads lose leading zeros (may become
# ""); infinities always carry "0".
decimal* decimal_make(int sign, char* digits, int exp, int kind):
	if (kind == DECIMAL_INF):
		free(digits)
		digits = decimal_str_dup(c"0", 1)
	if (kind != DECIMAL_FINITE): exp = 0
	int n = strlen(digits)
	int lead = 0
	while ((lead < n) && (digits[lead] == '0')): lead = lead + 1
	if ((kind == DECIMAL_FINITE) && (lead == n)):
		free(digits)
		return new decimal(sign, decimal_str_dup(c"0", 1), 1, exp, kind)
	if (kind == DECIMAL_INF): lead = 0
	if (lead > 0):
		char* t = decimal_str_dup(&digits[lead], n - lead)
		free(digits)
		digits = t
		n = n - lead
	return new decimal(sign, digits, n, exp, kind)


# Finite value from the first n digits of s (copied).
decimal* decimal_triple(int sign, char* s, int n, int exp):
	return decimal_make(sign, decimal_str_dup(s, n), exp, DECIMAL_FINITE)


# Finite value sign * mag * 10**exp for a non-negative bigint mag.
decimal* decimal_from_mag(int sign, bigint* mag, int exp):
	return decimal_make(sign, bigint_to_string(mag), exp, DECIMAL_FINITE)


void decimal_free(decimal* d):
	if (d == 0): return
	free(d.digits)
	free(cast(char*, d))


decimal* decimal_copy(decimal* d):
	return new decimal(d.sign, decimal_str_dup(d.digits, d.len), d.len, d.exp, d.kind)


decimal* decimal_nan():
	return decimal_make(0, decimal_str_dup(c"", 0), 0, DECIMAL_QNAN)


decimal* decimal_infinity(int sign):
	return decimal_make(sign, decimal_str_dup(c"0", 1), 0, DECIMAL_INF)


decimal* decimal_from_int(int v):
	bigint* b = bigint_from_int(v)
	decimal* d = decimal_from_bigint(b)
	bigint_free(b)
	return d


decimal* decimal_from_bigint(bigint* v):
	return decimal_from_bigint_scaled(v, 0)


# v * 10**exp, exactly.
decimal* decimal_from_bigint_scaled(bigint* v, int exp):
	int sign = 0
	if (bigint_sign(v) < 0): sign = 1
	bigint* m = bigint_abs(v)
	decimal* d = decimal_from_mag(sign, m, exp)
	bigint_free(m)
	return d


# The coefficient as a non-negative bigint.
bigint* decimal_coeff(decimal* d):
	return bigint_parse(d.digits, 10)


bigint* decimal_pow10(int e):
	bigint* ten = bigint_from_int(10)
	bigint* r = bigint_pow(ten, e)
	bigint_free(ten)
	return r


# m * 10**e for e >= 0 (new bigint).
bigint* decimal_shift_up(bigint* m, int e):
	if (e <= 0): return bigint_copy(m)
	bigint* p = decimal_pow10(e)
	bigint* r = bigint_mul(m, p)
	bigint_free(p)
	return r


# ---- predicates -------------------------------------------------------------

int decimal_is_nan(decimal* d):
	return (d.kind == DECIMAL_QNAN) || (d.kind == DECIMAL_SNAN)


int decimal_is_qnan(decimal* d):
	return d.kind == DECIMAL_QNAN


int decimal_is_snan(decimal* d):
	return d.kind == DECIMAL_SNAN


int decimal_is_infinite(decimal* d):
	return d.kind == DECIMAL_INF


int decimal_is_finite(decimal* d):
	return d.kind == DECIMAL_FINITE


int decimal_is_special(decimal* d):
	return d.kind != DECIMAL_FINITE


int decimal_is_zero(decimal* d):
	return (d.kind == DECIMAL_FINITE) && (d.digits[0] == '0')


int decimal_is_signed(decimal* d):
	return d.sign


# Python bool(d): NaNs and infinities are non-zero.
int decimal_nonzero(decimal* d):
	return (d.kind != DECIMAL_FINITE) || (d.digits[0] != '0')


# Exponent of the most significant digit (0 for specials).
int decimal_adjusted(decimal* d):
	if (d.kind != DECIMAL_FINITE): return 0
	return d.exp + d.len - 1


int decimal_exponent(decimal* d):
	return d.exp


int decimal_is_normal(decimal* d, decimal_context* ctx):
	if ((d.kind != DECIMAL_FINITE) || (decimal_is_zero(d) != 0)): return 0
	return ctx.emin <= decimal_adjusted(d)


int decimal_is_subnormal(decimal* d, decimal_context* ctx):
	if ((d.kind != DECIMAL_FINITE) || (decimal_is_zero(d) != 0)): return 0
	return decimal_adjusted(d) < ctx.emin


# 0 if a NaN, 1 if quiet NaN, 2 if signaling (like _pydecimal's _isnan).
int decimal_nan_kind(decimal* d):
	if (d.kind == DECIMAL_QNAN): return 1
	if (d.kind == DECIMAL_SNAN): return 2
	return 0


# 1 for +Infinity, -1 for -Infinity, else 0.
int decimal_inf_sign(decimal* d):
	if (d.kind != DECIMAL_INF): return 0
	if (d.sign != 0): return 0 - 1
	return 1


# ---- formatting -------------------------------------------------------------

# Python str(d) (eng == 0) or d.to_eng_string() (eng == 1), with capital E.
char* decimal_format(decimal* d, int eng):
	char* sgn = c""
	if (d.sign != 0): sgn = c"-"
	int sl = strlen(sgn)
	if (d.kind != DECIMAL_FINITE):
		char* word = c"Infinity"
		if (d.kind == DECIMAL_QNAN): word = c"NaN"
		if (d.kind == DECIMAL_SNAN): word = c"sNaN"
		int wl = strlen(word)
		int pl = 0
		if (d.kind != DECIMAL_INF): pl = d.len
		char* r = decimal_str_alloc(sl + wl + pl)
		if (sl > 0): r[0] = '-'
		decimal_copy_chars(&r[sl], word, wl)
		if (pl > 0): decimal_copy_chars(&r[sl + wl], d.digits, pl)
		return r
	int n = d.len
	int leftdigits = d.exp + n
	int dotplace = 1
	if ((d.exp <= 0) && (leftdigits > 0 - 6)):
		dotplace = leftdigits
	else if (eng == 0):
		dotplace = 1
	else if (d.digits[0] == '0'):
		dotplace = (leftdigits + 1) % 3
		if (dotplace < 0): dotplace = dotplace + 3
		dotplace = dotplace - 1
	else:
		dotplace = (leftdigits - 1) % 3
		if (dotplace < 0): dotplace = dotplace + 3
		dotplace = dotplace + 1
	# Worst case: sign, "0." + -dotplace zeros + digits, or digits padded
	# to dotplace, plus "E+" and an exponent of at most 11 characters.
	int extra = 0
	if (dotplace < 0): extra = 0 - dotplace
	if (dotplace > n): extra = dotplace - n
	char* r2 = decimal_str_alloc(sl + n + extra + 20)
	int o = 0
	if (sl > 0):
		r2[0] = '-'
		o = 1
	int i = 0
	if (dotplace <= 0):
		r2[o] = '0'
		r2[o + 1] = '.'
		o = o + 2
		i = 0
		while (i < 0 - dotplace):
			r2[o] = '0'
			o = o + 1
			i = i + 1
		decimal_copy_chars(&r2[o], d.digits, n)
		o = o + n
	else if (dotplace >= n):
		decimal_copy_chars(&r2[o], d.digits, n)
		o = o + n
		i = 0
		while (i < dotplace - n):
			r2[o] = '0'
			o = o + 1
			i = i + 1
	else:
		decimal_copy_chars(&r2[o], d.digits, dotplace)
		o = o + dotplace
		r2[o] = '.'
		o = o + 1
		decimal_copy_chars(&r2[o], &d.digits[dotplace], n - dotplace)
		o = o + n - dotplace
	if (leftdigits != dotplace):
		int e = leftdigits - dotplace
		r2[o] = 'E'
		o = o + 1
		if (e < 0):
			r2[o] = '-'
			e = 0 - e
		else:
			r2[o] = '+'
		o = o + 1
		char* es = itoa(e)
		int el = strlen(es)
		decimal_copy_chars(&r2[o], es, el)
		o = o + el
		free(es)
	r2[o] = 0
	return r2


# Python str(d) / Context.to_sci_string.
char* decimal_to_string(decimal* d):
	return decimal_format(d, 0)


# Python d.to_eng_string().
char* decimal_to_eng_string(decimal* d):
	return decimal_format(d, 1)


# ---- parsing ----------------------------------------------------------------

int decimal_is_space(char c):
	return (c == ' ') || (c == '\t') || (c == '\n') || (c == '\r') || (c == 11) || (c == 12)


int decimal_is_digit(char c):
	return (c >= '0') && (c <= '9')


char decimal_lower(char c):
	if ((c >= 'A') && (c <= 'Z')): return c + 32
	return c


# Case-insensitive equality of s[0 .. n) and the lowercase word w.
int decimal_word_eq(char* s, int n, char* w):
	if (strlen(w) != n): return 0
	int i = 0
	while (i < n):
		if (decimal_lower(s[i]) != w[i]): return 0
		i = i + 1
	return 1


# Python Decimal(s): exact (no rounding). Accepts surrounding whitespace,
# underscores anywhere (CPython's C implementation removes them all),
# "Inf"/"Infinity", "NaN"/"sNaN" with an optional digit payload, all case
# insensitive. Null on a syntax error or an exponent beyond
# DECIMAL_MAX_EXP.
decimal* decimal_parse(char* s):
	int end = strlen(s)
	int i = 0
	while ((i < end) && (decimal_is_space(s[i]) != 0)): i = i + 1
	while ((end > i) && (decimal_is_space(s[end - 1]) != 0)): end = end - 1
	char* buf = decimal_str_alloc(end - i)
	int n = 0
	while (i < end):
		if (s[i] != '_'):
			buf[n] = s[i]
			n = n + 1
		i = i + 1
	buf[n] = 0
	decimal* r = decimal_parse_clean(buf, n)
	free(buf)
	return r


decimal* decimal_parse_clean(char* s, int n):
	int i = 0
	int sign = 0
	if ((i < n) && ((s[i] == '+') || (s[i] == '-'))):
		if (s[i] == '-'): sign = 1
		i = i + 1
	if ((decimal_word_eq(&s[i], n - i, c"inf") != 0) || (decimal_word_eq(&s[i], n - i, c"infinity") != 0)):
		return decimal_infinity(sign)
	int kind = DECIMAL_FINITE
	if ((n - i >= 3) && (decimal_word_eq(&s[i], 3, c"nan") != 0)):
		kind = DECIMAL_QNAN
		i = i + 3
	else if ((n - i >= 4) && (decimal_word_eq(&s[i], 4, c"snan") != 0)):
		kind = DECIMAL_SNAN
		i = i + 4
	if (kind != DECIMAL_FINITE):
		int j = i
		while (j < n):
			if (decimal_is_digit(s[j]) == 0): return 0
			j = j + 1
		return decimal_make(sign, decimal_str_dup(&s[i], n - i), 0, kind)
	char* coeff = decimal_str_alloc(n)
	int cl = 0
	int intd = 0
	while ((i < n) && (decimal_is_digit(s[i]) != 0)):
		coeff[cl] = s[i]
		cl = cl + 1
		intd = intd + 1
		i = i + 1
	int fracd = 0
	if ((i < n) && (s[i] == '.')):
		i = i + 1
		while ((i < n) && (decimal_is_digit(s[i]) != 0)):
			coeff[cl] = s[i]
			cl = cl + 1
			fracd = fracd + 1
			i = i + 1
	coeff[cl] = 0
	int ok = 1
	if (intd + fracd == 0): ok = 0
	int e = 0
	if ((ok != 0) && (i < n) && ((s[i] == 'e') || (s[i] == 'E'))):
		i = i + 1
		int eneg = 0
		if ((i < n) && ((s[i] == '+') || (s[i] == '-'))):
			if (s[i] == '-'): eneg = 1
			i = i + 1
		int ed = 0
		while ((i < n) && (decimal_is_digit(s[i]) != 0)):
			if (e <= DECIMAL_MAX_EXP): e = e * 10 + (s[i] - '0')
			ed = ed + 1
			i = i + 1
		if ((ed == 0) || (e > DECIMAL_MAX_EXP)): ok = 0
		if (eneg != 0): e = 0 - e
	if (i != n): ok = 0
	if ((ok != 0) && (e - fracd < 0 - DECIMAL_MAX_EXP)): ok = 0
	if (ok == 0):
		free(coeff)
		return 0
	return decimal_make(sign, coeff, e - fracd, DECIMAL_FINITE)


# ---- rounding core ----------------------------------------------------------

# For finite non-zero d and 0 <= pos <= len (keeping digits [0, pos)):
# 1 to round the kept part up (away from zero), 0 when every dropped digit
# is zero, -1 to truncate dropping non-zero digits (_pydecimal's
# _round_* functions).
int decimal_round_decision(decimal* d, int pos, int rounding):
	char* s = d.digits
	int down = 0 - 1
	if (decimal_all_zeros(s, pos) != 0): down = 0
	if (rounding == DECIMAL_ROUND_DOWN): return down
	if (rounding == DECIMAL_ROUND_UP): return 0 - down
	if (rounding == DECIMAL_ROUND_CEILING):
		if (d.sign != 0): return down
		return 0 - down
	if (rounding == DECIMAL_ROUND_FLOOR):
		if (d.sign == 0): return down
		return 0 - down
	if (rounding == DECIMAL_ROUND_05UP):
		if ((pos > 0) && (s[pos - 1] != '0') && (s[pos - 1] != '5')): return down
		return 0 - down
	if (rounding == DECIMAL_ROUND_HALF_DOWN):
		if (decimal_exact_half(s, pos) != 0): return 0 - 1
	if (rounding == DECIMAL_ROUND_HALF_EVEN):
		if (decimal_exact_half(s, pos) != 0):
			if (pos == 0): return 0 - 1
			if (((s[pos - 1] - '0') % 2) == 0): return 0 - 1
	# HALF_UP, and the non-tie cases of HALF_DOWN / HALF_EVEN.
	if ((s[pos] >= '5') && (s[pos] <= '9')): return 1
	return down


# Python Overflow.handle: Infinity or the largest finite value, by rounding.
decimal* decimal_overflow(decimal_context* ctx, int sign):
	decimal_raise(ctx, DECIMAL_OVERFLOW)
	int r = ctx.rounding
	int to_inf = 0
	if ((r == DECIMAL_ROUND_HALF_UP) || (r == DECIMAL_ROUND_HALF_EVEN)): to_inf = 1
	if ((r == DECIMAL_ROUND_HALF_DOWN) || (r == DECIMAL_ROUND_UP)): to_inf = 1
	if ((sign == 0) && (r == DECIMAL_ROUND_CEILING)): to_inf = 1
	if ((sign != 0) && (r == DECIMAL_ROUND_FLOOR)): to_inf = 1
	if (to_inf != 0): return decimal_infinity(sign)
	char* nines = decimal_str_alloc(ctx.prec)
	int i = 0
	while (i < ctx.prec):
		nines[i] = '9'
		i = i + 1
	return decimal_make(sign, nines, ctx.emax - ctx.prec + 1, DECIMAL_FINITE)


# Trims a NaN payload to fit the context (_fix_nan).
decimal* decimal_fix_nan(decimal* d, decimal_context* ctx):
	int maxlen = ctx.prec - ctx.clamp
	if (d.len > maxlen):
		return decimal_make(d.sign, decimal_str_dup(&d.digits[d.len - maxlen], maxlen), 0, d.kind)
	return decimal_copy(d)


# Rounds d to the context's precision and exponent range (_fix).
decimal* decimal_fix(decimal* d, decimal_context* ctx):
	if (d.kind != DECIMAL_FINITE):
		if (decimal_is_nan(d) != 0): return decimal_fix_nan(d, ctx)
		return decimal_copy(d)
	int etiny = decimal_etiny(ctx)
	int etop = decimal_etop(ctx)
	if (decimal_is_zero(d) != 0):
		int exp_max = ctx.emax
		if (ctx.clamp != 0): exp_max = etop
		int ne = d.exp
		if (ne < etiny): ne = etiny
		if (ne > exp_max): ne = exp_max
		if (ne != d.exp):
			decimal_raise(ctx, DECIMAL_CLAMPED)
			return decimal_triple(d.sign, c"0", 1, ne)
		return decimal_copy(d)
	int exp_min = d.len + d.exp - ctx.prec
	if (exp_min > etop):
		decimal* ov = decimal_overflow(ctx, d.sign)
		decimal_raise(ctx, DECIMAL_INEXACT | DECIMAL_ROUNDED)
		return ov
	int subnormal = exp_min < etiny
	if (subnormal != 0): exp_min = etiny
	if (d.exp < exp_min):
		int keep = d.len + d.exp - exp_min
		decimal* w = d
		decimal* tmp = 0
		if (keep < 0):
			tmp = decimal_triple(d.sign, c"1", 1, exp_min - 1)
			w = tmp
			keep = 0
		int changed = decimal_round_decision(w, keep, ctx.rounding)
		char* coeff = 0
		if (keep == 0): coeff = decimal_str_dup(c"0", 1)
		else: coeff = decimal_str_dup(w.digits, keep)
		if (changed > 0):
			char* inc = decimal_str_incr(coeff, strlen(coeff))
			free(coeff)
			coeff = inc
			int cl = strlen(coeff)
			if (cl > ctx.prec):
				coeff[cl - 1] = 0
				exp_min = exp_min + 1
		decimal_free(tmp)
		decimal* ans = 0
		if (exp_min > etop):
			free(coeff)
			ans = decimal_overflow(ctx, d.sign)
		else:
			ans = decimal_make(d.sign, coeff, exp_min, DECIMAL_FINITE)
		if ((changed != 0) && (subnormal != 0)): decimal_raise(ctx, DECIMAL_UNDERFLOW)
		if (subnormal != 0): decimal_raise(ctx, DECIMAL_SUBNORMAL)
		if (changed != 0): decimal_raise(ctx, DECIMAL_INEXACT)
		decimal_raise(ctx, DECIMAL_ROUNDED)
		if (decimal_is_zero(ans) != 0): decimal_raise(ctx, DECIMAL_CLAMPED)
		return ans
	if (subnormal != 0): decimal_raise(ctx, DECIMAL_SUBNORMAL)
	if ((ctx.clamp == 1) && (d.exp > etop)):
		decimal_raise(ctx, DECIMAL_CLAMPED)
		return decimal_make(d.sign, decimal_str_pad(d.digits, d.len, d.exp - etop), etop, DECIMAL_FINITE)
	return decimal_copy(d)


# Takes ownership of d and returns it fitted to the context.
decimal* decimal_fix_owned(decimal* d, decimal_context* ctx):
	decimal* r = decimal_fix(d, ctx)
	decimal_free(d)
	return r


# Quietly rescales finite d to exponent exp with the given rounding
# (_rescale); specials are copied.
decimal* decimal_rescale(decimal* d, int exp, int rounding):
	if (d.kind != DECIMAL_FINITE): return decimal_copy(d)
	if (decimal_is_zero(d) != 0): return decimal_triple(d.sign, c"0", 1, exp)
	if (d.exp >= exp):
		return decimal_make(d.sign, decimal_str_pad(d.digits, d.len, d.exp - exp), exp, DECIMAL_FINITE)
	int keep = d.len + d.exp - exp
	decimal* w = d
	decimal* tmp = 0
	if (keep < 0):
		tmp = decimal_triple(d.sign, c"1", 1, exp - 1)
		w = tmp
		keep = 0
	int changed = decimal_round_decision(w, keep, rounding)
	char* coeff = 0
	if (keep == 0): coeff = decimal_str_dup(c"0", 1)
	else: coeff = decimal_str_dup(w.digits, keep)
	if (changed == 1):
		char* inc = decimal_str_incr(coeff, strlen(coeff))
		free(coeff)
		coeff = inc
	decimal_free(tmp)
	return decimal_make(d.sign, coeff, exp, DECIMAL_FINITE)


# ---- NaN handling -----------------------------------------------------------

# InvalidOperation: sets the flag and returns a quiet NaN (carrying the
# sign and payload of src when src is non-null).
decimal* decimal_invalid(decimal_context* ctx, decimal* src):
	decimal_raise(ctx, DECIMAL_INVALID_OPERATION)
	if (src == 0): return decimal_nan()
	decimal* q = decimal_make(src.sign, decimal_str_dup(src.digits, src.len), 0, DECIMAL_QNAN)
	return decimal_fix_owned(q, ctx)


# _check_nans: the NaN result of an operation with NaN operand(s), or null
# when neither operand is a NaN. b may be null.
decimal* decimal_check_nans(decimal* a, decimal* b, decimal_context* ctx):
	int an = decimal_nan_kind(a)
	int bn = 0
	if (b != 0): bn = decimal_nan_kind(b)
	if ((an == 0) && (bn == 0)): return 0
	if (an == 2): return decimal_invalid(ctx, a)
	if (bn == 2): return decimal_invalid(ctx, b)
	if (an != 0): return decimal_fix_nan(a, ctx)
	return decimal_fix_nan(b, ctx)


# ---- comparison -------------------------------------------------------------

# Numeric comparison of two non-NaN values (_cmp): -1, 0 or 1.
int decimal_cmp_raw(decimal* a, decimal* b):
	if ((a.kind != DECIMAL_FINITE) || (b.kind != DECIMAL_FINITE)):
		int ai = decimal_inf_sign(a)
		int bi = decimal_inf_sign(b)
		if (ai == bi): return 0
		if (ai < bi): return 0 - 1
		return 1
	int az = decimal_is_zero(a)
	int bz = decimal_is_zero(b)
	if (az != 0):
		if (bz != 0): return 0
		if (b.sign != 0): return 1
		return 0 - 1
	int s = 1
	if (a.sign != 0): s = 0 - 1
	if (bz != 0): return s
	if (b.sign < a.sign): return 0 - 1
	if (a.sign < b.sign): return 1
	int aa = decimal_adjusted(a)
	int ba = decimal_adjusted(b)
	if (aa > ba): return s
	if (aa < ba): return 0 - s
	# Same adjusted exponent: compare digit by digit, treating missing
	# trailing digits as zeros.
	int n = a.len
	if (b.len > n): n = b.len
	int i = 0
	while (i < n):
		char ca = '0'
		char cb = '0'
		if (i < a.len): ca = a.digits[i]
		if (i < b.len): cb = b.digits[i]
		if (ca < cb): return 0 - s
		if (ca > cb): return s
		i = i + 1
	return 0


# Quiet ordering: -1, 0 or 1, or DECIMAL_UNORDERED when either is a NaN.
# Sets no flags (Python's == semantics; use decimal_compare for the
# spec's compare operation).
int decimal_cmp(decimal* a, decimal* b):
	if ((decimal_is_nan(a) != 0) || (decimal_is_nan(b) != 0)): return DECIMAL_UNORDERED
	return decimal_cmp_raw(a, b)


# Python a == b (quiet NaNs compare unequal; -0 == 0).
int decimal_eq(decimal* a, decimal* b):
	return decimal_cmp(a, b) == 0


# Python a.compare(b): Decimal -1, 0 or 1; NaN when either is a NaN.
decimal* decimal_compare(decimal* a, decimal* b, decimal_context* ctx):
	decimal* n = decimal_check_nans(a, b, ctx)
	if (n != 0): return n
	return decimal_from_int(decimal_cmp_raw(a, b))


# Python a.compare_total(b) as an int: a total order on representations
# (-NaN < -sNaN < -Inf < ... < -0 < 0 < ... < Inf < sNaN < NaN, ties
# broken by exponent).
int decimal_compare_total(decimal* a, decimal* b):
	if ((a.sign != 0) && (b.sign == 0)): return 0 - 1
	if ((a.sign == 0) && (b.sign != 0)): return 1
	int s = 1
	if (a.sign != 0): s = 0 - 1
	int an = decimal_nan_kind(a)
	int bn = decimal_nan_kind(b)
	if ((an != 0) || (bn != 0)):
		if (an == bn):
			int c = 0
			if (a.len < b.len): c = 0 - 1
			else if (a.len > b.len): c = 1
			else:
				int r = strcmp(a.digits, b.digits)
				if (r < 0): c = 0 - 1
				if (r > 0): c = 1
			return c * s
		if (an == 1): return s
		if (bn == 1): return 0 - s
		if (an == 2): return s
		return 0 - s
	int c2 = decimal_cmp_raw(a, b)
	if (c2 != 0): return c2
	if (a.exp < b.exp): return 0 - s
	if (a.exp > b.exp): return s
	return 0


# Python max(a, b) / min(a, b) under the spec (a quiet NaN loses to a
# number). want = 1 for max, -1 for min.
decimal* decimal_maxmin(decimal* a, decimal* b, int want, decimal_context* ctx):
	if ((a.kind != DECIMAL_FINITE) || (b.kind != DECIMAL_FINITE)):
		int sn = decimal_nan_kind(a)
		int on = decimal_nan_kind(b)
		if ((sn != 0) || (on != 0)):
			if ((on == 1) && (sn == 0)): return decimal_fix(a, ctx)
			if ((sn == 1) && (on == 0)): return decimal_fix(b, ctx)
			return decimal_check_nans(a, b, ctx)
	int c = decimal_cmp_raw(a, b)
	if (c == 0): c = decimal_compare_total(a, b)
	if (want > 0):
		if (c == 0 - 1): return decimal_fix(b, ctx)
		return decimal_fix(a, ctx)
	if (c == 0 - 1): return decimal_fix(a, ctx)
	return decimal_fix(b, ctx)


decimal* decimal_max(decimal* a, decimal* b, decimal_context* ctx):
	return decimal_maxmin(a, b, 1, ctx)


decimal* decimal_min(decimal* a, decimal* b, decimal_context* ctx):
	return decimal_maxmin(a, b, 0 - 1, ctx)


# ---- sign operations --------------------------------------------------------

# Quiet copies (no rounding, no NaN signalling).
decimal* decimal_copy_abs(decimal* a):
	decimal* r = decimal_copy(a)
	r.sign = 0
	return r


decimal* decimal_copy_negate(decimal* a):
	decimal* r = decimal_copy(a)
	r.sign = 1 - r.sign
	return r


# Python +a (rounds to the context; +(-0) is 0 except under ROUND_FLOOR).
decimal* decimal_plus(decimal* a, decimal_context* ctx):
	if (a.kind != DECIMAL_FINITE):
		decimal* n = decimal_check_nans(a, 0, ctx)
		if (n != 0): return n
	if ((decimal_is_zero(a) != 0) && (ctx.rounding != DECIMAL_ROUND_FLOOR)):
		return decimal_fix_owned(decimal_copy_abs(a), ctx)
	return decimal_fix(a, ctx)


# Python -a.
decimal* decimal_minus(decimal* a, decimal_context* ctx):
	if (a.kind != DECIMAL_FINITE):
		decimal* n = decimal_check_nans(a, 0, ctx)
		if (n != 0): return n
	if ((decimal_is_zero(a) != 0) && (ctx.rounding != DECIMAL_ROUND_FLOOR)):
		return decimal_fix_owned(decimal_copy_abs(a), ctx)
	return decimal_fix_owned(decimal_copy_negate(a), ctx)


# Python abs(a).
decimal* decimal_abs(decimal* a, decimal_context* ctx):
	if (a.kind != DECIMAL_FINITE):
		decimal* n = decimal_check_nans(a, 0, ctx)
		if (n != 0): return n
	if (a.sign != 0): return decimal_minus(a, ctx)
	return decimal_plus(a, ctx)


# Python Context.create_decimal(s): parses s and rounds it to ctx. Unlike
# decimal_parse, surrounding whitespace and underscores are not allowed. A
# syntax error (or a NaN payload longer than prec - clamp) gives NaN with
# DECIMAL_INVALID_OPERATION; never null.
decimal* decimal_context_create(decimal_context* ctx, char* s):
	decimal* d = decimal_parse_clean(s, strlen(s))
	if (d == 0): return decimal_invalid(ctx, 0)
	if ((decimal_is_nan(d) != 0) && (d.len > ctx.prec - ctx.clamp)):
		decimal_free(d)
		return decimal_invalid(ctx, 0)
	return decimal_fix_owned(d, ctx)


# ---- addition ---------------------------------------------------------------

# a + b where b's sign is replaced by bsign (so subtraction passes the
# flipped sign without copying).
decimal* decimal_add_signed(decimal* a, decimal* b, int bsign, decimal_context* ctx):
	if ((a.kind != DECIMAL_FINITE) || (b.kind != DECIMAL_FINITE)):
		decimal* n = decimal_check_nans(a, b, ctx)
		if (n != 0): return n
		if (a.kind == DECIMAL_INF):
			if ((a.sign != bsign) && (b.kind == DECIMAL_INF)): return decimal_invalid(ctx, 0)
			return decimal_copy(a)
		if (b.kind == DECIMAL_INF): return decimal_infinity(bsign)
	int exp = a.exp
	if (b.exp < exp): exp = b.exp
	int negativezero = 0
	if ((ctx.rounding == DECIMAL_ROUND_FLOOR) && (a.sign != bsign)): negativezero = 1
	int az = decimal_is_zero(a)
	int bz = decimal_is_zero(b)
	if ((az != 0) && (bz != 0)):
		int sign = a.sign
		if (bsign < sign): sign = bsign
		if (negativezero != 0): sign = 1
		return decimal_fix_owned(decimal_triple(sign, c"0", 1, exp), ctx)
	if (az != 0):
		int e1 = b.exp - ctx.prec - 1
		if (e1 < exp): e1 = exp
		decimal* r1 = decimal_rescale(b, e1, ctx.rounding)
		r1.sign = bsign
		return decimal_fix_owned(r1, ctx)
	if (bz != 0):
		int e2 = a.exp - ctx.prec - 1
		if (e2 < exp): e2 = exp
		return decimal_fix_owned(decimal_rescale(a, e2, ctx.rounding), ctx)
	# _normalize: align exponents, replacing a far smaller operand by a
	# single unit just below the rounding position.
	bigint* ai = decimal_coeff(a)
	bigint* bi = decimal_coeff(b)
	int ae = a.exp
	int be = b.exp
	if (ae < be):
		# b is "tmp", a is "other".
		int lim = b.len - ctx.prec - 2
		if (lim > 0 - 1): lim = 0 - 1
		int ex = be + lim
		if (a.len + ae - 1 < ex):
			bigint_free(ai)
			ai = bigint_from_int(1)
			ae = ex
		bigint* t = decimal_shift_up(bi, be - ae)
		bigint_free(bi)
		bi = t
		be = ae
	else:
		int lim2 = a.len - ctx.prec - 2
		if (lim2 > 0 - 1): lim2 = 0 - 1
		int ex2 = ae + lim2
		if (b.len + be - 1 < ex2):
			bigint_free(bi)
			bi = bigint_from_int(1)
			be = ex2
		bigint* t2 = decimal_shift_up(ai, ae - be)
		bigint_free(ai)
		ai = t2
		ae = be
	decimal* ans = 0
	if (a.sign != bsign):
		int c = bigint_cmp(ai, bi)
		if (c == 0):
			ans = decimal_triple(negativezero, c"0", 1, exp)
		else if (c > 0):
			bigint* d1 = bigint_sub(ai, bi)
			ans = decimal_from_mag(a.sign, d1, ae)
			bigint_free(d1)
		else:
			bigint* d2 = bigint_sub(bi, ai)
			ans = decimal_from_mag(bsign, d2, ae)
			bigint_free(d2)
	else:
		bigint* s = bigint_add(ai, bi)
		ans = decimal_from_mag(a.sign, s, ae)
		bigint_free(s)
	bigint_free(ai)
	bigint_free(bi)
	return decimal_fix_owned(ans, ctx)


decimal* decimal_add(decimal* a, decimal* b, decimal_context* ctx):
	return decimal_add_signed(a, b, b.sign, ctx)


decimal* decimal_sub(decimal* a, decimal* b, decimal_context* ctx):
	if ((a.kind != DECIMAL_FINITE) || (b.kind != DECIMAL_FINITE)):
		decimal* n = decimal_check_nans(a, b, ctx)
		if (n != 0): return n
	return decimal_add_signed(a, b, 1 - b.sign, ctx)


# ---- multiplication and division --------------------------------------------

decimal* decimal_mul(decimal* a, decimal* b, decimal_context* ctx):
	int sign = a.sign ^ b.sign
	if ((a.kind != DECIMAL_FINITE) || (b.kind != DECIMAL_FINITE)):
		decimal* n = decimal_check_nans(a, b, ctx)
		if (n != 0): return n
		if (a.kind == DECIMAL_INF):
			if (decimal_nonzero(b) == 0): return decimal_invalid(ctx, 0)
			return decimal_infinity(sign)
		if (b.kind == DECIMAL_INF):
			if (decimal_nonzero(a) == 0): return decimal_invalid(ctx, 0)
			return decimal_infinity(sign)
	int exp = a.exp + b.exp
	if ((decimal_is_zero(a) != 0) || (decimal_is_zero(b) != 0)):
		return decimal_fix_owned(decimal_triple(sign, c"0", 1, exp), ctx)
	bigint* x = decimal_coeff(a)
	bigint* y = decimal_coeff(b)
	bigint* p = bigint_mul(x, y)
	decimal* r = decimal_from_mag(sign, p, exp)
	bigint_free(x)
	bigint_free(y)
	bigint_free(p)
	return decimal_fix_owned(r, ctx)


# Python a / b.
decimal* decimal_div(decimal* a, decimal* b, decimal_context* ctx):
	int sign = a.sign ^ b.sign
	if ((a.kind != DECIMAL_FINITE) || (b.kind != DECIMAL_FINITE)):
		decimal* n = decimal_check_nans(a, b, ctx)
		if (n != 0): return n
		if ((a.kind == DECIMAL_INF) && (b.kind == DECIMAL_INF)): return decimal_invalid(ctx, 0)
		if (a.kind == DECIMAL_INF): return decimal_infinity(sign)
		decimal_raise(ctx, DECIMAL_CLAMPED)
		return decimal_triple(sign, c"0", 1, decimal_etiny(ctx))
	if (decimal_is_zero(b) != 0):
		if (decimal_is_zero(a) != 0): return decimal_invalid(ctx, 0)
		decimal_raise(ctx, DECIMAL_DIVISION_BY_ZERO)
		return decimal_infinity(sign)
	if (decimal_is_zero(a) != 0):
		return decimal_fix_owned(decimal_triple(sign, c"0", 1, a.exp - b.exp), ctx)
	int shift = b.len - a.len + ctx.prec + 1
	int exp = a.exp - b.exp - shift
	bigint* x = decimal_coeff(a)
	bigint* y = decimal_coeff(b)
	if (shift >= 0):
		bigint* t = decimal_shift_up(x, shift)
		bigint_free(x)
		x = t
	else:
		bigint* t2 = decimal_shift_up(y, 0 - shift)
		bigint_free(y)
		y = t2
	bigint* q = 0
	bigint* rem = 0
	bigint_divmod(x, y, &q, &rem)
	bigint_free(x)
	bigint_free(y)
	decimal* ans = 0
	if (bigint_is_zero(rem) == 0):
		# Inexact: make sure the last digit is not 0 or 5 so the final
		# rounding sees the discarded part as non-zero.
		bigint* five = bigint_from_int(5)
		bigint* m = bigint_mod(q, five)
		if (bigint_is_zero(m) != 0):
			bigint* t3 = bigint_add_int(q, 1)
			bigint_free(q)
			q = t3
		bigint_free(m)
		bigint_free(five)
		ans = decimal_from_mag(sign, q, exp)
	else:
		# Exact: strip trailing zeros toward the ideal exponent.
		ans = decimal_from_mag(sign, q, exp)
		int ideal = a.exp - b.exp
		int n = ans.len
		while ((ans.exp < ideal) && (n > 1) && (ans.digits[n - 1] == '0')):
			n = n - 1
			ans.exp = ans.exp + 1
		ans.digits[n] = 0
		ans.len = n
	bigint_free(q)
	bigint_free(rem)
	return decimal_fix_owned(ans, ctx)


# _divide: for finite a, non-zero b (a not infinite; b may be infinite):
# *q = a // b (truncated) and *r = a % b, both unrounded; or NaN for both
# (DivisionImpossible) when the quotient needs more than prec digits.
void decimal_divide_core(decimal* a, decimal* b, decimal_context* ctx, decimal** qo, decimal** ro):
	int sign = a.sign ^ b.sign
	int ideal = a.exp
	if ((b.kind != DECIMAL_INF) && (b.exp < ideal)): ideal = b.exp
	int expdiff = decimal_adjusted(a) - decimal_adjusted(b)
	if ((decimal_is_zero(a) != 0) || (b.kind == DECIMAL_INF) || (expdiff <= 0 - 2)):
		*qo = decimal_triple(sign, c"0", 1, 0)
		*ro = decimal_rescale(a, ideal, ctx.rounding)
		return
	if (expdiff <= ctx.prec):
		bigint* x = decimal_coeff(a)
		bigint* y = decimal_coeff(b)
		if (a.exp >= b.exp):
			bigint* t = decimal_shift_up(x, a.exp - b.exp)
			bigint_free(x)
			x = t
		else:
			bigint* t2 = decimal_shift_up(y, b.exp - a.exp)
			bigint_free(y)
			y = t2
		bigint* q = 0
		bigint* r = 0
		bigint_divmod(x, y, &q, &r)
		bigint_free(x)
		bigint_free(y)
		bigint* lim = decimal_pow10(ctx.prec)
		int fits = bigint_cmp(q, lim) < 0
		bigint_free(lim)
		if (fits != 0):
			*qo = decimal_from_mag(sign, q, 0)
			*ro = decimal_from_mag(a.sign, r, ideal)
			bigint_free(q)
			bigint_free(r)
			return
		bigint_free(q)
		bigint_free(r)
	*qo = decimal_invalid(ctx, 0)
	*ro = decimal_nan()


# Python divmod(a, b): *q = a // b (truncating toward zero), *r = a % b
# (sign of a). Both results are always set.
void decimal_divmod(decimal* a, decimal* b, decimal** q, decimal** r, decimal_context* ctx):
	decimal* n = decimal_check_nans(a, b, ctx)
	if (n != 0):
		*q = n
		*r = decimal_copy(n)
		return
	int sign = a.sign ^ b.sign
	if (a.kind == DECIMAL_INF):
		if (b.kind == DECIMAL_INF):
			*q = decimal_invalid(ctx, 0)
			*r = decimal_nan()
			return
		*q = decimal_infinity(sign)
		*r = decimal_invalid(ctx, 0)
		return
	if (decimal_is_zero(b) != 0):
		if (decimal_is_zero(a) != 0):
			*q = decimal_invalid(ctx, 0)
			*r = decimal_nan()
			return
		decimal_raise(ctx, DECIMAL_DIVISION_BY_ZERO)
		*q = decimal_infinity(sign)
		*r = decimal_invalid(ctx, 0)
		return
	decimal* qq = 0
	decimal* rr = 0
	decimal_divide_core(a, b, ctx, &qq, &rr)
	*q = qq
	*r = decimal_fix_owned(rr, ctx)


# Python a // b (Context.divide_int): truncates toward zero.
decimal* decimal_divide_int(decimal* a, decimal* b, decimal_context* ctx):
	decimal* n = decimal_check_nans(a, b, ctx)
	if (n != 0): return n
	if (a.kind == DECIMAL_INF):
		if (b.kind == DECIMAL_INF): return decimal_invalid(ctx, 0)
		return decimal_infinity(a.sign ^ b.sign)
	if (decimal_is_zero(b) != 0):
		if (decimal_is_zero(a) == 0):
			decimal_raise(ctx, DECIMAL_DIVISION_BY_ZERO)
			return decimal_infinity(a.sign ^ b.sign)
		return decimal_invalid(ctx, 0)
	decimal* qq = 0
	decimal* rr = 0
	decimal_divide_core(a, b, ctx, &qq, &rr)
	decimal_free(rr)
	return qq


# Python a % b (Context.remainder): the result has a's sign.
decimal* decimal_remainder(decimal* a, decimal* b, decimal_context* ctx):
	decimal* n = decimal_check_nans(a, b, ctx)
	if (n != 0): return n
	if (a.kind == DECIMAL_INF): return decimal_invalid(ctx, 0)
	if (decimal_is_zero(b) != 0): return decimal_invalid(ctx, 0)
	decimal* qq = 0
	decimal* rr = 0
	decimal_divide_core(a, b, ctx, &qq, &rr)
	decimal_free(qq)
	return decimal_fix_owned(rr, ctx)


# Python a.remainder_near(b): a - n*b with n the integer nearest a/b
# (ties to even).
decimal* decimal_remainder_near(decimal* a, decimal* b, decimal_context* ctx):
	decimal* n = decimal_check_nans(a, b, ctx)
	if (n != 0): return n
	if (a.kind == DECIMAL_INF): return decimal_invalid(ctx, 0)
	if (decimal_is_zero(b) != 0): return decimal_invalid(ctx, 0)
	if (b.kind == DECIMAL_INF): return decimal_fix(a, ctx)
	int ideal = a.exp
	if (b.exp < ideal): ideal = b.exp
	if (decimal_is_zero(a) != 0):
		return decimal_fix_owned(decimal_triple(a.sign, c"0", 1, ideal), ctx)
	int expdiff = decimal_adjusted(a) - decimal_adjusted(b)
	if (expdiff >= ctx.prec + 1): return decimal_invalid(ctx, 0)
	if (expdiff <= 0 - 2): return decimal_fix_owned(decimal_rescale(a, ideal, ctx.rounding), ctx)
	bigint* x = decimal_coeff(a)
	bigint* y = decimal_coeff(b)
	if (a.exp >= b.exp):
		bigint* t = decimal_shift_up(x, a.exp - b.exp)
		bigint_free(x)
		x = t
	else:
		bigint* t2 = decimal_shift_up(y, b.exp - a.exp)
		bigint_free(y)
		y = t2
	bigint* q = 0
	bigint* r = 0
	bigint_divmod(x, y, &q, &r)
	bigint_free(x)
	# if 2*r + (q & 1) > y: r -= y, q += 1
	bigint* r2 = bigint_mul_int(r, 2)
	bigint* r2q = bigint_add_int(r2, bigint_is_odd(q))
	if (bigint_cmp(r2q, y) > 0):
		bigint* nr = bigint_sub(r, y)
		bigint_free(r)
		r = nr
		bigint* nq = bigint_add_int(q, 1)
		bigint_free(q)
		q = nq
	bigint_free(r2)
	bigint_free(r2q)
	bigint_free(y)
	bigint* lim = decimal_pow10(ctx.prec)
	int too_big = bigint_cmp(q, lim) >= 0
	bigint_free(lim)
	bigint_free(q)
	if (too_big != 0):
		bigint_free(r)
		return decimal_invalid(ctx, 0)
	int sign = a.sign
	if (bigint_sign(r) < 0):
		sign = 1 - sign
		bigint* ar = bigint_abs(r)
		bigint_free(r)
		r = ar
	decimal* ans = decimal_from_mag(sign, r, ideal)
	bigint_free(r)
	return decimal_fix_owned(ans, ctx)


# ---- quantize, normalize, integral values -----------------------------------

# Python a.quantize(b, rounding): a rounded to b's exponent. rounding < 0
# uses ctx.rounding.
decimal* decimal_quantize_with(decimal* a, decimal* b, int rounding, decimal_context* ctx):
	if (rounding < 0): rounding = ctx.rounding
	if ((a.kind != DECIMAL_FINITE) || (b.kind != DECIMAL_FINITE)):
		decimal* n = decimal_check_nans(a, b, ctx)
		if (n != 0): return n
		if ((a.kind == DECIMAL_INF) && (b.kind == DECIMAL_INF)): return decimal_copy(a)
		return decimal_invalid(ctx, 0)
	if ((b.exp < decimal_etiny(ctx)) || (b.exp > ctx.emax)): return decimal_invalid(ctx, 0)
	if (decimal_is_zero(a) != 0):
		return decimal_fix_owned(decimal_triple(a.sign, c"0", 1, b.exp), ctx)
	int adj = decimal_adjusted(a)
	if (adj > ctx.emax): return decimal_invalid(ctx, 0)
	if (adj - b.exp + 1 > ctx.prec): return decimal_invalid(ctx, 0)
	decimal* ans = decimal_rescale(a, b.exp, rounding)
	if ((decimal_adjusted(ans) > ctx.emax) || (ans.len > ctx.prec)):
		decimal_free(ans)
		return decimal_invalid(ctx, 0)
	if ((decimal_is_zero(ans) == 0) && (decimal_adjusted(ans) < ctx.emin)): decimal_raise(ctx, DECIMAL_SUBNORMAL)
	if (ans.exp > a.exp):
		if (decimal_cmp_raw(ans, a) != 0): decimal_raise(ctx, DECIMAL_INEXACT)
		decimal_raise(ctx, DECIMAL_ROUNDED)
	return decimal_fix_owned(ans, ctx)


decimal* decimal_quantize(decimal* a, decimal* b, decimal_context* ctx):
	return decimal_quantize_with(a, b, 0 - 1, ctx)


# Python round(a, n): a.quantize(Decimal('1E-n')).
decimal* decimal_round_digits(decimal* a, int n, decimal_context* ctx):
	decimal* q = decimal_triple(0, c"1", 1, 0 - n)
	decimal* r = decimal_quantize(a, q, ctx)
	decimal_free(q)
	return r


# Python a.same_quantum(b).
int decimal_same_quantum(decimal* a, decimal* b):
	if ((a.kind != DECIMAL_FINITE) || (b.kind != DECIMAL_FINITE)):
		if ((decimal_is_nan(a) != 0) && (decimal_is_nan(b) != 0)): return 1
		return (a.kind == DECIMAL_INF) && (b.kind == DECIMAL_INF)
	return a.exp == b.exp


# Python a.normalize(): rounds, then strips trailing zeros (zero becomes
# 0E0 with its sign).
decimal* decimal_normalize(decimal* a, decimal_context* ctx):
	if (a.kind != DECIMAL_FINITE):
		decimal* n = decimal_check_nans(a, 0, ctx)
		if (n != 0): return n
	decimal* dup = decimal_fix(a, ctx)
	if (dup.kind == DECIMAL_INF): return dup
	if (decimal_is_zero(dup) != 0):
		decimal* z = decimal_triple(dup.sign, c"0", 1, 0)
		decimal_free(dup)
		return z
	int exp_max = ctx.emax
	if (ctx.clamp != 0): exp_max = decimal_etop(ctx)
	int end = dup.len
	int exp = dup.exp
	while ((dup.digits[end - 1] == '0') && (exp < exp_max)):
		exp = exp + 1
		end = end - 1
	decimal* r = decimal_triple(dup.sign, dup.digits, end, exp)
	decimal_free(dup)
	return r


# Python a.to_integral_value(rounding): rounds to an integer without
# setting Inexact/Rounded. rounding < 0 uses ctx.rounding.
decimal* decimal_to_integral_value(decimal* a, int rounding, decimal_context* ctx):
	if (rounding < 0): rounding = ctx.rounding
	if (a.kind != DECIMAL_FINITE):
		decimal* n = decimal_check_nans(a, 0, ctx)
		if (n != 0): return n
		return decimal_copy(a)
	if (a.exp >= 0): return decimal_copy(a)
	return decimal_rescale(a, 0, rounding)


# Python a.to_integral_exact(rounding): like to_integral_value but sets
# Inexact and Rounded.
decimal* decimal_to_integral_exact(decimal* a, int rounding, decimal_context* ctx):
	if (rounding < 0): rounding = ctx.rounding
	if (a.kind != DECIMAL_FINITE):
		decimal* n = decimal_check_nans(a, 0, ctx)
		if (n != 0): return n
		return decimal_copy(a)
	if (a.exp >= 0): return decimal_copy(a)
	if (decimal_is_zero(a) != 0): return decimal_triple(a.sign, c"0", 1, 0)
	decimal* ans = decimal_rescale(a, 0, rounding)
	if (decimal_cmp_raw(ans, a) != 0): decimal_raise(ctx, DECIMAL_INEXACT)
	decimal_raise(ctx, DECIMAL_ROUNDED)
	return ans


# ---- square root ------------------------------------------------------------

# Python a.sqrt(): correctly rounded (ROUND_HALF_EVEN regardless of the
# context's rounding), with the ideal exponent floor(exp / 2) when exact.
decimal* decimal_sqrt(decimal* a, decimal_context* ctx):
	if (a.kind != DECIMAL_FINITE):
		decimal* n = decimal_check_nans(a, 0, ctx)
		if (n != 0): return n
		if (a.sign == 0): return decimal_copy(a)
	if (decimal_is_zero(a) != 0):
		int ze = a.exp >> 1
		return decimal_fix_owned(decimal_triple(a.sign, c"0", 1, ze), ctx)
	if (a.sign != 0): return decimal_invalid(ctx, 0)
	int prec = ctx.prec + 1
	int e = a.exp >> 1
	bigint* c = decimal_coeff(a)
	int l = 0
	if ((a.exp & 1) != 0):
		bigint* t = bigint_mul_int(c, 10)
		bigint_free(c)
		c = t
		l = (a.len >> 1) + 1
	else:
		l = (a.len + 1) >> 1
	int shift = prec - l
	int exact = 1
	if (shift >= 0):
		bigint* t2 = decimal_shift_up(c, 2 * shift)
		bigint_free(c)
		c = t2
	else:
		bigint* p = decimal_pow10(0 - 2 * shift)
		bigint* q = 0
		bigint* r = 0
		bigint_divmod(c, p, &q, &r)
		exact = bigint_is_zero(r)
		bigint_free(c)
		bigint_free(p)
		bigint_free(r)
		c = q
	e = e - shift
	bigint* nn = bigint_isqrt(c)
	if (exact != 0):
		bigint* sq = bigint_mul(nn, nn)
		exact = bigint_eq(sq, c)
		bigint_free(sq)
	bigint_free(c)
	if (exact != 0):
		if (shift >= 0):
			bigint* p2 = decimal_pow10(shift)
			bigint* q2 = bigint_floordiv(nn, p2)
			bigint_free(p2)
			bigint_free(nn)
			nn = q2
		else:
			bigint* t3 = decimal_shift_up(nn, 0 - shift)
			bigint_free(nn)
			nn = t3
		e = e + shift
	else:
		bigint* five = bigint_from_int(5)
		bigint* m = bigint_mod(nn, five)
		if (bigint_is_zero(m) != 0):
			bigint* t4 = bigint_add_int(nn, 1)
			bigint_free(nn)
			nn = t4
		bigint_free(m)
		bigint_free(five)
	decimal* ans = decimal_from_mag(0, nn, e)
	bigint_free(nn)
	int saved = ctx.rounding
	ctx.rounding = DECIMAL_ROUND_HALF_EVEN
	decimal* r2 = decimal_fix_owned(ans, ctx)
	ctx.rounding = saved
	return r2


# ---- conversion to integers and fractions -----------------------------------

# The integer part toward zero (Python int(a)); null for NaN/Infinity.
bigint* decimal_to_bigint(decimal* a):
	return decimal_to_bigint_rounded(a, DECIMAL_ROUND_DOWN)


# a rounded to an integer with the given rounding mode; null for
# NaN/Infinity. Python round(a) is DECIMAL_ROUND_HALF_EVEN,
# math.floor/ceil are DECIMAL_ROUND_FLOOR/CEILING.
bigint* decimal_to_bigint_rounded(decimal* a, int rounding):
	if (a.kind != DECIMAL_FINITE): return 0
	decimal* r = decimal_rescale(a, 0, rounding)
	bigint* v = decimal_coeff(r)
	if (r.sign != 0):
		bigint* nv = bigint_neg(v)
		bigint_free(v)
		v = nv
	decimal_free(r)
	return v


# Python a.as_integer_ratio(): *num / *den in lowest terms, den > 0.
# Returns 0 (setting nothing) for NaN/Infinity.
int decimal_as_integer_ratio(decimal* a, bigint** num, bigint** den):
	if (a.kind != DECIMAL_FINITE): return 0
	bigint* n = decimal_coeff(a)
	bigint* d = 0
	if (a.exp >= 0):
		bigint* t = decimal_shift_up(n, a.exp)
		bigint_free(n)
		n = t
		d = bigint_from_int(1)
	else:
		d = decimal_pow10(0 - a.exp)
		bigint* g = bigint_gcd(n, d)
		if (bigint_is_zero(g) == 0):
			bigint* n2 = bigint_floordiv(n, g)
			bigint* d2 = bigint_floordiv(d, g)
			bigint_free(n)
			bigint_free(d)
			n = n2
			d = d2
		bigint_free(g)
		if (bigint_is_zero(n) != 0):
			bigint_free(d)
			d = bigint_from_int(1)
	if (a.sign != 0):
		bigint* nn = bigint_neg(n)
		bigint_free(n)
		n = nn
	*num = n
	*den = d
	return 1
