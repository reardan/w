# Integer helpers for word-sized W integers.
#
# Overflow policy: gcd/isqrt never overflow for supported inputs except the
# native two's-complement edge case abs(INT_MIN), which wraps like normal W
# integer arithmetic. lcm/comb/perm return 0 when the mathematically positive
# result would exceed a signed 32-bit int, or when inputs are invalid.

int math_abs_int(int value):
	if (value < 0):
		return 0 - value
	return value


int math_mul_overflows_positive(int a, int b):
	if ((a < 0) | (b < 0)):
		return 1
	if ((a == 0) | (b == 0)):
		return 0
	return a > 2147483647 / b


int math_gcd(int a, int b):
	a = math_abs_int(a)
	b = math_abs_int(b)
	while (b != 0):
		int t = a % b
		a = b
		b = t
	return a


int math_lcm(int a, int b):
	if ((a == 0) | (b == 0)):
		return 0
	int left = math_abs_int(a / math_gcd(a, b))
	int right = math_abs_int(b)
	if (math_mul_overflows_positive(left, right)):
		return 0
	return left * right


int math_isqrt(int n):
	if (n < 0):
		return -1
	if (n < 2):
		return n
	int lo = 1
	int hi = n / 2 + 1
	if (hi > 46340):
		hi = 46340
	int answer = 1
	while (lo <= hi):
		int mid = lo + (hi - lo) / 2
		if (mid <= n / mid):
			answer = mid
			lo = mid + 1
		else:
			hi = mid - 1
	return answer


int math_comb(int n, int k):
	if ((n < 0) | (k < 0) | (k > n)):
		return 0
	if (k > n - k):
		k = n - k
	int result = 1
	int i = 1
	while (i <= k):
		int numerator = n - k + i
		int denominator = i
		int g = math_gcd(result, denominator)
		result = result / g
		denominator = denominator / g
		g = math_gcd(numerator, denominator)
		numerator = numerator / g
		denominator = denominator / g
		if (math_mul_overflows_positive(result, numerator)):
			return 0
		result = result * numerator
		if (denominator != 1):
			result = result / denominator
		i = i + 1
	return result


int math_perm(int n, int k):
	if ((n < 0) | (k < 0) | (k > n)):
		return 0
	int result = 1
	int i = 0
	while (i < k):
		int factor = n - i
		if (math_mul_overflows_positive(result, factor)):
			return 0
		result = result * factor
		i = i + 1
	return result
