/*
lib.window: sliding-window aggregates over list[int] and list[float].

Every function slides a fixed-size window of k elements across the
input and returns one aggregate per window position, so the result has
xs.length - k + 1 elements. k < 1 is a fatal assert (a nonsensical
window is a caller bug, matching the lib/stats.w domain-error
precedent); an input shorter than k returns the empty list, because
"zero windows" is a real answer, not an error. Results are fresh lists
owned by the caller (free with list_free[int] / list_free[float] from
lib.container). Inputs are never modified.

window_min/window_max are the O(n) monotonic-deque algorithm: the
deque holds indices of candidates in dominance order, each index is
pushed and popped at most once. Everything is window_-prefixed because
imports merge into one flat namespace and lib/math.w owns min/max.

Float variants are float32-only, like lib/stats.w, so every target is
covered. window_sum_float slides a Neumaier-compensated running sum
(stats_sum's scheme, applied to both the entering element and the
negated leaving element), so a single window's cancellation error
matches stats_sum rather than a naive running subtract; int sums are
exact until word-size overflow wraps.
*/
import lib.lib
import lib.assert
import lib.container
import lib.fmath


# Shared monotonic-deque scan. want_max picks the dominance direction:
# for a max window, a new element evicts every smaller-or-equal
# candidate behind it; for a min window, every larger-or-equal one.
# The deque lives in a plain index array — each of the n elements is
# pushed at most once, so head/tail never wrap.
list[int] window_extreme(list[int] xs, int k, int want_max):
	asserts(c"window: k must be >= 1", k >= 1)
	list[int] out = new list[int]
	if (xs.length < k):
		return out
	int* candidates = malloc(xs.length * __word_size__)
	int head = 0
	int tail = 0
	int i = 0
	while (i < xs.length):
		# The window slides one step, so at most one index expires.
		if ((head < tail) && (candidates[head] <= i - k)):
			head = head + 1
		# Evict dominated candidates from the back.
		while (head < tail):
			int back = xs[candidates[tail - 1]]
			if (want_max && (back > xs[i])):
				break
			if ((want_max == 0) && (back < xs[i])):
				break
			tail = tail - 1
		candidates[tail] = i
		tail = tail + 1
		if (i >= k - 1):
			out.push(xs[candidates[head]])
		i = i + 1
	free(candidates)
	return out


# Maximum of each k-wide window, O(n) — the "sliding window maximum"
# shape (LeetCode 239).
list[int] window_max(list[int] xs, int k):
	return window_extreme(xs, k, 1)


# Minimum of each k-wide window, O(n).
list[int] window_min(list[int] xs, int k):
	return window_extreme(xs, k, 0)


# Sum of each k-wide window via a running add/subtract; int arithmetic
# is exact until the platform word wraps.
list[int] window_sum(list[int] xs, int k):
	asserts(c"window: k must be >= 1", k >= 1)
	list[int] out = new list[int]
	if (xs.length < k):
		return out
	int total = 0
	int i = 0
	while (i < xs.length):
		total = total + xs[i]
		if (i >= k):
			total = total - xs[i - k]
		if (i >= k - 1):
			out.push(total)
		i = i + 1
	return out


# Mean of each k-wide window of ints, as float32: the window sum stays
# exact in int, only the final divide rounds.
list[float] window_mean(list[int] xs, int k):
	list[int] sums = window_sum(xs, k)
	list[float] out = new list[float]
	float divisor = k
	int i = 0
	while (i < sums.length):
		float total = sums[i]
		out.push(total / divisor)
		i = i + 1
	list_free[int](sums)
	return out


# One Neumaier step: fold x into the running (total, compensation)
# pair; returns the new total, accumulates the rounding error into
# *comp. Same formulation as stats_sum in lib/stats.w.
float window_neumaier_step(float total, float x, float* comp):
	float t = total + x
	if (fabs(total) >= fabs(x)):
		*comp = *comp + ((total - t) + x)
	else:
		*comp = *comp + ((x - t) + total)
	return t


# Sum of each k-wide float window. The running total is Neumaier-
# compensated on both the entering element and the negated leaving
# element, so the first window matches stats_sum exactly and later
# windows avoid the naive running-subtract's unbounded drift; tiny
# residual error can still accumulate over very long slides.
list[float] window_sum_float(list[float] xs, int k):
	asserts(c"window: k must be >= 1", k >= 1)
	list[float] out = new list[float]
	if (xs.length < k):
		return out
	float total = 0.0
	float comp = 0.0
	int i = 0
	while (i < xs.length):
		total = window_neumaier_step(total, xs[i], &comp)
		if (i >= k):
			total = window_neumaier_step(total, 0.0 - xs[i - k], &comp)
		if (i >= k - 1):
			out.push(total + comp)
		i = i + 1
	return out


# Mean of each k-wide float window: window_sum_float divided by k.
list[float] window_mean_float(list[float] xs, int k):
	list[float] out = window_sum_float(xs, k)
	float divisor = k
	int i = 0
	while (i < out.length):
		out[i] = out[i] / divisor
		i = i + 1
	return out
