# Parallel assignment (issue #360 item 6, grammar/multi_assign.w)
# requires equal arity on both sides: fewer values than targets is a
# compile error naming both counts.
# expect_fail
# expect_stderr: multi-assignment arity mismatch: 3 targets but 2 values
int main():
	int a
	int b
	int c
	a, b, c = 1, 2
	return 0
