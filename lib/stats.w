/*
lib.stats: descriptive statistics over list[float].

float32-only so every target is covered: float64 is a compile error on
the default 32-bit target. Everything is stats_-prefixed because imports
merge into one flat global namespace and lib/math.w already owns
min/max/abs. Float helpers (fsqrt, fabs, bit casts) come from lib.fmath.

Domain errors (empty input, count <= ddof, quantile outside [0, 1]) are
fatal asserts, matching the __w_list_min precedent: a silent 0.0 would be
indistinguishable from a real result. NaN inputs are garbage-in/
garbage-out — NaN relationals evaluate false in every direction on both
targets, so a NaN never replaces a running min/max and sorts to an
arbitrary position; callers can pre-filter with fis_nan from lib.fmath.

Design and phasing: docs/projects/stats.md.
*/
import lib.lib
import lib.assert
import lib.container
import lib.fmath


# Streaming accumulator: push samples one at a time, read count/mean/
# min/max straight off the fields at any point (fields shadow method
# sugar, so stored state has no accessor functions). Derived values come
# from stats_acc_variance/stats_acc_stddev.
struct stats_acc:
	int count
	float mean
	float m2
	float min
	float max


# Zero every field; doubles as the reset. Works on stack values:
# stats_acc a, then a.init().
void stats_acc_init(stats_acc* a):
	a.count = 0
	a.mean = 0.0
	a.m2 = 0.0
	a.min = 0.0
	a.max = 0.0


# Welford single-pass update: numerically stable running mean and sum of
# squared deviations (m2), with min/max tracked alongside.
void stats_acc_add(stats_acc* a, float x):
	if (a.count == 0):
		a.min = x
		a.max = x
	else:
		if (x < a.min):
			a.min = x
		if (x > a.max):
			a.max = x
	a.count = a.count + 1
	float n = a.count
	float delta = x - a.mean
	a.mean = a.mean + delta / n
	a.m2 = a.m2 + delta * (x - a.mean)


# Chan parallel combine of b into a (b is unchanged): accumulators built
# over chunks of a stream merge into the same result as one pass over
# the whole stream.
void stats_acc_merge(stats_acc* a, stats_acc* b):
	if (b.count == 0):
		return
	if (a.count == 0):
		a.count = b.count
		a.mean = b.mean
		a.m2 = b.m2
		a.min = b.min
		a.max = b.max
		return
	float na = a.count
	float nb = b.count
	float n = na + nb
	float delta = b.mean - a.mean
	a.m2 = a.m2 + b.m2 + delta * delta * (na * nb / n)
	a.mean = a.mean + delta * (nb / n)
	a.count = a.count + b.count
	if (b.min < a.min):
		a.min = b.min
	if (b.max > a.max):
		a.max = b.max


# Population (ddof = 0) or sample (ddof = 1) variance of the samples
# added so far; the roundoff clamp keeps tiny negative m2 out.
float stats_acc_variance(stats_acc* a, int ddof = 0):
	asserts(c"stats: variance requires count > ddof", a.count > ddof)
	float denom = a.count - ddof
	float v = a.m2 / denom
	if (v < 0.0):
		return 0.0
	return v


float stats_acc_stddev(stats_acc* a, int ddof = 0):
	return fsqrt(stats_acc_variance(a, ddof))


# Neumaier-compensated sum (same cost as Kahan, also covers the case
# where the next element outweighs the running total). The built-in
# l.sum() rejects float elements, and a plain loop loses low-order bits
# once the total outgrows the addends. The empty list sums to 0.0.
float stats_sum(list[float] xs):
	float total = 0.0
	float comp = 0.0
	int i = 0
	while (i < xs.length):
		float x = xs[i]
		float t = total + x
		if (fabs(total) >= fabs(x)):
			comp = comp + ((total - t) + x)
		else:
			comp = comp + ((x - t) + total)
		total = t
		i = i + 1
	return total + comp


float stats_mean(list[float] xs):
	asserts(c"stats: mean of empty list", xs.length > 0)
	float n = xs.length
	return stats_sum(xs) / n


float stats_min(list[float] xs):
	asserts(c"stats: min of empty list", xs.length > 0)
	float best = xs[0]
	int i = 1
	while (i < xs.length):
		if (xs[i] < best):
			best = xs[i]
		i = i + 1
	return best


float stats_max(list[float] xs):
	asserts(c"stats: max of empty list", xs.length > 0)
	float best = xs[0]
	int i = 1
	while (i < xs.length):
		if (xs[i] > best):
			best = xs[i]
		i = i + 1
	return best


# Corrected two-pass variance (Chan/Golub/LeVeque): mean first, then sum
# of squared deviations minus the compensation term. Immune to the
# catastrophic cancellation of the naive E[x^2] - mean^2 formula on
# offset data; the clamp absorbs roundoff driving the result negative.
float stats_variance(list[float] xs, int ddof = 0):
	asserts(c"stats: variance requires length > ddof", xs.length > ddof)
	float m = stats_mean(xs)
	float s2 = 0.0
	float comp = 0.0
	int i = 0
	while (i < xs.length):
		float d = xs[i] - m
		s2 = s2 + d * d
		comp = comp + d
		i = i + 1
	float n = xs.length
	float denom = xs.length - ddof
	float v = (s2 - comp * comp / n) / denom
	if (v < 0.0):
		return 0.0
	return v


float stats_stddev(list[float] xs, int ddof = 0):
	return fsqrt(stats_variance(xs, ddof))


# Sift the root of the subtree at index start down a max-heap over
# xs[0 .. n-1]. Internal helper for stats_sort.
void stats_sift_down(list[float] xs, int start, int n):
	int root = start
	while (root * 2 + 1 < n):
		int child = root * 2 + 1
		# && so xs[child + 1] is never evaluated out of heap bounds
		if ((child + 1 < n) && (xs[child] < xs[child + 1])):
			child = child + 1
		if (xs[root] < xs[child]):
			float t = xs[root]
			xs[root] = xs[child]
			xs[child] = t
			root = child
		else:
			return


# In-place ascending heapsort: O(n log n), no allocation, no recursion.
# The built-in l.sort() rejects float elements, and the __w_list_*
# insertion sorts are O(n^2). Termination depends only on index
# arithmetic, so incoherent NaN comparisons cannot hang it.
void stats_sort(list[float] xs):
	int n = xs.length
	int start = n / 2 - 1
	while (start >= 0):
		stats_sift_down(xs, start, n)
		start = start - 1
	int end = n - 1
	while (end > 0):
		float t = xs[0]
		xs[0] = xs[end]
		xs[end] = t
		stats_sift_down(xs, 0, end)
		end = end - 1


# Ascending copy; xs is untouched. The caller owns the result (free with
# list_free[float] from lib.container).
list[float] stats_sorted(list[float] xs):
	list[float] out = new list[float]
	int i = 0
	while (i < xs.length):
		out.push(xs[i])
		i = i + 1
	stats_sort(out)
	return out


# Hyndman-Fan type 7 quantile (the numpy/Python default) over an already
# sorted list: h = q * (n - 1), linear interpolation between the
# neighbors of h. Truncation is floor here because h >= 0.
float stats_quantile_sorted(list[float] xs, float q):
	asserts(c"stats: quantile of empty list", xs.length > 0)
	asserts(c"stats: quantile q outside [0, 1]", (q >= 0.0) & (q <= 1.0))
	float nm1 = xs.length - 1
	float h = q * nm1
	int lo = h
	if (lo >= xs.length - 1):
		return xs[xs.length - 1]
	float flo = lo
	float frac = h - flo
	return xs[lo] + frac * (xs[lo + 1] - xs[lo])


# Quantile of an unsorted list; sorts a private copy.
float stats_quantile(list[float] xs, float q):
	list[float] tmp = stats_sorted(xs)
	float result = stats_quantile_sorted(tmp, q)
	list_free[float](tmp)
	return result


float stats_median(list[float] xs):
	return stats_quantile(xs, 0.5)


# Most frequent value via a longest-run scan of a sorted copy; the
# smallest value wins ties (the scan replaces the best run only on a
# strictly longer one). Grouping is float equality on sorted neighbors,
# which keeps float map keys (raw-bit compared) out of the picture.
float stats_mode(list[float] xs):
	asserts(c"stats: mode of empty list", xs.length > 0)
	list[float] tmp = stats_sorted(xs)
	float best = tmp[0]
	int best_run = 1
	float current = tmp[0]
	int run = 1
	int i = 1
	while (i < tmp.length):
		if (tmp[i] == current):
			run = run + 1
		else:
			current = tmp[i]
			run = 1
		if (run > best_run):
			best_run = run
			best = current
		i = i + 1
	list_free[float](tmp)
	return best
