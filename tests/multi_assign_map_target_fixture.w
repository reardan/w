# A map element on the left of a parallel assignment is rejected (v1,
# grammar/multi_assign.w): the pending-slot write path would need its
# own deferred emission; spell it as separate statements.
# expect_fail
# expect_stderr: multi-assignment does not support map or set elements
int main():
	map[int, int] m
	int x
	m[1], x = 1, 2
	return 0
