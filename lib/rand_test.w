# wbuild: x64
# float_bits (for the rand_float golden check only) comes from lib.fmath.
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
