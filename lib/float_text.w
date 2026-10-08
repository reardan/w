/*
lib.float_text: exact, correctly rounded conversion between IEEE-754
binary floats and decimal text, for float32 (width 32) and float64
(width 64).

Everything works on the raw bit pattern held in an int, so this module
never names float64 and compiles on every target: width 32 needs only
the 32-bit word of x86/wasm (a float32 mantissa has 24 bits), while
width 64 needs the 8-byte word of x64/arm64/win64 (53-bit mantissas)
and is only meaningful there. A float32 pattern may arrive
sign-extended (an int32 load on an 8-byte word); every field extraction
below masks with positive constants, so both spellings decode alike.

The engine is a multiprecision decimal (digits in a byte array, a
decimal-point position, and a sticky flag for nonzero digits dropped
beyond the 800-digit capacity) that is shifted by powers of two -- the
same "slow path" Go's strconv falls back on. Every binary float is a
dyadic rational, so its exact decimal expansion fits the array (a
float64 needs at most 767 significant digits) and both directions are
exact before the single final rounding:

- float_text_parse: decimal text -> bits, rounded to nearest, ties to
  even, overflow to +-inf, gradual underflow through the subnormals
  (strtod semantics). Inputs longer than 800 significant digits keep
  the sticky flag, which is all round-half-even needs to decide.
- float_text_shortest / float_text_shortest_digits: the shortest
  decimal that parses back to the same bits, choosing the nearest such
  decimal when several have the shortest length (the digits Python's
  repr, JavaScript and Ryu print). The walk compares the exact value
  with the exact halfway points to its neighbours, inclusive when the
  mantissa is even (the parser's ties-to-even would then round back).
- float_text_fixed: a fixed number of fraction digits ("%.Nf"),
  correctly rounded from the exact value, ties to even, with no limit
  on the magnitude.

Correctness over speed: a conversion costs O(digits * shifts) byte
operations, microseconds for typical values. lib/format.w (ftoa,
parse_float), lib/float64_format.w (f64toa, parse_float64), the
f-string and print float runtimes and structures/json.w all route
through here. This file is in the compiler's import closure (through
structures/string.w), so it must stay plain W the pinned seed accepts.
*/
import lib.lib


# Digit capacity of a decimal: enough for the exact expansion of every
# float64 (at most 767 significant digits).
int ftx_capacity():
	return 800


# Largest single shift: the accumulators below hold n * 10 + 9 with
# n < 2^k, which must stay below the signed word, so k = bits - 5
# (27 on 4-byte words, 59 on 8-byte words).
int ftx_max_shift():
	return __word_size__ * 8 - 5


struct ftx_decimal:
	char* d      # ASCII digits, most significant first, no trailing zeros
	int nd       # digits used
	int dp       # decimal point: value = 0.d[0..nd) * 10^dp
	int trunc    # nonzero digits were discarded beyond the capacity


ftx_decimal* ftx_new():
	ftx_decimal* a = new ftx_decimal()
	a.d = cast(char*, malloc(ftx_capacity() + 1))
	a.nd = 0
	a.dp = 0
	a.trunc = 0
	return a


void ftx_free(ftx_decimal* a):
	free(a.d)
	free(a)


void ftx_trim(ftx_decimal* a):
	while ((a.nd > 0) && (a.d[a.nd - 1] == '0')): a.nd = a.nd - 1
	if (a.nd == 0): a.dp = 0


# a = v for 0 <= v (a word-sized integer).
void ftx_assign(ftx_decimal* a, int v):
	char* buf = cast(char*, malloc(24))
	int n = 0
	while (v > 0):
		int v1 = v / 10
		buf[n] = '0' + (v - 10 * v1)
		n = n + 1
		v = v1
	a.nd = 0
	a.trunc = 0
	n = n - 1
	while (n >= 0):
		a.d[a.nd] = buf[n]
		a.nd = a.nd + 1
		n = n - 1
	a.dp = a.nd
	free(buf)
	ftx_trim(a)


# a = a / 2^k, 0 < k <= ftx_max_shift(); low digits beyond the
# capacity set trunc.
void ftx_right_shift(ftx_decimal* a, int k):
	int r = 0
	int w = 0
	int n = 0
	# Pick up enough leading digits to cover the first shift.
	int scanning = 1
	while (scanning && ((n >> k) == 0)):
		if (r >= a.nd):
			if (n == 0):
				a.nd = 0
				return
			while ((n >> k) == 0):
				n = n * 10
				r = r + 1
			scanning = 0
		else:
			n = n * 10 + a.d[r] - '0'
			r = r + 1
	a.dp = a.dp - (r - 1)
	int mask = (1 << k) - 1
	# Pick up a digit, put down a digit.
	while (r < a.nd):
		int c = a.d[r]
		int dig = n >> k
		n = n & mask
		a.d[w] = '0' + dig
		w = w + 1
		n = n * 10 + c - '0'
		r = r + 1
	# Put down the extra digits.
	int cap = ftx_capacity()
	while (n > 0):
		int dig = n >> k
		n = n & mask
		if (w < cap):
			a.d[w] = '0' + dig
			w = w + 1
		else if (dig > 0): a.trunc = 1
		n = n * 10
	a.nd = w
	ftx_trim(a)


# a = a * 2^k, 0 < k <= ftx_max_shift(). Every input digit yields one
# output digit and the final carry adds delta leading digits; a dry
# pass sizes delta so the real pass can write right to left in place
# (digit r lands at r + delta, which was already read).
void ftx_left_shift(ftx_decimal* a, int k):
	int n = 0
	int r = a.nd - 1
	while (r >= 0):
		n = n + ((a.d[r] - '0') << k)
		n = n / 10
		r = r - 1
	int delta = 0
	while (n > 0):
		delta = delta + 1
		n = n / 10
	int cap = ftx_capacity()
	n = 0
	r = a.nd - 1
	while (r >= 0):
		n = n + ((a.d[r] - '0') << k)
		int quo = n / 10
		int rem = n - 10 * quo
		if (r + delta < cap): a.d[r + delta] = '0' + rem
		else if (rem != 0): a.trunc = 1
		n = quo
		r = r - 1
	int w = delta - 1
	while (w >= 0):
		int quo = n / 10
		a.d[w] = '0' + (n - 10 * quo)
		n = quo
		w = w - 1
	a.nd = a.nd + delta
	if (a.nd > cap): a.nd = cap
	a.dp = a.dp + delta
	ftx_trim(a)


# a = a * 2^k for any k (negative divides).
void ftx_shift(ftx_decimal* a, int k):
	if (a.nd == 0): return
	int max_shift = ftx_max_shift()
	if (k > 0):
		while (k > max_shift):
			ftx_left_shift(a, max_shift)
			k = k - max_shift
		ftx_left_shift(a, k)
	else if (k < 0):
		while (k < 0 - max_shift):
			ftx_right_shift(a, max_shift)
			k = k + max_shift
		ftx_right_shift(a, 0 - k)


# Whether keeping nd digits should round up: above half, or exactly
# half with an odd last kept digit (ties to even), where any dropped
# nonzero digit (trunc) makes it above half.
int ftx_should_round_up(ftx_decimal* a, int nd):
	if ((nd < 0) || (nd >= a.nd)): return 0
	if ((a.d[nd] == '5') && (nd + 1 == a.nd)):
		if (a.trunc): return 1
		return (nd > 0) && (((a.d[nd - 1] - '0') % 2) == 1)
	return a.d[nd] >= '5'


void ftx_round_down(ftx_decimal* a, int nd):
	if ((nd < 0) || (nd >= a.nd)): return
	a.nd = nd
	ftx_trim(a)


void ftx_round_up(ftx_decimal* a, int nd):
	if ((nd < 0) || (nd >= a.nd)): return
	int i = nd - 1
	while (i >= 0):
		if (a.d[i] < '9'):
			a.d[i] = a.d[i] + 1
			a.nd = i + 1
			return
		i = i - 1
	# all nines: becomes a single 1 one decade up
	a.d[0] = '1'
	a.nd = 1
	a.dp = a.dp + 1


# Round to nd significant digits, ties to even.
void ftx_round(ftx_decimal* a, int nd):
	if ((nd < 0) || (nd >= a.nd)): return
	if (ftx_should_round_up(a, nd)): ftx_round_up(a, nd)
	else: ftx_round_down(a, nd)


# The integer nearest a (ties to even); a must be below 2^62.
int ftx_rounded_integer(ftx_decimal* a):
	int n = 0
	int i = 0
	while ((i < a.dp) && (i < a.nd)):
		n = n * 10 + a.d[i] - '0'
		i = i + 1
	while (i < a.dp):
		n = n * 10
		i = i + 1
	if (ftx_should_round_up(a, a.dp)): n = n + 1
	return n


##### format parameters #####


int ftx_mant_bits(int width):
	if (width == 64): return 52
	return 23


int ftx_exp_bits(int width):
	if (width == 64): return 11
	return 8


int ftx_bias(int width):
	if (width == 64): return -1023
	return -127


int ftx_sign_of(int bits, int width):
	if (width == 64): return (bits >> 63) & 1
	return (bits >> 31) & 1


int ftx_exp_field(int bits, int width):
	if (width == 64): return (bits >> 52) & 0x7ff
	return (bits >> 23) & 0xff


int ftx_frac_field(int bits, int width):
	return bits & ((1 << ftx_mant_bits(width)) - 1)


# 1 when bits is an infinity or a NaN.
int float_text_is_special(int bits, int width):
	return ftx_exp_field(bits, width) == (1 << ftx_exp_bits(width)) - 1


# 0 finite, 1 infinite, 2 NaN.
int ftx_class(int bits, int width):
	if (float_text_is_special(bits, width) == 0): return 0
	if (ftx_frac_field(bits, width) == 0): return 1
	return 2


# Assemble a bit pattern from sign, biased exponent field and fraction.
int ftx_pack(int sign, int exp_field, int frac, int width):
	int mb = ftx_mant_bits(width)
	int bits = (frac & ((1 << mb) - 1)) | (exp_field << mb)
	if (sign):
		if (width == 64): bits = bits | (1 << 63)
		else: bits = bits | (1 << 31)
	return bits


##### decimal -> binary #####


# Binary shift that moves a decimal with decimal-point position dp
# toward [0.5, 1) without overshooting: floor(dp * log2(10)) for small
# dp, a 27-bit step beyond the table.
int ftx_pow_shift(int dp):
	if (dp == 1): return 3
	if (dp == 2): return 6
	if (dp == 3): return 9
	if (dp == 4): return 13
	if (dp == 5): return 16
	if (dp == 6): return 19
	if (dp == 7): return 23
	if (dp == 8): return 26
	if (dp >= 9): return 27
	return 1


# The decimal a (nonnegative) rounded to the nearest float of the
# given width, ties to even, as unsigned bits (no sign). Overflow gives
# the infinity pattern.
int ftx_float_bits(ftx_decimal* a, int width):
	int mb = ftx_mant_bits(width)
	int eb = ftx_exp_bits(width)
	int bias = ftx_bias(width)
	int exp_max = (1 << eb) - 1
	int inf_bits = exp_max << mb
	if (a.nd == 0): return 0
	# Obvious overflow / underflow (bounds sized for float64, which
	# also cover float32).
	if (a.dp > 310): return inf_bits
	if (a.dp < -330): return 0

	# Scale by powers of two into [0.5, 1).
	int exp = 0
	int n = 0
	while (a.dp > 0):
		n = ftx_pow_shift(a.dp)
		ftx_shift(a, 0 - n)
		exp = exp + n
	while ((a.dp < 0) || ((a.dp == 0) && (a.d[0] < '5'))):
		n = ftx_pow_shift(0 - a.dp)
		ftx_shift(a, n)
		exp = exp - n

	# [0.5, 1) to the [1, 2) of an IEEE significand.
	exp = exp - 1

	# Below the smallest normal exponent: denormalize.
	if (exp < bias + 1):
		n = bias + 1 - exp
		ftx_shift(a, 0 - n)
		exp = exp + n

	if (exp - bias >= exp_max): return inf_bits

	# Extract 1 + mantissa bits, rounded.
	ftx_shift(a, 1 + mb)
	int mant = ftx_rounded_integer(a)

	# Rounding may have carried into a new top bit.
	if (mant == (2 << mb)):
		mant = mant >> 1
		exp = exp + 1
		if (exp - bias >= exp_max): return inf_bits

	# Denormal: no implicit bit, exponent field zero.
	if ((mant & (1 << mb)) == 0): exp = bias
	return ftx_pack(0, (exp - bias) & exp_max, mant, width)


int ftx_lower(int c):
	if ((c >= 'A') && (c <= 'Z')): return c + 32
	return c


# Case-insensitive prefix test of word (lowercase) at s.
int ftx_has_word(char* s, char* word):
	int i = 0
	while (word[i] != 0):
		if (ftx_lower(s[i]) != word[i]): return 0
		i = i + 1
	return 1


# Parse the longest decimal float prefix of s, strtod-style:
#   [+-] ( digits [. digits] | . digits ) [(e|E) [+-] digits]
#   [+-] (inf | infinity | nan)            (any letter case)
# No leading whitespace is skipped. Returns the correctly rounded bit
# pattern of the given width (32 or 64): round to nearest, ties to
# even; magnitudes beyond the largest finite value give +-inf, tiny
# ones round through the subnormals to +-0. A NaN is the quiet NaN.
# *consumed (when consumed is nonzero) receives the number of chars
# used: 0 when s does not start with a number (the result is then 0).
# An exponent marker not followed by digits is left unconsumed.
int float_text_parse(char* s, int width, int* consumed):
	int i = 0
	int sign = 0
	if ((s[i] == '+') || (s[i] == '-')):
		if (s[i] == '-'): sign = 1
		i = i + 1
	int mb = ftx_mant_bits(width)
	int exp_max = (1 << ftx_exp_bits(width)) - 1
	if (ftx_has_word(s + i, c"inf")):
		i = i + 3
		if (ftx_has_word(s + i, c"inity")): i = i + 5
		if (consumed): *consumed = i
		return ftx_pack(sign, exp_max, 0, width)
	if (ftx_has_word(s + i, c"nan")):
		if (consumed): *consumed = i + 3
		return ftx_pack(sign, exp_max, 1 << (mb - 1), width)

	ftx_decimal* a = ftx_new()
	int cap = ftx_capacity()
	int saw_digits = 0
	int nsig = 0
	while ((s[i] >= '0') && (s[i] <= '9')):
		saw_digits = 1
		if ((nsig > 0) || (s[i] != '0')):
			if (a.nd < cap):
				a.d[a.nd] = s[i]
				a.nd = a.nd + 1
			else if (s[i] != '0'): a.trunc = 1
			nsig = nsig + 1
			a.dp = a.dp + 1
		i = i + 1
	if (s[i] == '.'):
		int j = i + 1
		while ((s[j] >= '0') && (s[j] <= '9')):
			saw_digits = 1
			if ((nsig > 0) || (s[j] != '0')):
				if (a.nd < cap):
					a.d[a.nd] = s[j]
					a.nd = a.nd + 1
				else if (s[j] != '0'): a.trunc = 1
				nsig = nsig + 1
			else: a.dp = a.dp - 1
			j = j + 1
		if (saw_digits): i = j
	if (saw_digits == 0):
		ftx_free(a)
		if (consumed): *consumed = 0
		return 0
	if ((s[i] == 'e') || (s[i] == 'E')):
		int j = i + 1
		int exp_negative = 0
		if ((s[j] == '+') || (s[j] == '-')):
			if (s[j] == '-'): exp_negative = 1
			j = j + 1
		if ((s[j] >= '0') && (s[j] <= '9')):
			int e = 0
			while ((s[j] >= '0') && (s[j] <= '9')):
				# clamped: far beyond any representable exponent
				if (e < 100000): e = e * 10 + s[j] - '0'
				j = j + 1
			if (exp_negative): e = 0 - e
			a.dp = a.dp + e
			i = j
	if (consumed): *consumed = i
	ftx_trim(a)
	int bits = ftx_float_bits(a, width)
	ftx_free(a)
	if (sign): bits = bits | ftx_pack(1, 0, 0, width)
	return bits


##### binary -> decimal #####


# The exact decimal value of the finite bit pattern's magnitude, with
# its unbiased exponent and full mantissa (implicit bit included) in
# *exp_out / *mant_out.
ftx_decimal* ftx_exact(int bits, int width, int* mant_out, int* exp_out):
	int mb = ftx_mant_bits(width)
	int exp = ftx_exp_field(bits, width)
	int mant = ftx_frac_field(bits, width)
	if (exp == 0): exp = exp + 1
	else: mant = mant | (1 << mb)
	exp = exp + ftx_bias(width)
	ftx_decimal* d = ftx_new()
	ftx_assign(d, mant)
	ftx_shift(d, exp - mb)
	*mant_out = mant
	*exp_out = exp
	return d


# Round the exact decimal d of mant * 2^(exp - mantbits) to the
# shortest digit string that still lies strictly inside (or, for an
# even mantissa, on the boundary of) the interval of decimals that
# parse back to the same float, picking the nearest when there is a
# choice.
void ftx_round_shortest(ftx_decimal* d, int mant, int exp, int width):
	if (mant == 0):
		d.nd = 0
		return
	int mb = ftx_mant_bits(width)
	int minexp = ftx_bias(width) + 1
	# Already shortest: the nearest shorter decimal is at least
	# 10^(dp - nd) away, more than the half-ulp bound 2^(exp - mb).
	if ((exp > minexp) && (332 * (d.dp - d.nd) >= 100 * (exp - mb))): return

	# Upper bound: halfway to the next float up.
	ftx_decimal* upper = ftx_new()
	ftx_assign(upper, mant * 2 + 1)
	ftx_shift(upper, exp - mb - 1)

	# Lower bound: halfway to the next float down, which sits one
	# binade lower (half the spacing) when mant is a power of two above
	# the minimum exponent.
	int mantlo = 0
	int explo = 0
	if ((mant > (1 << mb)) || (exp == minexp)):
		mantlo = mant - 1
		explo = exp
	else:
		mantlo = mant * 2 - 1
		explo = exp - 1
	ftx_decimal* lower = ftx_new()
	ftx_assign(lower, mantlo * 2 + 1)
	ftx_shift(lower, explo - mb - 1)

	# The bounds themselves parse back to this float only when its
	# mantissa is even (ties to even).
	int inclusive = (mant % 2) == 0

	# upperdelta: 0 while d and upper agree, 1 after a difference of
	# exactly one followed only by d's 9s against upper's 0s (rounding
	# up may land on the bound), 2 once rounding up is safely inside.
	int upperdelta = 0
	int ui = 0
	int done = 0
	while (done == 0):
		int mi = ui - upper.dp + d.dp
		if (mi >= d.nd): done = 1
		else:
			int li = ui - upper.dp + lower.dp
			int l = '0'
			if ((li >= 0) && (li < lower.nd)): l = lower.d[li]
			int m = '0'
			if (mi >= 0): m = d.d[mi]
			int u = '0'
			if (ui < upper.nd): u = upper.d[ui]

			# Truncating is fine once lower differs, or lower is
			# inclusive and ends right here.
			int okdown = (l != m) || (inclusive && (li + 1 == lower.nd))

			if ((upperdelta == 0) && (m + 1 < u)): upperdelta = 2
			else if ((upperdelta == 0) && (m != u)): upperdelta = 1
			else if ((upperdelta == 1) && ((m != '9') || (u != '0'))): upperdelta = 2
			int okup = (upperdelta > 0) && (inclusive || (upperdelta > 1) || (ui + 1 < upper.nd))

			if (okdown && okup):
				ftx_round(d, mi + 1)
				done = 1
			else if (okdown):
				ftx_round_down(d, mi + 1)
				done = 1
			else if (okup):
				ftx_round_up(d, mi + 1)
				done = 1
			ui = ui + 1
	ftx_free(upper)
	ftx_free(lower)


# Shortest round-trip digits of the finite pattern's magnitude: writes
# the significant digits (ASCII, no sign, no point, no trailing zeros;
# at most 17 for float64, 9 for float32) to digits, NUL-terminated
# (digits needs 18 bytes), sets *exp10 to the decimal exponent of the
# leading digit (value = d.ddd * 10^exp10), and returns the digit
# count. Zero gives the single digit "0" with exponent 0. Infinities
# and NaNs are the caller's to spell (see float_text_is_special); they
# return 0 digits.
int float_text_shortest_digits(int bits, int width, char* digits, int* exp10):
	*exp10 = 0
	digits[0] = 0
	if (float_text_is_special(bits, width)): return 0
	int mant = 0
	int exp = 0
	ftx_decimal* d = ftx_exact(bits, width, &mant, &exp)
	ftx_round_shortest(d, mant, exp, width)
	int n = d.nd
	if (n == 0):
		digits[0] = '0'
		digits[1] = 0
		ftx_free(d)
		return 1
	int i = 0
	while (i < n):
		digits[i] = d.d[i]
		i = i + 1
	digits[n] = 0
	*exp10 = d.dp - 1
	ftx_free(d)
	return n


# The special spellings: inf, -inf, nan (malloc'd).
char* ftx_special_text(int bits, int width):
	if (ftx_class(bits, width) == 2): return strclone(c"nan")
	if (ftx_sign_of(bits, width)): return strclone(c"-inf")
	return strclone(c"inf")


# Shortest round-trip text of the pattern, spelled like Python's repr:
# plain notation for decimal exponents -4..15 with at least one
# fraction digit ("3.0", "0.1", "123.456", "0.0001"), scientific
# outside it ("1e+20", "1e-07", "1.7976931348623157e+308",
# "5e-324"), a sign on negatives including -0.0, and inf / -inf / nan.
# Parsing the result with float_text_parse at the same width gives the
# same bits back. Returns a malloc'd string.
char* float_text_shortest(int bits, int width):
	if (float_text_is_special(bits, width)): return ftx_special_text(bits, width)
	char* digits = cast(char*, malloc(24))
	int e = 0
	int n = float_text_shortest_digits(bits, width, digits, &e)
	char* s = cast(char*, malloc(n + 32))
	int pos = 0
	if (ftx_sign_of(bits, width)):
		s[pos] = '-'
		pos = pos + 1
	int i = 0
	if ((e < -4) || (e >= 16)):
		s[pos] = digits[0]
		pos = pos + 1
		if (n > 1):
			s[pos] = '.'
			pos = pos + 1
			i = 1
			while (i < n):
				s[pos] = digits[i]
				pos = pos + 1
				i = i + 1
		s[pos] = 'e'
		pos = pos + 1
		int ae = e
		if (e < 0):
			s[pos] = '-'
			ae = 0 - e
		else: s[pos] = '+'
		pos = pos + 1
		if (ae < 10):
			s[pos] = '0'
			pos = pos + 1
		char* exp_digits = itoa(ae)
		i = 0
		while (exp_digits[i] != 0):
			s[pos] = exp_digits[i]
			pos = pos + 1
			i = i + 1
		free(exp_digits)
	else if (e < 0):
		s[pos] = '0'
		s[pos + 1] = '.'
		pos = pos + 2
		i = -1
		while (i > e):
			s[pos] = '0'
			pos = pos + 1
			i = i - 1
		i = 0
		while (i < n):
			s[pos] = digits[i]
			pos = pos + 1
			i = i + 1
	else:
		i = 0
		while (i <= e):
			if (i < n): s[pos] = digits[i]
			else: s[pos] = '0'
			pos = pos + 1
			i = i + 1
		s[pos] = '.'
		pos = pos + 1
		if (n <= e + 1):
			s[pos] = '0'
			pos = pos + 1
		while (i < n):
			s[pos] = digits[i]
			pos = pos + 1
			i = i + 1
	s[pos] = 0
	free(digits)
	return s


# Text with exactly precision fraction digits ("%.Nf"), correctly
# rounded from the exact value (ties to even), for any magnitude:
# a precision of 0 prints no point. Negative values, -0.0 included,
# keep their sign; infinities and NaNs spell inf / -inf / nan.
# Returns a malloc'd string.
char* float_text_fixed(int bits, int width, int precision):
	if (float_text_is_special(bits, width)): return ftx_special_text(bits, width)
	if (precision < 0): precision = 0
	int mant = 0
	int exp = 0
	ftx_decimal* d = ftx_exact(bits, width, &mant, &exp)
	ftx_round(d, d.dp + precision)
	int whole = d.dp
	if (whole < 1): whole = 1
	char* s = cast(char*, malloc(whole + precision + 4))
	int pos = 0
	if (ftx_sign_of(bits, width)):
		s[pos] = '-'
		pos = pos + 1
	if (d.dp > 0):
		int m = 0
		while (m < d.dp):
			if (m < d.nd): s[pos] = d.d[m]
			else: s[pos] = '0'
			pos = pos + 1
			m = m + 1
	else:
		s[pos] = '0'
		pos = pos + 1
	if (precision > 0):
		s[pos] = '.'
		pos = pos + 1
		int i = 1
		while (i <= precision):
			int j = d.dp + i - 1
			if ((j >= 0) && (j < d.nd)): s[pos] = d.d[j]
			else: s[pos] = '0'
			pos = pos + 1
			i = i + 1
	s[pos] = 0
	ftx_free(d)
	return s
