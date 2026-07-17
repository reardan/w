# wbuild: x64
import lib.testing
import libs.standard.distributed.prng


void test_same_seed_same_sequence():
	prng* a = prng_new(42)
	prng* b = prng_new(42)
	int i = 0
	while (i < 100):
		assert_equal(prng_next(a), prng_next(b))
		i = i + 1
	prng_free(a)
	prng_free(b)


void test_different_seeds_differ():
	prng* a = prng_new(1)
	prng* b = prng_new(2)
	int same = 0
	int i = 0
	while (i < 10):
		if (prng_next(a) == prng_next(b)):
			same = same + 1
		i = i + 1
	assert1(same < 10)
	prng_free(a)
	prng_free(b)


void test_seed_zero_is_valid():
	prng* a = prng_new(0)
	prng* b = prng_new(0)
	int v = prng_next(a)
	assert1(v >= 0)
	assert_equal(v, prng_next(b))
	prng_free(a)
	prng_free(b)


void test_outputs_non_negative():
	prng* p = prng_new(7)
	int i = 0
	while (i < 1000):
		assert1(prng_next(p) >= 0)
		i = i + 1
	prng_free(p)


void test_range_bounds():
	prng* p = prng_new(99)
	int i = 0
	while (i < 1000):
		int v = prng_range(p, 10)
		assert1(v >= 0)
		assert1(v < 10)
		int w = prng_between(p, 150, 300)
		assert1(w >= 150)
		assert1(w <= 300)
		i = i + 1
	# n = 1 always yields 0
	assert_equal(0, prng_range(p, 1))
	prng_free(p)


void test_range_hits_all_small_values():
	prng* p = prng_new(5)
	int seen0 = 0
	int seen1 = 0
	int seen2 = 0
	int i = 0
	while (i < 200):
		int v = prng_range(p, 3)
		if (v == 0):
			seen0 = 1
		if (v == 1):
			seen1 = 1
		if (v == 2):
			seen2 = 1
		i = i + 1
	assert_equal(1, seen0)
	assert_equal(1, seen1)
	assert_equal(1, seen2)
	prng_free(p)


void test_known_sequence_cross_target():
	# First outputs for seed 42, observed on the x86 target; the x64
	# run must produce the identical sequence (masked-word discipline).
	prng* p = prng_new(42)
	assert_equal(11355432, prng_next(p))
	assert_equal(688534700, prng_next(p))
	assert_equal(476557059, prng_next(p))
	prng_free(p)
