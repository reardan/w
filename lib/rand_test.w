# wbuild: x64
# float_bits (for the golden bit-pattern checks) comes from lib.fmath;
# rand_gaussian itself is built on lib.fmath's flog/fsqrt/fsin/fcos.
import lib.testing
import lib.rand
import lib.fmath


# First 8 rand_next31 values for seed 42, computed by a scratch C program
# (uint32_t x; x ^= x<<13; x ^= x>>17; x ^= x<<5; return x & 0x7fffffff;)
# replicating rand_next31 bit-for-bit. Both the 32-bit and the x64 twin of
# this test assert the same numbers: that identity is the entire point of
# the masked-32-bit-word convention lib/rand.w documents.
void test_next31_goldens():
	rand_state r
	rand_init(&r, 42)
	assert_equal(11355432, rand_next31(&r))
	assert_equal(688534700, rand_next31(&r))
	assert_equal(476557059, rand_next31(&r))
	assert_equal(1500562368, rand_next31(&r))
	assert_equal(1612499908, rand_next31(&r))
	assert_equal(1441438134, rand_next31(&r))
	assert_equal(1565983192, rand_next31(&r))
	assert_equal(284160686, rand_next31(&r))


# rand_init(r, 0) folds to the documented constant 0x12345678, so seeding
# explicitly with that constant must produce the identical sequence.
void test_seed_zero_folds_to_documented_constant():
	rand_state a
	rand_init(&a, 0)
	rand_state b
	rand_init(&b, 305419896)   # 0x12345678
	int i = 0
	while (i < 8):
		assert_equal(rand_next31(&b), rand_next31(&a))
		i = i + 1


void test_below_bounds():
	rand_state r
	rand_init(&r, 7)
	int i = 0
	while (i < 4000):
		int v = rand_below(&r, 100)
		assert1(v >= 0)
		assert1(v < 100)
		i = i + 1

	int j = 0
	while (j < 2000):
		int v2 = rand_below(&r, 1000003)   # large, still must stay in range
		assert1(v2 >= 0)
		assert1(v2 < 1000003)
		j = j + 1


# n = 1 has exactly one outcome: always 0.
void test_below_n_one():
	rand_state r
	rand_init(&r, 17)
	int i = 0
	while (i < 200):
		assert_equal(0, rand_below(&r, 1))
		i = i + 1


# Crude, deterministic uniformity sanity check: every bucket of a small
# n gets at least one hit over enough draws. Not a statistical test of
# distribution quality, just a smoke test that rand_below doesn't starve
# a bucket outright (e.g. an off-by-one in the rejection threshold).
void test_below_uniformity():
	rand_state r
	rand_init(&r, 99)
	int[5] buckets
	buckets[0] = 0
	buckets[1] = 0
	buckets[2] = 0
	buckets[3] = 0
	buckets[4] = 0
	int i = 0
	while (i < 5000):
		int v = rand_below(&r, 5)
		buckets[v] += 1
		i = i + 1
	i = 0
	while (i < 5):
		assert1(buckets[i] > 0)
		i = i + 1


void test_float_range():
	rand_state r
	rand_init(&r, 123)
	int i = 0
	while (i < 5000):
		float f = rand_float(&r)
		assert1(f >= 0.0)
		assert1(f < 1.0)
		i = i + 1


# Bit-exact goldens for the first few rand_float draws off seed 42,
# cross-checked against the same scratch C program (top 24 bits of the
# next31 golden sequence above, times 2^-24) via float_bits from
# lib.fmath so the comparison is exact rather than tolerance-based.
void test_float_goldens():
	rand_state r
	rand_init(&r, 42)
	assert_equal_hex(0x3bad4500, float_bits(rand_float(&r)))
	assert_equal_hex(0x3ea428d2, float_bits(rand_float(&r)))
	assert_equal_hex(0x3e633d78, float_bits(rand_float(&r)))
	assert_equal_hex(0x3f32e187, float_bits(rand_float(&r)))
	assert_equal_hex(0x3f403997, float_bits(rand_float(&r)))
	assert_equal_hex(0x3f2bd533, float_bits(rand_float(&r)))


# Bit-exact goldens for the first 6 rand_gaussian values off seed 42,
# captured by running this same rand_gaussian off a throwaway W scratch
# program on the 32-bit target and printing float_bits(...) in hex, then
# re-run unmodified on the x64 target to confirm the bits didn't move.
# That cross-target agreement is the entire assertion here, not any
# external reference for "correct" gaussian output: a regression in the
# Box-Muller construction, the u1/u2 draws, or in flog/fsqrt/fsin/fcos
# would be caught by this test moving off these numbers, on one target
# or both. cast(int, ...) is required on the four values with bit 31
# set (lib/rand.w's masked-32-bit-word convention: such a literal
# sign-extends on every target unless explicitly cast).
void test_gaussian_goldens():
	rand_state r
	rand_init(&r, 42)
	assert_equal_hex(cast(int, 0xbfb1f082), float_bits(rand_gaussian(&r)))
	assert_equal_hex(0x403b2987, float_bits(rand_gaussian(&r)))
	assert_equal_hex(cast(int, 0xbf0c92a6), float_bits(rand_gaussian(&r)))
	assert_equal_hex(cast(int, 0xbfd2b101), float_bits(rand_gaussian(&r)))
	assert_equal_hex(cast(int, 0xbeb81a3d), float_bits(rand_gaussian(&r)))
	assert_equal_hex(cast(int, 0xbf2a876d), float_bits(rand_gaussian(&r)))


# Statistical sanity, fully deterministic (fixed seed, fixed draw
# count): 10,000 rand_gaussian draws off seed 7 should look like a
# standard normal sample without being a rigorous distribution test.
# Measured off this exact seed/count: mean -0.002153, variance
# 0.982079, max |value| 4.244895, 4980/5020 negative/positive - all
# comfortably inside the bounds below on both targets.
void test_gaussian_statistics():
	rand_state r
	rand_init(&r, 7)
	int n = 10000
	float sum = 0.0
	float sumsq = 0.0
	int pos = 0
	int neg = 0
	int i = 0
	while (i < n):
		float v = rand_gaussian(&r)
		assert1(v > -6.0)
		assert1(v < 6.0)
		if (v > 0.0):
			pos = pos + 1
		else if (v < 0.0):
			neg = neg + 1
		sum = sum + v
		sumsq = sumsq + v * v
		i = i + 1
	float nf = n
	float mean = sum / nf
	float variance = sumsq / nf - mean * mean
	assert1(mean > -0.05)
	assert1(mean < 0.05)
	assert1(variance > 0.9)
	assert1(variance < 1.1)
	assert1(pos > 4000)
	assert1(neg > 4000)


# Cache behavior: rand_gaussian caches the Box-Muller sine partner and
# hands it back on the next call instead of drawing fresh randomness.
# An odd number of draws (3) leaves that cache non-empty; rand_init
# must clear it, so re-seeding the same rand_state and drawing again
# reproduces the very first value rather than the stale cached one.
void test_gaussian_cache_reset_on_reinit():
	rand_state r
	rand_init(&r, 55)
	int first = float_bits(rand_gaussian(&r))
	rand_gaussian(&r)
	rand_gaussian(&r)
	rand_init(&r, 55)
	assert_equal_hex(first, float_bits(rand_gaussian(&r)))


# rand_gaussian_scaled(r, mean, stddev) is exactly
# "mean + stddev * rand_gaussian(r)": check it against a plain
# rand_gaussian draw from an identically-seeded state.
void test_gaussian_scaled():
	rand_state a
	rand_init(&a, 91)
	rand_state b
	rand_init(&b, 91)
	float plain = rand_gaussian(&a)
	float mean = 10.0
	float stddev = 2.0
	float scaled = rand_gaussian_scaled(&b, mean, stddev)
	assert_equal_hex(float_bits(mean + stddev * plain), float_bits(scaled))
