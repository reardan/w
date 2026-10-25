# Differential fixture for bin/wllvm: calls past the symbol table's
# parameter-type slots (their types come from the definition), a wide
# function value called indirectly (System V, since one is a value here),
# and narrow indirect calls (pushed in native order as well). Exits 78.
type wide_fn = fn(int, int, int, int, int, int, int, int) -> int
type pair_fn = fn(int, int) -> int


int wide(int a, int b, int c, int d, int e, int g, int h, int i, int j, int k, int l, int m):
	return a + b + c + d + e + g + h + i + j + k + l + m


int wide8(int a, int b, int c, int d, int e, int g, int h, int i):
	return a * 1 + b * 2 + c * 3 + d * 4 + e * 5 + g * 6 + h * 7 + i * 8


int minus(int a, int b): return a - b


int main():
	int direct = wide(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
	wide_fn* f = wide8
	if (f(8, 7, 6, 5, 4, 3, 2, 1) != 120): return 3
	pair_fn* p = minus
	if (p(10, 3) != 7): return 1
	return direct
