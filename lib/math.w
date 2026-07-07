int min(int a, int b):
	if (a < b):
		return a
	return b


int max(int a, int b):
	if (a > b):
		return a
	return b


int abs(int a):
	if (a < 0):
		return 0 - a
	return a


# -1, 0 or 1 by the sign of a.
int sign(int a):
	if (a < 0):
		return 0 - 1
	if (a > 0):
		return 1
	return 0


# Greatest common divisor (Euclid); gcd(0, 0) is 0, negatives fold to
# their absolute values.
int gcd(int a, int b):
	a = abs(a)
	b = abs(b)
	while (b != 0):
		int t = b
		b = a % b
		a = t
	return a


# Integer exponentiation by squaring; negative exponents return 0
# (integer division semantics).
int pow(int base, int exponent):
	if (exponent < 0):
		return 0
	int result = 1
	while (exponent > 0):
		if (exponent % 2 == 1):
			result = result * base
		base = base * base
		exponent = exponent / 2
	return result
