# 'w check --lint' semantic rules (compiler/lint.w): every function
# below trips exactly one rule. A plain 'w check' must stay silent on
# this file; lint_test runs it both ways and freezes the message text.
# No imports besides lib.lib, which is imported twice on purpose.
import lib.lib
import lib.lib


int unused_local(int a):
	int never_read = a + 1
	return a


int unreachable(int a):
	return a
	a = a + 1


int shadow_local(int a):
	int total = a
	if (a > 0):
		int total = 2
		a = a + total
	return a + total


int shadow_parameter(int a):
	if (a > 0):
		int a = 3
		return a
	return 0


int assign_condition(int a):
	if (a = 2):
		return 1
	while (a = 0):
		pass
	return 0


int self_assign(int a):
	a = a
	return a


int main():
	int sum = unused_local(1) + unreachable(1) + shadow_local(1)
	return sum + shadow_parameter(1) + assign_condition(1) + self_assign(1)
