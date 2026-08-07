/*
structures.json_float64_impl: the float64 number engine behind
structures/json.w on 8-byte-word targets.

structures/json.w compiles for every target, and float64 is a compile
error where the word is 4 bytes (docs/projects/float.md), so json.w
itself never spells the type: every float64-typed operation lives here,
bound through the reserved __arch__ import segment. The
structures/__arch__/<arch>/json_float64.w twins import this file on the
8-byte-word targets and define bits-degrade-to-zero stubs on x86/wasm,
the same split lib/__arch__/x64/repl_echo_float64.w and its x86 twin
use.

The interface passes float64 values as their raw IEEE-754 bit pattern
in an int ("bits"), which is exactly word-sized on every target that
imports this file. Only the float_value-mirror helpers
(json_f64_to_float32 / json_f64_from_float32) mention float itself.

Parsing (json_f64_from_decimal) and formatting (json_f64_append) scale
by exact powers of ten -- 10^k and every intermediate product are
exactly representable in float64 for k <= 22 -- in as few chunks as
possible, carrying a double-double (~106-bit) intermediate so the
conversion is correctly rounded in both directions. The formatter
additionally verifies its digits by re-parsing them through
json_f64_from_decimal and emits the shortest rounded prefix that still
reproduces the exact source bits, so 0.1 prints as 0.1 (17 significant
digits at most, enough to identify any float64) and a stringify ->
parse round trip is bit-exact for every finite value (asserted by
tests/x64_json_float64_test.w and swept over random patterns during
development). Like json.w's float32 formatter it keeps a trailing .0
on whole values so they re-parse as floats, switches to scientific
notation for extreme exponents, and spells non-finite bit patterns as
null; unlike the float32 side it preserves the sign of a negative
zero.

Wide integer literals cannot be spelled here: the tokenizer runs as a
32-bit process and keeps only the low 32 bits of a wider literal token
(see lib/fmath64.w's header), so every constant needing more than 32
significant bits is built at runtime from shifts or multiplies.
*/
import lib.lib
import structures.string


# Reinterpret helpers, private copies rather than an import of
# lib.fmath64: imports merge into one flat namespace, and pulling the
# whole f*64 math surface into every structures.json consumer would
# collide with programs that import lib.fmath64 themselves.
int json_f64_bits(float64 f):
	int* p = cast(int*, &f)
	return *p


float64 json_f64_value(int bits):
	float64 f
	int* p = cast(int*, &f)
	*p = bits
	return f


# float32 reinterpret for the saturation check below. json.w owns the
# name json_float_bits, so this private copy is prefixed like the rest
# of the module.
int json_f64_float32_bits(float f):
	int32* p = cast(int32*, &f)
	return *p


# 10^k for 0 <= k <= 22: every value and every intermediate product is
# exactly representable in float64 (5^22 < 2^53), so the running
# product never rounds.
float64 json_f64_pow10(int k):
	float64 p = 1.0
	while (k > 0):
		p = p * 10.0
		k = k - 1
	return p


int json_f64_exp_field(int bits):
	return (bits >> 52) & 0x7ff


int json_f64_is_finite(int bits):
	return json_f64_exp_field(bits) != 0x7ff


int json_f64_sign_bit():
	return 1 << 63


# 0x7fffffffffffffff, built without the unspellable wide literal (the
# same shape as json.w's json_int_max)
int json_f64_abs_mask():
	return 0 - ((1 << 63) + 1)


# Largest finite float64, 0x7fefffffffffffff: the parse saturation
# limit. Like the float32 parser in json.w, overflow never produces an
# infinity.
int json_f64_max_finite_bits():
	return (0x7fe << 52) | ((1 << 52) - 1)


# Double-double building blocks for json_f64_from_decimal: an unevaluated
# hi + lo pair carries ~106 significand bits through the power-of-ten
# scaling, so the chained chunk roundings that would otherwise drift a
# unit into the 17th digit stay ~2^-50 below it. Plain float64
# formulations (Dekker/Knuth) -- no FMA in the instruction set.
float64 json_f64_dd_hi
float64 json_f64_dd_lo


# a * b exactly as json_f64_dd_hi (the rounded product) plus
# json_f64_dd_lo (the rounding error), via 26-bit Dekker splits. Valid
# while no intermediate overflows: |a * b| and the split constant
# 2^27 + 1 times |a| or |b| must stay finite, which the scaling loop's
# 2^±600 rescale guarantees.
void json_f64_two_prod(float64 a, float64 b):
	float64 p = a * b
	float64 ca = a * 134217729.0
	float64 a_big = ca - (ca - a)
	float64 a_low = a - a_big
	float64 cb = b * 134217729.0
	float64 b_big = cb - (cb - b)
	float64 b_low = b - b_big
	json_f64_dd_hi = p
	json_f64_dd_lo = ((a_big * b_big - p) + a_big * b_low + a_low * b_big) + a_low * b_low


# hi + lo renormalized (Fast2Sum; requires |hi| >= |lo|, which every
# caller satisfies).
void json_f64_dd_norm(float64 hi, float64 lo):
	float64 s = hi + lo
	json_f64_dd_lo = lo - (s - hi)
	json_f64_dd_hi = s


# (hi, lo) * p for an exact power of ten p <= 10^22.
void json_f64_dd_mul(float64 hi, float64 lo, float64 p):
	json_f64_two_prod(hi, p)
	float64 p_hi = json_f64_dd_hi
	float64 p_lo = json_f64_dd_lo + lo * p
	json_f64_dd_norm(p_hi, p_lo)


# (hi, lo) / p for an exact power of ten p <= 10^22.
void json_f64_dd_div(float64 hi, float64 lo, float64 p):
	float64 q1 = hi / p
	json_f64_two_prod(q1, p)
	# hi and the rounded product q1 * p are within a factor of two, so
	# the subtraction is exact (Sterbenz)
	float64 r = (hi - json_f64_dd_hi) - json_f64_dd_lo + lo
	json_f64_dd_norm(q1, r / p)


# mant * 10^exp10 as float64 bits, negated when negative is nonzero.
# mant is json.w's digit accumulation: 0 <= mant < 10^17, exact in an
# 8-byte int. Overflow saturates to the largest finite float64 and
# underflow flushes to (signed) zero, mirroring json_scale_pow10's
# float32 contract. The scaling walks exact powers of ten in <= 22
# decade chunks with double-double precision, rescaling by the exact
# 2^-600 / 2^600 near the range ends so no intermediate overflows,
# underflows, or hits the Dekker split's overflow bound; the single
# rounding that matters happens when hi + lo collapses to the result,
# so the value is correctly rounded (up to a ~2^-50-ulp tie band) for
# every normal result, and within an ulp for denormals, whose final
# 2^-600 unscale can round once more. The result is monotone in mant,
# which json_f64_append's round-trip walk relies on -- and the
# near-correct rounding here is what guarantees that walk finds, for
# every float64, a 17-digit decimal mapping back to its exact bits.
int json_f64_from_decimal(int mant, int exp10, int negative):
	int sign = 0
	if (negative):
		sign = json_f64_sign_bit()
	if (mant == 0):
		return sign
	# Exact double-double image of mant: hi rounds (mant can exceed
	# 2^53), the integer subtraction recovers the residue exactly
	float64 hi = mant
	int hi_int = hi
	float64 lo = mant - hi_int
	float64 two600 = json_f64_value((1023 + 600) << 52)
	float64 two_neg600 = json_f64_value((1023 - 600) << 52)
	int rescaled = 0
	int e = exp10
	int k = 0
	while (e > 0):
		if (rescaled):
			if (hi > 1e130):
				# beyond the largest finite float64 once unscaled
				return json_f64_max_finite_bits() | sign
		else if (hi > 1e250):
			# keep hi clear of the split's 2^970 overflow bound
			hi = hi * two_neg600
			lo = lo * two_neg600
			rescaled = 1
		k = e
		if (k > 22):
			k = 22
		json_f64_dd_mul(hi, lo, json_f64_pow10(k))
		hi = json_f64_dd_hi
		lo = json_f64_dd_lo
		if (json_f64_is_finite(json_f64_bits(hi)) == 0):
			return json_f64_max_finite_bits() | sign
		e = e - k
	while (e < 0):
		if (rescaled):
			if (hi < 1e-150):
				# below half the smallest denormal once unscaled
				return sign
		else if (hi < 1e-250):
			# keep the components normal so the double-double
			# precision survives into the denormal decades
			hi = hi * two600
			lo = lo * two600
			rescaled = 1
		k = 0 - e
		if (k > 22):
			k = 22
		json_f64_dd_div(hi, lo, json_f64_pow10(k))
		hi = json_f64_dd_hi
		lo = json_f64_dd_lo
		e = e + k
	float64 f = hi + lo
	if (rescaled):
		if (exp10 > 0):
			f = f * two600
			if (json_f64_is_finite(json_f64_bits(f)) == 0):
				return json_f64_max_finite_bits() | sign
		else:
			f = f * two_neg600
			if (f == 0.0):
				return sign
	return json_f64_bits(f) | sign


# Widen json.w's float32 float_value mirror to float64 bits (exact).
int json_f64_from_float32(float f):
	float64 wide = f
	return json_f64_bits(wide)


# int -> float64 bits, for decoding a JSON integer into a float64 slot.
int json_f64_from_int(int v):
	float64 f = v
	return json_f64_bits(f)


# Narrow float64 bits to the float32 mirror json.w keeps in
# float_value. Finite values too large for float32 saturate to the
# largest finite float32 instead of the infinity IEEE narrowing gives,
# matching json.w's float32 parse contract; small values flush through
# the float32 denormals naturally, and non-finite input keeps its
# non-finite float32 image (json_append_float spells it null).
float json_f64_to_float32(int bits):
	float64 f = json_f64_value(bits)
	float narrow = f
	if (json_f64_is_finite(bits)):
		if ((json_f64_float32_bits(narrow) & 0x7f800000) == 0x7f800000):
			narrow = 3.40282346e38
			if (f < 0.0):
				narrow = -3.40282346e38
	return narrow


# Append the JSON spelling of float64 bits to out: up to 17 significant
# digits (enough to identify any float64), trailing zeros stripped, a
# trailing .0 on whole values, scientific notation outside plain
# range, null for non-finite patterns, and a preserved sign on
# negative zero.
void json_f64_append(string_builder* out, int bits):
	if (json_f64_is_finite(bits) == 0):
		string_append(out, c"null")
		return
	int pbits = bits & json_f64_abs_mask()
	if (pbits == 0):
		if (bits != 0):
			string_append_char(out, '-')
		string_append(out, c"0.0")
		return
	if (bits != pbits):
		string_append_char(out, '-')

	# Initial decimal exponent estimate from the binary exponent
	# (log10(2) ~ 301/1000, floored); denormals all sit within the
	# lowest decades, and the normalization below absorbs any
	# estimate error.
	int be = json_f64_exp_field(pbits)
	int e10 = -324
	if (be > 0):
		int scaled = (be - 1023) * 301
		e10 = scaled / 1000
		if ((scaled < 0) && (scaled % 1000 != 0)):
			e10 = e10 - 1

	# Scale into [10^16, 10^17) with exact-power chunks at double-double
	# precision, keeping e10 the decimal exponent of the leading digit.
	# The dd error (~2^-100 relative) stays far below the digit grid,
	# so rounding hi + lo to an integer below lands on the correctly
	# rounded 17 significant digits -- the canonical spelling, so whole
	# values print whole. Extreme exponents first fold in an exact
	# power of two (2^-568 for the huge decades, 2^568 for the tiny
	# ones -- exact because scaling a float64 by a power of two only
	# moves its exponent, and 2^±568 folds back out through one more dd
	# multiplication): that keeps every Dekker-split operand and error
	# term inside the normal range, where the top decades would
	# otherwise overflow a_big * b_big to infinity and the denormal
	# decades would underflow the error terms to zero.
	float64 hi = json_f64_value(pbits)
	float64 lo = 0.0
	int prescale = 0
	if (e10 > 250):
		hi = hi * json_f64_value((1023 - 568) << 52)
		prescale = 1
	else if (e10 < -250):
		hi = hi * json_f64_value((1023 + 568) << 52)
		prescale = -1
	int shift = 16 - e10
	while (shift > 22):
		json_f64_dd_mul(hi, lo, json_f64_pow10(22))
		hi = json_f64_dd_hi
		lo = json_f64_dd_lo
		shift = shift - 22
	while (shift < -22):
		json_f64_dd_div(hi, lo, json_f64_pow10(22))
		hi = json_f64_dd_hi
		lo = json_f64_dd_lo
		shift = shift + 22
	if (shift > 0):
		json_f64_dd_mul(hi, lo, json_f64_pow10(shift))
		hi = json_f64_dd_hi
		lo = json_f64_dd_lo
	if (shift < 0):
		json_f64_dd_div(hi, lo, json_f64_pow10(0 - shift))
		hi = json_f64_dd_hi
		lo = json_f64_dd_lo
	if (prescale == 1):
		json_f64_dd_mul(hi, lo, json_f64_value((1023 + 568) << 52))
		hi = json_f64_dd_hi
		lo = json_f64_dd_lo
	if (prescale == -1):
		json_f64_dd_mul(hi, lo, json_f64_value((1023 - 568) << 52))
		hi = json_f64_dd_hi
		lo = json_f64_dd_lo
	float64 low = json_f64_pow10(16)
	float64 high = low * 10.0
	while (hi >= high):
		json_f64_dd_div(hi, lo, 10.0)
		hi = json_f64_dd_hi
		lo = json_f64_dd_lo
		e10 = e10 + 1
	while (hi < low):
		json_f64_dd_mul(hi, lo, 10.0)
		hi = json_f64_dd_hi
		lo = json_f64_dd_lo
		e10 = e10 - 1

	# Every float64 in [10^16, 10^17) is a whole number (the spacing
	# there is at least 2), so the truncation of hi is exact; lo then
	# rounds it to the nearest 17-digit integer
	int d = hi
	float64 adjust = lo + 0.5
	int whole = adjust
	if ((adjust < 0.0) && (whole > adjust)):
		whole = whole - 1
	d = d + whole
	int d_low = 1
	int i = 0
	while (i < 16):
		d_low = d_low * 10
		i = i + 1
	int d_high = d_low * 10
	if (d >= d_high):
		d = d_low
		e10 = e10 + 1
	if (d < d_low):
		d = d_high - 1
		e10 = e10 - 1

	# Verification walk: json_f64_from_decimal is monotone in d, so
	# step the 17-digit candidate (across decade edges when it
	# saturates a boundary) until re-parsing returns the source bits.
	# With the double-double scaling above, d already is the correctly
	# rounded 17-digit spelling and the first probe matches; the walk
	# is the safety net that turns any residual tie-band slip into at
	# most a couple of extra probes instead of a broken round trip. If
	# it ever bracketed the target without hitting it, the closest
	# candidate would be kept.
	int walked_up = 0
	int walked_down = 0
	int done = 0
	int tries = 0
	while ((done == 0) && (tries < 64)):
		int got = json_f64_from_decimal(d, e10 - 16, 0)
		if (got == pbits):
			done = 1
		else if (got < pbits):
			# positive bit patterns order like their values
			if (walked_down):
				done = 1
			else:
				walked_up = 1
				d = d + 1
				if (d >= d_high):
					d = d_low
					e10 = e10 + 1
		else:
			if (walked_up):
				done = 1
			else:
				walked_down = 1
				d = d - 1
				if (d < d_low):
					d = d_high - 1
					e10 = e10 - 1
		tries = tries + 1

	# Shortest spelling: try the rounded L-digit prefixes of d from
	# one digit up and keep the first that still re-parses to the
	# exact source bits, so 0.1 prints as 0.1 (not its canonical
	# 17-digit expansion 0.10000000000000001) and the smallest
	# denormal as 5e-324. The nearest L-digit decimal is the only
	# possible L-digit spelling of the value, so one probe per length
	# suffices; a prefix that rounds up into the next decade re-probes
	# as that decade's single leading digit.
	int length = 1
	int found = 0
	while ((found == 0) && (length < 17)):
		int p = 1
		i = 17 - length
		while (i > 0):
			p = p * 10
			i = i - 1
		int cand = (d + p / 2) / p * p
		if (cand >= d_high):
			if (json_f64_from_decimal(d_low, e10 - 15, 0) == pbits):
				d = d_low
				e10 = e10 + 1
				found = 1
		else if (json_f64_from_decimal(cand, e10 - 16, 0) == pbits):
			d = cand
			found = 1
		length = length + 1

	char* digits = malloc(18)
	i = 16
	while (i >= 0):
		digits[i] = '0' + d % 10
		d = d / 10
		i = i - 1
	digits[17] = 0
	int n = 17
	while ((n > 1) && (digits[n - 1] == '0')):
		n = n - 1

	if ((e10 < -4) || (e10 > 16)):
		# scientific: d.ddde±x (no fraction part for a single digit --
		# JSON requires at least one digit after a '.')
		string_append_char(out, digits[0])
		if (n > 1):
			string_append_char(out, '.')
			i = 1
			while (i < n):
				string_append_char(out, digits[i])
				i = i + 1
		string_append_char(out, 'e')
		string_append_int(out, e10)
	else if (e10 < 0):
		string_append(out, c"0.")
		i = -1
		while (i > e10):
			string_append_char(out, '0')
			i = i - 1
		i = 0
		while (i < n):
			string_append_char(out, digits[i])
			i = i + 1
	else if (e10 >= n - 1):
		i = 0
		while (i < n):
			string_append_char(out, digits[i])
			i = i + 1
		i = n - 1
		while (i < e10):
			string_append_char(out, '0')
			i = i + 1
		string_append(out, c".0")
	else:
		i = 0
		while (i <= e10):
			string_append_char(out, digits[i])
			i = i + 1
		string_append_char(out, '.')
		while (i < n):
			string_append_char(out, digits[i])
			i = i + 1
	free(digits)
