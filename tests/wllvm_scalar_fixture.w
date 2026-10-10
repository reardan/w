# Shared differential input for the production x64 backend and wllvm.
# Every arithmetic operand comes from a parameter or local so lowering
# cannot pass these checks solely through constant folding.
int arithmetic(int a, int b):
	if (a + b != 22): return 1
	if (a - b != 12): return 2
	if (a * b != 85): return 3
	if (-a / b != -3): return 4
	if (-a % b != -2): return 5
	if ((a & b) != 1): return 6
	if ((a | b) != 21): return 7
	if ((a ^ b) != 20): return 8
	if (~b != -6): return 9
	if ((a << 2) != 68): return 10
	if ((-a >> 2) != -5): return 11
	if (!(a > b && a >= b && b < a && b <= a)): return 12
	if (a == b || a != 17): return 13
	return 0


int factorial(int n):
	if (n <= 1): return 1
	return n * factorial(n - 1)


bool positive(int n):
	return n > 0


int choose(int n):
	if (n < 0):
		return 11
	elif (n == 0):
		return 13
	else:
		return 17


int loop_sum(int n):
	int i = 0
	int total = 0
	while i < n:
		i = i + 1
		if (i == 3): continue
		if (i == 8): break
		total = total + i
	return total


int short_circuit(int zero):
	int side = 0
	if (zero && (side = 1)): return 3
	if (1 || (side = 2)):
		if (side != 0): return 4
	if (zero && 10 / zero): return 1
	if (1 || 10 / zero):
		if ((zero || 7) && (2 && 9)): return 0
	return 2


int nested_loops(int limit):
	int result = 0
	int i = 0
	while i < limit:
		i = i + 1
		int j = 0
		while j < limit:
			j = j + 1
			if (j == 2): continue
			if (j == 4): break
			result = result + i
	return result


int pair(int a, int b):
	return a * 10 + b


int default_add(int x = 3):
	return x + 1


int forward(int x);


int main():
	int result = arithmetic(17, 5)
	if (result): return result
	if (factorial(5) != 120): return 20
	if (!positive(4) || positive(-4)): return 21
	if (choose(-2) + choose(0) + choose(2) != 41): return 22
	if (loop_sum(10) != 25): return 23
	if (short_circuit(0)): return 24
	int wide = 1
	wide = wide << 32
	if ((wide >> 32) != 1): return 25
	if (wide + 7 - wide != 7): return 26
	if ((1 << 65) != 2): return 27
	if ((-8 >> 66) != -2): return 28
	if (cast(int, 0xffffffff) != -1): return 29
	int high = 1
	high = high << 63
	if (high + high != 0): return 30
	if (forward(5) != 12): return 31
	if (nested_loops(5) != 30): return 32
	int order = 0
	if (pair(order = order + 1, order = order + 1) != 12): return 33
	int scoped = 7
	if (order):
		int scoped = 11
		if (scoped != 11): return 34
	if (scoped != 7): return 35
	if (default_add() != 4 || default_add(8) != 9): return 36
	return 73


int forward(int x):
	return x + 7
