# wbuild: x64
import lib.testing
import lib.format
import lib.container
import lib.window


# Same tolerance as lib/stats_test.w.
void assert_near(float want, float got):
	if (fabs(want - got) > 0.0001):
		print2(c"Assertion failed. wanted float(")
		print2(ftoa(want))
		print2(c") got float(")
		print2(ftoa(got))
		println2(c")")
		exit(1)


void assert_int_list(list[int] want, list[int] got):
	assert_equal(want.length, got.length)
	int i = 0
	while (i < want.length):
		assert_equal(want[i], got[i])
		i = i + 1


# O(n * k) reference for the extremes.
int reference_extreme(list[int] xs, int start, int k, int want_max):
	int best = xs[start]
	int i = 1
	while (i < k):
		if (want_max && (xs[start + i] > best)):
			best = xs[start + i]
		if ((want_max == 0) && (xs[start + i] < best)):
			best = xs[start + i]
		i = i + 1
	return best


void test_window_max_classic():
	# the LeetCode 239 example
	list[int] xs = list[int]{1, 3, -1, -3, 5, 3, 6, 7}
	list[int] got = window_max(xs, 3)
	list[int] want = list[int]{3, 3, 5, 5, 6, 7}
	assert_int_list(want, got)
	list_free[int](got)


void test_window_min_classic():
	list[int] xs = list[int]{1, 3, -1, -3, 5, 3, 6, 7}
	list[int] got = window_min(xs, 3)
	list[int] want = list[int]{-1, -3, -3, -3, 3, 3}
	assert_int_list(want, got)
	list_free[int](got)


void test_window_extremes_k_one_is_identity():
	list[int] xs = list[int]{4, -2, 9, 0}
	list[int] maxes = window_max(xs, 1)
	list[int] mins = window_min(xs, 1)
	assert_int_list(xs, maxes)
	assert_int_list(xs, mins)
	list_free[int](maxes)
	list_free[int](mins)


void test_window_extremes_k_equals_length():
	list[int] xs = list[int]{4, -2, 9, 0}
	list[int] maxes = window_max(xs, 4)
	assert_equal(1, maxes.length)
	assert_equal(9, maxes[0])
	list[int] mins = window_min(xs, 4)
	assert_equal(1, mins.length)
	assert_equal(-2, mins[0])
	list_free[int](maxes)
	list_free[int](mins)


void test_window_shorter_than_k_is_empty():
	list[int] xs = list[int]{1, 2, 3}
	list[int] maxes = window_max(xs, 4)
	assert_equal(0, maxes.length)
	list[int] sums = window_sum(xs, 4)
	assert_equal(0, sums.length)
	list[float] fs = list[float]{1.0}
	list[float] fsums = window_sum_float(fs, 2)
	assert_equal(0, fsums.length)
	list_free[int](maxes)
	list_free[int](sums)
	list_free[float](fsums)


void test_window_extremes_monotonic_inputs():
	list[int] rising = list[int]{1, 2, 3, 4, 5}
	list[int] got = window_max(rising, 2)
	list[int] want_rising = list[int]{2, 3, 4, 5}
	assert_int_list(want_rising, got)
	list_free[int](got)

	list[int] falling = list[int]{5, 4, 3, 2, 1}
	got = window_max(falling, 2)
	list[int] want_falling = list[int]{5, 4, 3, 2}
	assert_int_list(want_falling, got)
	list_free[int](got)


void test_window_extremes_duplicates():
	list[int] xs = list[int]{2, 2, 2, 1, 2}
	list[int] maxes = window_max(xs, 2)
	list[int] want_max = list[int]{2, 2, 2, 2}
	assert_int_list(want_max, maxes)
	list[int] mins = window_min(xs, 2)
	list[int] want_min = list[int]{2, 2, 1, 1}
	assert_int_list(want_min, mins)
	list_free[int](maxes)
	list_free[int](mins)


# Deterministic LCG-generated input, every k from 1 to n, checked
# against the O(n * k) reference — the strongest guard on the deque
# index arithmetic.
void test_window_extremes_match_reference():
	list[int] xs = new list[int]
	int state = 12345
	int i = 0
	while (i < 40):
		state = state * 1103515245 + 12345
		# fold to a small signed range so duplicates are common
		xs.push((state / 65536) % 50)
		i = i + 1
	int k = 1
	while (k <= xs.length):
		list[int] maxes = window_max(xs, k)
		list[int] mins = window_min(xs, k)
		assert_equal(xs.length - k + 1, maxes.length)
		assert_equal(xs.length - k + 1, mins.length)
		int start = 0
		while (start + k <= xs.length):
			assert_equal(reference_extreme(xs, start, k, 1), maxes[start])
			assert_equal(reference_extreme(xs, start, k, 0), mins[start])
			start = start + 1
		list_free[int](maxes)
		list_free[int](mins)
		k = k + 1
	list_free[int](xs)


void test_window_sum():
	list[int] xs = list[int]{1, 2, 3, 4, 5}
	list[int] got = window_sum(xs, 2)
	list[int] want = list[int]{3, 5, 7, 9}
	assert_int_list(want, got)
	list_free[int](got)

	list[int] mixed = list[int]{3, -1, 4, -1, 5}
	got = window_sum(mixed, 3)
	list[int] want_mixed = list[int]{6, 2, 8}
	assert_int_list(want_mixed, got)
	list_free[int](got)

	# k = length: one window, the total
	got = window_sum(xs, 5)
	assert_equal(1, got.length)
	assert_equal(15, got[0])
	list_free[int](got)

	# k = 1: identity
	got = window_sum(mixed, 1)
	assert_int_list(mixed, got)
	list_free[int](got)


void test_window_mean():
	list[int] xs = list[int]{1, 2, 3, 4}
	list[float] got = window_mean(xs, 2)
	assert_equal(3, got.length)
	assert_near(1.5, got[0])
	assert_near(2.5, got[1])
	assert_near(3.5, got[2])
	list_free[float](got)

	list[int] negatives = list[int]{-3, 3, -3, 3}
	got = window_mean(negatives, 4)
	assert_equal(1, got.length)
	assert_near(0.0, got[0])
	list_free[float](got)


void test_window_sum_float():
	list[float] xs = list[float]{0.5, 1.5, 2.5, 3.5}
	list[float] got = window_sum_float(xs, 2)
	assert_equal(3, got.length)
	assert_near(2.0, got[0])
	assert_near(4.0, got[1])
	assert_near(6.0, got[2])
	list_free[float](got)


void test_window_sum_float_compensation():
	# stats_sum's cancellation case as a single window: a naive running
	# total collapses to 0.0 because 1e8 + 1.0 rounds to 1e8 in float32.
	list[float] cancel = list[float]{100000000.0, 1.0, -100000000.0}
	list[float] got = window_sum_float(cancel, 3)
	assert_equal(1, got.length)
	assert_near(1.0, got[0])
	list_free[float](got)


void test_window_sum_float_sliding_after_cancellation():
	# once the huge values have left the window, the compensation term
	# has recaptured the small addends a naive running subtract loses:
	# {0.25, 0.5} and {0.5, 0.125} come out exact even though 0.25 and
	# 0.5 were completely absorbed while -1e8 sat in the total
	list[float] xs = list[float]{100000000.0, -100000000.0, 0.25, 0.5, 0.125}
	list[float] got = window_sum_float(xs, 2)
	assert_equal(4, got.length)
	assert_near(0.0, got[0])
	# window {-1e8, 0.25}: -99999999.75 rounds to -1e8 in float32
	assert_near(-100000000.0, got[1])
	assert_near(0.75, got[2])
	assert_near(0.625, got[3])
	list_free[float](got)


void test_window_mean_float():
	list[float] xs = list[float]{1.0, 2.0, 3.0, 4.0}
	list[float] got = window_mean_float(xs, 2)
	assert_equal(3, got.length)
	assert_near(1.5, got[0])
	assert_near(2.5, got[1])
	assert_near(3.5, got[2])
	list_free[float](got)

	got = window_mean_float(xs, 4)
	assert_equal(1, got.length)
	assert_near(2.5, got[0])
	list_free[float](got)


void test_window_sum_matches_float_on_int_values():
	# integer-valued floats: the int and float paths agree exactly
	list[int] xs = list[int]{7, -2, 9, 4, -5, 1}
	list[float] fs = new list[float]
	int i = 0
	while (i < xs.length):
		float v = xs[i]
		fs.push(v)
		i = i + 1
	int k = 1
	while (k <= xs.length):
		list[int] want = window_sum(xs, k)
		list[float] got = window_sum_float(fs, k)
		assert_equal(want.length, got.length)
		int j = 0
		while (j < want.length):
			float w = want[j]
			assert_near(w, got[j])
			j = j + 1
		list_free[int](want)
		list_free[float](got)
		k = k + 1
	list_free[float](fs)
