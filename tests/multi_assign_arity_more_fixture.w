# Parallel assignment (issue #360 item 6, grammar/multi_assign.w)
# requires equal arity on both sides: more values than targets is a
# compile error naming both counts.
# expect_fail
# expect_stderr: multi-assignment arity mismatch: 2 targets but 3 values
int main():
	int a
	int b
	a, b = 1, 2, 3
	return 0
