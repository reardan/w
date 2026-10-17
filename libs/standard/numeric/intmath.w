/*
libs.standard.numeric.intmath: Python math's integer helpers --
factorial, comb, perm, isqrt -- on W's word-sized int.

Python ints never overflow; W's int is one machine word (32 bits on the
default target, 64 on x64/arm64), so every function here detects
overflow instead of wrapping. All results are non-negative, which frees
-1 to be the one error value: each function returns -1 when an argument
is negative (Python's ValueError) or when the exact result does not fit
in a positive int (where Python would just grow). Arbitrary-precision
versions belong to the bigint library, not here.

Largest exact results: factorial(12) on 32-bit words, factorial(20) on
64-bit; comb/perm overflow exactly when the true value exceeds
math_int_max(), never earlier (intermediates are kept no larger than the
answer).

Compiles on every target (no float64), unlike lib/fmath64.w, which holds
the float64 half of the P3.6 math extras.
*/
import lib.math


# Largest positive int on this target: 2^31 - 1 or 2^63 - 1.
int math_int_max():
	return ~(1 << (__word_size__ * 8 - 1))


# a * b for a, b >= 0, or -1 when the product exceeds math_int_max().
int math_checked_mul(int a, int b):
	if (a < 0 || b < 0): return -1
	if (a == 0 || b == 0): return 0
	if (a > math_int_max() / b): return -1
	return a * b


# n! (Python math.factorial). -1 for n < 0 or on overflow.
int math_factorial(int n):
	if (n < 0): return -1
	int result = 1
	int i = 2
	while (i <= n):
		result = math_checked_mul(result, i)
		if (result < 0): return -1
		i = i + 1
	return result


# Binomial coefficient C(n, k) = n! / (k! (n - k)!) (Python math.comb):
# 0 when k > n, -1 for a negative argument or on overflow. Builds
# C(n - k + i, i) for i = 1..k, each step exact: dividing the running
# value and i by their gcd first leaves i' coprime to it, so i' divides
# (n - k + i) and the next value is formed without an intermediate
# larger than itself. The partial values only grow, so a step overflows
# exactly when the final answer would.
int math_comb(int n, int k):
	if (n < 0 || k < 0): return -1
	if (k > n): return 0
	if (k > n - k): k = n - k
	int result = 1
	int i = 1
	while (i <= k):
		int g = gcd(result, i)
		int scaled = result / g
		int factor = (n - k + i) / (i / g)
		result = math_checked_mul(scaled, factor)
		if (result < 0): return -1
		i = i + 1
	return result


# Number of k-permutations of n, n! / (n - k)! (Python math.perm(n, k)):
# 0 when k > n, -1 for a negative argument or on overflow. perm(n, n)
# is n!.
int math_perm(int n, int k):
	if (n < 0 || k < 0): return -1
	if (k > n): return 0
	int result = 1
	int i = 0
	while (i < k):
		result = math_checked_mul(result, n - i)
		if (result < 0): return -1
		i = i + 1
	return result


# floor(sqrt(n)) exactly (Python math.isqrt): -1 for n < 0. Digit-by-
# digit (base 4) square root, so no float rounding and no overflow on
# any word size: res + bit never exceeds n.
int math_isqrt(int n):
	if (n < 0): return -1
	int res = 0
	int bit = 1 << (__word_size__ * 8 - 2)
	while (bit > n):
		bit = bit >> 2
	while (bit != 0):
		if (n >= res + bit):
			n = n - (res + bit)
			res = (res >> 1) + bit
		else:
			res = res >> 1
		bit = bit >> 2
	return res
