/*
lib.rand: seeded, deterministic, non-cryptographic pseudo-random numbers
for numeric code (Monte Carlo sampling, jittered initialization, and
other simulation work that wants the exact same sequence on every run
and every target).

NOT cryptographic: libs/standard/crypto/random.w is the CSPRNG (kernel
getrandom(2), with a /dev/urandom fallback). This module exists for the
opposite property: the sequence is a pure function of the seed and is
bit-for-bit identical on every target (32-bit x86, x64, arm64, wasm),
so numeric results replay exactly across machines and runs. It is also
distinct from libs/standard/distributed/prng.w, which serves protocol
replay (timeout jitter, election delays) rather than numeric sampling;
the two modules deliberately carry independent copies of the same
generator rather than share code, so that lib/ stays self-contained
below libs/ (docs/projects/engineering_math_baseline.md).

Generator: xorshift32 (Marsaglia 2003, the 13/17/5 triple), one 32-bit
word of state. Kept under the masked-32-bit-word convention
(lib/sha256.w, libs/standard/distributed/prng.w): no integer literal
with bit 31 set appears in the source (such a literal is positive on a
64-bit host and negative on the 32-bit seed), the 0xffffffff/0x7fffffff
masks are built at runtime instead, and the logical right shift goes
through the shr intrinsic so no host sign bit smears into the result.
Every value handed back to a caller (rand_next31, rand_below,
rand_float) is masked down to a non-negative range, so the observable
sequence is identical on every target regardless of host word size.
*/
import lib.lib
import lib.assert
import lib.fmath


struct rand_state:
	int state   # masked 32-bit xorshift word, never zero
	float gaussian_cache   # second Box-Muller value, valid iff gaussian_has_cache
	int gaussian_has_cache   # 1 when gaussian_cache holds an unconsumed draw


# 0xffffffff as this target represents a masked 32-bit word (identity
# mask on the 32-bit target, where h * h wraps to 0).
int rand_mask32():
	int h = 1 << 16
	return h * h - 1


# 0x7fffffff, i.e. 2^31 - 1, built without a bit-31-set literal.
int rand_mask31():
	int q = 1 << 30
	return (q - 1) + q


# Seeds r from the low 32 bits of seed; higher bits of a wider host int
# are not observed. xorshift's one forbidden state (all-zero) folds to
# a fixed nonzero constant, 0x12345678, so rand_init(r, 0) is still
# valid and deterministic (same fold constant as
# libs/standard/distributed/prng.w's prng_new).
void rand_init(rand_state* r, int seed):
	r.state = seed & rand_mask32()
	if (r.state == 0): r.state = 305419896   # 0x12345678
	r.gaussian_cache = 0.0
	r.gaussian_has_cache = 0


# Next value: uniform over [0, 2^31), non-negative and identical on
# every target.
int rand_next31(rand_state* r):
	int x = r.state
	x = (x ^ (x << 13)) & rand_mask32()
	x = x ^ shr(x, 17)
	x = (x ^ (x << 5)) & rand_mask32()
	r.state = x
	return x & rand_mask31()


# Unbiased draw over [0, n): fatal assert if n is not positive.
#
# Plain "rand_next31(r) % n" is slightly biased whenever n does not
# divide the 2^31-wide output range evenly, so this rejects draws that
# land in the partial top bucket instead: every accepted draw then maps
# onto one of the n outcomes exactly the same number of times.
#
# The rejection threshold is "2^31 mod n", computed without ever
# forming the literal 2^31 (bit 31 set would sign-extend differently on
# a 32-bit host than a 64-bit one): 2^31 mod n == ((2^31 - 1) mod n + 1) mod n,
# and 2^31 - 1 is rand_mask31(), safe to write directly.
int rand_below(rand_state* r, int n):
	asserts(c"rand_below: n must be positive", n > 0)
	int rem = (rand_mask31() % n + 1) % n
	while (1):
		int v = rand_next31(r)
		if ((rem == 0) || (v <= rand_mask31() - rem)): return v % n


# float32 in [0, 1): the top 24 bits of a next31 draw (next31 >> 7,
# an ordinary arithmetic shift is fine here since next31's result is
# always non-negative) times 2^-24, so every one of the 2^24 possible
# outputs is exactly representable in a float32 mantissa and the
# comparatively weak low bits of xorshift32 never enter the result.
float rand_float(rand_state* r):
	int top24 = rand_next31(r) >> 7
	return top24 * (1.0 / 16777216.0)


# Standard normal (mean 0, variance 1) via Box-Muller, sine/cosine pair
# form: two independent uniforms u1, u2 produce two independent gaussian
# values, z0 = sqrt(-2 ln u1) * cos(2*pi*u2) and
# z1 = sqrt(-2 ln u1) * sin(2*pi*u2). z1 is cached in r.gaussian_cache
# (with r.gaussian_has_cache set) and handed back on the very next call
# instead of being recomputed, so a run of calls consumes one
# rand_next31 draw each on average - the textbook Box-Muller rate -
# rather than two. rand_init clears the cache, so re-seeding (or
# reusing a rand_state from scratch) always restarts at a fresh z0/z1
# pair regardless of how many gaussians were drawn before.
#
# u1 is the flog() argument and must never be exactly 0 (flog(0) is
# -inf): it is built the same way as rand_float's [0, 1) draw but with
# 1 added before scaling - (top24 + 1) * 2^-24 - so it ranges over
# (0, 1] instead of [0, 1). Every one of the 2^24 possible values of
# top24 + 1 is an integer no larger than 2^24, and dividing such an
# integer by 2^24 is exact in float32 (and in float64), so this
# construction is exactly representable and bit-identical on every
# target, like the rest of this module. u2 is an ordinary rand_float()
# draw, scaled by 2*pi for the angle.
#
# Deterministic: a fixed seed produces the same z0/z1 stream, and the
# same cache state after any given number of calls, on every target -
# exactly like rand_next31/rand_float. Accuracy is inherited entirely
# from lib/fmath's flog/fsqrt/fsin/fcos (each states its own measured
# ulp bound in its header); rand_gaussian composes them but adds no
# further error of its own.
float rand_gaussian(rand_state* r):
	if (r.gaussian_has_cache):
		r.gaussian_has_cache = 0
		return r.gaussian_cache
	int top24 = rand_next31(r) >> 7
	float scale = 1.0 / 16777216.0
	float u1 = (top24 + 1) * scale
	float u2 = rand_float(r)
	float neg_two = -2.0
	float radius = fsqrt(neg_two * flog(u1))
	float two_pi = float_from_bits(0x40c90fdb)    # 2*pi
	float theta = two_pi * u2
	r.gaussian_cache = radius * fsin(theta)
	r.gaussian_has_cache = 1
	return radius * fcos(theta)


# rand_gaussian(r) scaled and shifted to N(mean, stddev^2). Trivial
# composition (no new float constants, no new determinism concerns):
# provided for callers that want a non-standard normal distribution
# without hand-writing the affine transform.
float rand_gaussian_scaled(rand_state* r, float mean, float stddev):
	return mean + stddev * rand_gaussian(r)


# Python randrange(start, stop, step): a uniform pick from
# start, start + step, start + 2*step, ... strictly short of stop (above
# it for a negative step). Fatal assert when step is 0, when the range
# is empty, or when it holds more than 2^31 - 1 values (the most
# rand_below can draw unbiased on every target). Plain
# randrange(stop) is rand_range(r, 0, stop, 1). The span stop - start is
# computed in the host word, so on the 32-bit target a span wider than
# 2^31 - 1 wraps and is reported as empty rather than drawn from.
int rand_range(rand_state* r, int start, int stop, int step):
	asserts(c"rand_range: step must be nonzero", step != 0)
	int width = stop - start
	int n = 0
	if (step > 0): n = (width + step - 1) / step
	else: n = (width + step + 1) / step
	asserts(c"rand_range: empty range", n > 0)
	asserts(c"rand_range: range too wide", n <= rand_mask31())
	return start + step * rand_below(r, n)


# Uniform float in [a, b) (Python uniform(a, b); like Python, rounding
# can land exactly on b, and a > b draws from (b, a]).
float rand_uniform(rand_state* r, float a, float b):
	return a + (b - a) * rand_float(r)


# Exponential distribution with rate lambd (mean 1 / lambd), Python
# expovariate: -ln(1 - u) / lambd with u = rand_float(r). 1 - u is
# exactly representable and lies in (0, 1], so flog never sees 0. A
# negative lambd yields values in (-inf, 0], as in Python. Fatal assert
# when lambd is 0.
float rand_expovariate(rand_state* r, float lambd):
	asserts(c"rand_expovariate: lambd must be nonzero", lambd != 0.0)
	float one = 1.0
	float u = one - rand_float(r)
	return (0.0 - flog(u)) / lambd


# In-place Fisher-Yates shuffle of values[0..n): every one of the n!
# orderings is equally likely because each swap index comes from the
# unbiased rand_below. n <= 1 leaves values untouched. Works for any
# word-sized element (ints or pointers stored as int).
void rand_shuffle(rand_state* r, int* values, int n):
	int i = n - 1
	while (i > 0):
		int j = rand_below(r, i + 1)
		int t = values[i]
		values[i] = values[j]
		values[j] = t
		i = i - 1
