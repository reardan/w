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


struct rand_state:
	int state   # masked 32-bit xorshift word, never zero


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
	if (r.state == 0):
		r.state = 305419896   # 0x12345678


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
		if ((rem == 0) || (v <= rand_mask31() - rem)):
			return v % n


# float32 in [0, 1): the top 24 bits of a next31 draw (next31 >> 7,
# an ordinary arithmetic shift is fine here since next31's result is
# always non-negative) times 2^-24, so every one of the 2^24 possible
# outputs is exactly representable in a float32 mantissa and the
# comparatively weak low bits of xorshift32 never enter the result.
float rand_float(rand_state* r):
	int top24 = rand_next31(r) >> 7
	return top24 * (1.0 / 16777216.0)
