# S2.2b: blocks, if/elif/else chains, conditions and while loops parsed
# (header first), then emitted by the retained walk (--ast-emit-retained).
# Compiled in both modes by ast_retained_emit_test, which requires
# identical images and diagnostics: the conditions below draw warnings
# (and, on the check --lint leg, assignment-in-condition, unreachable-code
# and unused-local lint) that the walk emits from the header's phases.
int control_trace

void control_mark(int n):
	control_trace = control_trace * 10 + n

bool control_true(int n):
	control_mark(n)
	return true

# elif chains of every shape, same-line and block arms, braces.
int control_classify(int n):
	defer control_mark(9)
	if n < 0:
		if n < -5: return -2
		else: return -1
	elif n == 0: return 0
	elif (n == 1) { return 10; }
	elif n == 2:
		int unused = n
		return 20
	else {
		int doubled = n * 2
		if doubled > 100: return 100
		return doubled
	}

# Conditions with warnings: bitwise operators on bool operands, an
# assignment used as the condition, a constant-true loop.
int control_conditions(int n):
	int total = 0
	bool a = n > 1
	bool b = n > 2
	if a | b: total = total + 1
	if (a & control_true(1)): total = total + 2
	int k = 0
	while (k = k + 1) < 4:
		if k == 2: continue
		total = total + k
	while true:
		total = total + 100
		if total > 300: break
	while 1:
		break
	return total

# Nested blocks, an empty block, a loop whose body is a brace block, a
# while with a same-line body and an else on the next line.
int control_blocks(int n):
	int sum = 0
	{
		int inner = n
		{
			sum = sum + inner
		}
	}
	if n > 100:
	sum = sum + 1
	int i = 0
	while i < n {
		i = i + 1
		if i % 2: continue
		sum = sum + i
	}
	while i > 0: i = i - 1
	if sum > 1000: return 0
	else:
		return sum
		sum = 0
	return -1

# A generic body and a defer in nested scopes.
T control_pick[T](T a, T b, int first):
	if first: return a
	elif first == 0:
		return b
	return a

int main():
	if (control_classify(-7) != -2): return 1
	if (control_classify(-1) != -1): return 2
	if (control_classify(0) != 0): return 3
	if (control_classify(1) != 10): return 4
	if (control_classify(2) != 20): return 5
	if (control_classify(9) != 18): return 6
	if (control_conditions(3) != 307): return 7
	if (control_blocks(6) != 19): return 8
	if (control_pick[int](3, 4, 0) != 4): return 9
	if (control_trace == 0): return 10
	return 0
