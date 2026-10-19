# wbuild: x64
# wbuild: step="bin/random_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import lib.container
import libs.standard.numeric.random


void assert_list_equal(list[int] want, list[int] got):
	assert_equal(want.length, got.length)
	for i in range(want.length): assert_equal(want[i], got[i])


list[int] random_test_population():
	return list[int]{10, 20, 30, 40, 50, 60, 70, 80}


# Goldens off seed 42, captured on the 32-bit target and identical on x64
# (both twins assert the same lists): sample, then uniform choices, then
# weighted choices, all drawn in sequence from one state.
void test_goldens_fixed_seed():
	rand_state* r = random_new(42)
	list[int] pop = random_test_population()
	list[int] s = random_sample(r, pop, 5)
	list[int] want_s = list[int]{10, 20, 60, 70, 50}
	assert_list_equal(want_s, s)
	list[int] c = random_choices(r, pop, 6)
	list[int] want_c = list[int]{70, 10, 70, 40, 80, 30}
	assert_list_equal(want_c, c)
	list[float] w = list[float]{1.0, 0.0, 2.0, 0.0, 0.0, 0.0, 0.0, 5.0}
	list[int] cw = random_choices_weighted(r, pop, w, 8)
	list[int] want_cw = list[int]{80, 80, 80, 80, 80, 30, 10, 80}
	assert_list_equal(want_cw, cw)
	list_free[int](want_cw)
	list_free[int](cw)
	list_free[float](w)
	list_free[int](want_c)
	list_free[int](c)
	list_free[int](want_s)
	list_free[int](s)
	list_free[int](pop)
	random_free(r)


# Same seed, same calls -> same results; re-seeding replays the stream.
void test_determinism_and_reseed():
	rand_state* a = random_new(1234)
	rand_state* b = random_new(1234)
	for i in range(200):
		assert_equal(random_randrange(a, -100, 100, 7), random_randrange(b, -100, 100, 7))
		assert_equal(random_randint(a, 1, 6), random_randint(b, 1, 6))
	list[int] xs = random_test_population()
	list[int] ys = random_test_population()
	random_shuffle_list(a, xs)
	random_shuffle_list(b, ys)
	assert_list_equal(xs, ys)

	random_seed(a, 9)
	int first = random_range(a, 0, 1000000)
	random_seed(a, 9)
	assert_equal(first, random_range(a, 0, 1000000))
	list_free[int](ys)
	list_free[int](xs)
	random_free(b)
	random_free(a)


# randint is inclusive at both ends and hits both.
void test_randint_inclusive():
	rand_state* r = random_new(5)
	int lo = 0
	int hi = 0
	for i in range(600):
		int v = random_randint(r, -2, 2)
		assert1((v >= -2) && (v <= 2))
		if (v == -2): lo = lo + 1
		if (v == 2): hi = hi + 1
	assert1(lo > 60)
	assert1(hi > 60)
	assert_equal(7, random_randint(r, 7, 7))
	random_free(r)


# random_shuffle (array) and random_shuffle_list walk identically, and a
# shuffle is a permutation: every element still present exactly once.
void test_shuffle_array_matches_list():
	rand_state* a = random_new(77)
	rand_state* b = random_new(77)
	int* arr = cast(int*, malloc(8 * 50))
	list[int] xs = new list[int]
	for i in range(50):
		arr[i] = i
		xs.push(i)
	random_shuffle(a, arr, 50)
	random_shuffle_list(b, xs)
	int* seen = cast(int*, malloc(8 * 50))
	for i in range(50): seen[i] = 0
	int moved = 0
	for i in range(50):
		assert_equal(arr[i], xs[i])
		seen[arr[i]] = seen[arr[i]] + 1
		if (arr[i] != i): moved = moved + 1
	for i in range(50): assert_equal(1, seen[i])
	assert1(moved > 25)
	free(seen)
	list_free[int](xs)
	free(arr)
	random_free(b)
	random_free(a)


void test_choice():
	rand_state* r = random_new(3)
	list[int] pop = random_test_population()
	list[int] hits = new list[int]
	for i in range(8): hits.push(0)
	for i in range(1600):
		int v = random_choice_list(r, pop)
		assert1((v % 10 == 0) && (v >= 10) && (v <= 80))
		hits[v / 10 - 1] = hits[v / 10 - 1] + 1
	for i in range(8): assert1((hits[i] > 120) && (hits[i] < 280))
	int* one = cast(int*, malloc(8))
	one[0] = 42
	assert_equal(42, random_choice(r, one, 1))
	free(one)
	list_free[int](hits)
	list_free[int](pop)
	random_free(r)


# sample: distinct positions, k = 0 empty, k = n a full permutation,
# duplicates in the population may repeat as values (Python semantics).
void test_sample_without_replacement():
	rand_state* r = random_new(8)
	for t in range(200):
		list[int] idx = random_sample_indices(r, 20, 7)
		assert_equal(7, idx.length)
		for i in range(7):
			assert1((idx[i] >= 0) && (idx[i] < 20))
			for j in range(i): assert1(idx[i] != idx[j])
		list_free[int](idx)

	list[int] pop = random_test_population()
	list[int] none = random_sample(r, pop, 0)
	assert_equal(0, none.length)
	list[int] all = random_sample(r, pop, 8)
	int sum = 0
	for i in range(8): sum = sum + all[i]
	assert_equal(360, sum)
	for i in range(8):
		for j in range(i): assert1(all[i] != all[j])

	list[int] dup = list[int]{1, 1, 1}
	list[int] d = random_sample(r, dup, 3)
	for i in range(3): assert_equal(1, d[i])

	list[int] empty = new list[int]
	list[int] e = random_sample(r, empty, 0)
	assert_equal(0, e.length)
	list_free[int](e)
	list_free[int](empty)
	list_free[int](d)
	list_free[int](dup)
	list_free[int](all)
	list_free[int](none)
	list_free[int](pop)
	random_free(r)


# Every element of range(5) is equally likely to be in a 2-sample:
# expected 0.4 * 5000 = 2000 appearances each.
void test_sample_inclusion_uniform():
	rand_state* r = random_new(31)
	list[int] counts = new list[int]
	for i in range(5): counts.push(0)
	for t in range(5000):
		list[int] idx = random_sample_indices(r, 5, 2)
		counts[idx[0]] = counts[idx[0]] + 1
		counts[idx[1]] = counts[idx[1]] + 1
		list_free[int](idx)
	for i in range(5): assert1((counts[i] > 1800) && (counts[i] < 2200))
	list_free[int](counts)
	random_free(r)


# Weights 1:3 -> about 25% / 75%; zero-weight elements are never chosen,
# including at either end; cum_weights give the same distribution.
void test_choices_weighted_distribution():
	rand_state* r = random_new(2026)
	list[int] pop = list[int]{0, 1, 2, 3}
	list[float] w = list[float]{0.0, 1.0, 3.0, 0.0}
	list[int] got = random_choices_weighted(r, pop, w, 8000)
	assert_equal(8000, got.length)
	int ones = 0
	for i in range(got.length):
		assert1((got[i] == 1) || (got[i] == 2))
		if (got[i] == 1): ones = ones + 1
	assert1((ones > 1700) && (ones < 2300))

	list[float] cum = list[float]{0.0, 1.0, 4.0, 4.0}
	list[int] got2 = random_choices_cum(r, pop, cum, 8000)
	int ones2 = 0
	for i in range(got2.length):
		assert1((got2[i] == 1) || (got2[i] == 2))
		if (got2[i] == 1): ones2 = ones2 + 1
	assert1((ones2 > 1700) && (ones2 < 2300))

	list[int] zero = random_choices_cum(r, pop, cum, 0)
	assert_equal(0, zero.length)
	list_free[int](zero)
	list_free[int](got2)
	list_free[float](cum)
	list_free[int](got)
	list_free[float](w)
	list_free[int](pop)
	random_free(r)


# Uniform choices draw with replacement: a 1-element population repeats.
void test_choices_with_replacement():
	rand_state* r = random_new(4)
	list[int] pop = list[int]{9}
	list[int] got = random_choices(r, pop, 5)
	assert_equal(5, got.length)
	for i in range(5): assert_equal(9, got[i])
	list[int] empty = new list[int]
	list[int] none = random_choices(r, empty, 0)
	assert_equal(0, none.length)
	list_free[int](none)
	list_free[int](empty)
	list_free[int](got)
	list_free[int](pop)
	random_free(r)


void test_float_distributions():
	rand_state* r = random_new(12)
	float usum = 0.0
	float esum = 0.0
	float gsum = 0.0
	float gsq = 0.0
	for i in range(10000):
		float f = random_float(r)
		assert1((f >= 0.0) && (f < 1.0))
		float u = random_uniform(r, 10.0, 20.0)
		assert1((u >= 10.0) && (u <= 20.0))
		usum = usum + u
		float e = random_expovariate(r, 0.5)
		assert1(e >= 0.0)
		esum = esum + e
		float g = random_gauss(r, 5.0, 2.0)
		gsum = gsum + g
		gsq = gsq + (g - 5.0) * (g - 5.0)
	float umean = usum / 10000.0
	assert1((umean > 14.7) && (umean < 15.3))
	float emean = esum / 10000.0
	assert1((emean > 1.85) && (emean < 2.15))
	float gmean = gsum / 10000.0
	assert1((gmean > 4.9) && (gmean < 5.1))
	float gvar = gsq / 10000.0
	assert1((gvar > 3.6) && (gvar < 4.4))
	random_free(r)
