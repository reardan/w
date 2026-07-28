# Every element on the left of a parallel assignment must be an
# assignable lvalue, checked with the same message as plain '='
# (grammar/multi_assign.w).
# expect_fail
# expect_stderr: assignment target is not assignable
int main():
	int a
	a, 3 = 1, 2
	return 0
