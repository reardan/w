/*
lib.edit_distance: string distance metrics over C strings.

Distances are byte-oriented, like everything in lib/str.w: multi-byte
UTF-8 sequences count one unit per byte, not per code point (callers
needing code-point distances can decode with lib/utf8.w first).

A separate module rather than lib/str.w because these are algorithms
with scratch allocations, not thin non-mutating string conveniences —
str.w consumers should not pay for DP buffers they never use.
*/
import lib.lib
import lib.assert


# Levenshtein distance: the minimum number of single-byte insertions,
# deletions and substitutions turning a into b. Classic two-row dynamic
# program — O(m * n) time, O(min(m, n)) memory: the column string is
# always the shorter one, so the two scratch rows have min(m, n) + 1
# entries each. Symmetric in its arguments; either string may be empty.
int levenshtein(char* a, char* b):
	int m = strlen(a)
	int n = strlen(b)
	# Keep b (the DP row) as the shorter string. The metric is
	# symmetric, so swapping the roles changes nothing but memory.
	if (n > m):
		char* swap_s = a
		a = b
		b = swap_s
		int swap_n = m
		m = n
		n = swap_n
	if (n == 0):
		return m
	# prev[j] / curr[j]: distance from a[0 .. i) to b[0 .. j)
	int* prev = malloc((n + 1) * __word_size__)
	int* curr = malloc((n + 1) * __word_size__)
	int j = 0
	while (j <= n):
		prev[j] = j
		j = j + 1
	int i = 1
	while (i <= m):
		curr[0] = i
		char ca = a[i - 1]
		j = 1
		while (j <= n):
			# substitution (free on a match), deletion, insertion
			int best = prev[j - 1]
			if (ca != b[j - 1]):
				best = best + 1
			if (prev[j] + 1 < best):
				best = prev[j] + 1
			if (curr[j - 1] + 1 < best):
				best = curr[j - 1] + 1
			curr[j] = best
			j = j + 1
		int* swap_row = prev
		prev = curr
		curr = swap_row
		i = i + 1
	int result = prev[n]
	free(prev)
	free(curr)
	return result


# Hamming distance: the number of positions where the equal-length
# strings a and b differ. Returns -1 when the lengths differ — unlike
# the fatal asserts on lib/stats.w domain errors, mismatched lengths
# are a plausible runtime input, and -1 is unambiguous because a real
# distance is never negative. Single pass, no allocation.
int hamming(char* a, char* b):
	int distance = 0
	int i = 0
	while ((a[i] != 0) && (b[i] != 0)):
		if (a[i] != b[i]):
			distance = distance + 1
		i = i + 1
	# One string ended first: unequal lengths (0 versus a live byte).
	if (a[i] != b[i]):
		return -1
	return distance
