import lib.testing
import lib.format
import lib.container
import lib.stats


# Same tolerance as lib/fmath_test.w: well within what float32 callers
# need, loose enough to absorb iteration truncation.
void assert_near(float want, float got):
	if (fabs(want - got) > 0.0001):
		print2(c"Assertion failed. wanted float(")
		print2(ftoa(want))
		print2(c") got float(")
		print2(ftoa(got))
		println2(c")")
		exit(1)


void assert_float_bits(int want, float got):
	assert_equal_hex(want, float_bits(got))


void test_sum():
	list[float] xs = list[float]{1.5, 2.25, 3.25}
	assert_float_bits(0x40e00000, stats_sum(xs))    # exactly 7.0

	list[float] empty = list[float]{}
	assert_float_bits(0x00000000, stats_sum(empty))

	# Neumaier compensation: the naive running total collapses to 0.0
	# because 1e8 + 1.0 rounds to 1e8 in float32.
	list[float] cancel = list[float]{100000000.0, 1.0, -100000000.0}
	assert_near(1.0, stats_sum(cancel))


void test_mean():
	list[float] xs = list[float]{1.0, 2.0, 3.0, 4.0}
	assert_near(2.5, stats_mean(xs))

	list[float] one = list[float]{7.5}
	assert_near(7.5, stats_mean(one))

	list[float] negative = list[float]{-3.0, 3.0}
	assert_near(0.0, stats_mean(negative))


void test_min_max():
	list[float] xs = list[float]{2.5, -1.5, 4.0, 0.5}
	assert_near(-1.5, stats_min(xs))
	assert_near(4.0, stats_max(xs))

	list[float] one = list[float]{3.25}
	assert_near(3.25, stats_min(one))
	assert_near(3.25, stats_max(one))


void test_variance():
	# population variance of {1, 2, 3, 4} is 1.25; sample is 5/3
	list[float] xs = list[float]{1.0, 2.0, 3.0, 4.0}
	assert_near(1.25, stats_variance(xs))
	assert_near(1.6666667, stats_variance(xs, 1))
	assert_near(1.1180339, stats_stddev(xs))
	assert_near(1.2909944, stats_stddev(xs, 1))

	# single element: population variance is 0
	list[float] one = list[float]{42.0}
	assert_near(0.0, stats_variance(one))

	# constant data: exactly zero, the clamp guards roundoff
	list[float] flat = list[float]{5.0, 5.0, 5.0}
	assert_near(0.0, stats_variance(flat))


# The 1e6-offset set: deviations are {-1, 0, +1}, so the population
# variance is 2/3. The naive E[x^2] - mean^2 formula loses all
# significance at this offset in float32; the corrected two-pass keeps
# full precision because 1e6 + 3 is still exact in a 24-bit mantissa.
void test_variance_offset():
	list[float] xs = list[float]{1000001.0, 1000002.0, 1000003.0}
	assert_near(0.6666667, stats_variance(xs))
	assert_near(1000002.0, stats_mean(xs))


void test_acc():
	stats_acc a
	a.init()
	assert_equal(0, a.count)
	a.add(1.0)
	a.add(2.0)
	a.add(3.0)
	a.add(4.0)
	assert_equal(4, a.count)
	assert_near(2.5, a.mean)
	assert_near(1.0, a.min)
	assert_near(4.0, a.max)
	# default ddof through method sugar and explicit ddof agree with the
	# batch functions
	assert_near(1.25, a.variance())
	assert_near(1.6666667, a.variance(1))
	assert_near(1.1180339, a.stddev())

	# reset via init
	a.init()
	a.add(-2.5)
	assert_equal(1, a.count)
	assert_near(-2.5, a.mean)
	assert_near(-2.5, a.min)
	assert_near(-2.5, a.max)
	assert_near(0.0, a.variance())


void test_acc_matches_batch():
	list[float] xs = list[float]{0.5, -1.25, 3.75, 2.0, -0.5, 1.25}
	stats_acc a
	a.init()
	int i = 0
	while (i < xs.length):
		a.add(xs[i])
		i = i + 1
	assert_near(stats_mean(xs), a.mean)
	assert_near(stats_min(xs), a.min)
	assert_near(stats_max(xs), a.max)
	assert_near(stats_variance(xs), a.variance())
	assert_near(stats_variance(xs, 1), a.variance(1))


void test_acc_merge():
	# merge of two halves equals one pass over the whole
	stats_acc whole
	whole.init()
	stats_acc left
	left.init()
	stats_acc right
	right.init()
	list[float] xs = list[float]{1.5, -2.0, 3.25, 0.75, 4.5, -1.25}
	int i = 0
	while (i < xs.length):
		whole.add(xs[i])
		if (i < 3):
			left.add(xs[i])
		else:
			right.add(xs[i])
		i = i + 1
	left.merge(&right)
	assert_equal(whole.count, left.count)
	assert_near(whole.mean, left.mean)
	assert_near(whole.min, left.min)
	assert_near(whole.max, left.max)
	assert_near(whole.variance(1), left.variance(1))

	# merging an empty accumulator changes nothing
	stats_acc empty
	empty.init()
	left.merge(&empty)
	assert_equal(whole.count, left.count)
	assert_near(whole.mean, left.mean)

	# merging into an empty accumulator copies
	empty.merge(&whole)
	assert_equal(whole.count, empty.count)
	assert_near(whole.mean, empty.mean)
	assert_near(whole.variance(), empty.variance())


void assert_ascending(list[float] xs):
	int i = 1
	while (i < xs.length):
		assert1(xs[i - 1] <= xs[i])
		i = i + 1


void test_sort():
	list[float] reversed = list[float]{5.0, 4.0, 3.0, 2.0, 1.0}
	stats_sort(reversed)
	assert_ascending(reversed)
	assert_near(1.0, reversed[0])
	assert_near(5.0, reversed[4])

	list[float] dupes = list[float]{2.5, -1.0, 2.5, 0.0, -1.0, 7.5}
	stats_sort(dupes)
	assert_ascending(dupes)
	assert_near(-1.0, dupes[0])
	assert_near(-1.0, dupes[1])
	assert_near(7.5, dupes[5])

	list[float] one = list[float]{3.0}
	stats_sort(one)
	assert_near(3.0, one[0])

	list[float] empty = list[float]{}
	stats_sort(empty)
	assert_equal(0, empty.length)

	list[float] sorted = list[float]{1.0, 2.0, 3.0}
	stats_sort(sorted)
	assert_ascending(sorted)


void test_sorted_copy():
	list[float] xs = list[float]{3.0, 1.0, 2.0}
	list[float] out = stats_sorted(xs)
	assert_ascending(out)
	# the input is untouched
	assert_near(3.0, xs[0])
	assert_near(1.0, xs[1])
	assert_near(2.0, xs[2])
	list_free[float](out)


void test_quantile():
	list[float] xs = list[float]{4.0, 1.0, 3.0, 2.0}
	# endpoints are min and max
	assert_near(1.0, stats_quantile(xs, 0.0))
	assert_near(4.0, stats_quantile(xs, 1.0))
	# type 7: h = 0.25 * 3 = 0.75 interpolates 1 and 2
	assert_near(1.75, stats_quantile(xs, 0.25))
	assert_near(2.5, stats_quantile(xs, 0.5))

	list[float] one = list[float]{9.0}
	assert_near(9.0, stats_quantile(one, 0.0))
	assert_near(9.0, stats_quantile(one, 0.5))
	assert_near(9.0, stats_quantile(one, 1.0))


void test_median():
	list[float] odd = list[float]{7.0, 1.0, 3.0}
	assert_near(3.0, stats_median(odd))

	list[float] even = list[float]{1.0, 2.0, 3.0, 4.0}
	assert_near(2.5, stats_median(even))


void test_mode():
	list[float] xs = list[float]{1.0, 2.0, 2.0, 3.0}
	assert_near(2.0, stats_mode(xs))

	# tie between 2.0 and 3.0: the smallest wins
	list[float] tie = list[float]{3.0, 2.0, 2.0, 3.0, 1.0}
	assert_near(2.0, stats_mode(tie))

	# all distinct: every run has length 1, the smallest wins
	list[float] distinct = list[float]{5.0, 1.0, 3.0}
	assert_near(1.0, stats_mode(distinct))

	list[float] one = list[float]{4.5}
	assert_near(4.5, stats_mode(one))
