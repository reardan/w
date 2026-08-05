# ndarray elements on a multi-assignment's left side are rejected like
# map/set elements (grammar/multi_assign.w): the pending write path
# would need its own deferred emission; spell them as separate
# statements.
# expect_fail
# expect_stderr: multi-assignment does not support ndarray elements
import lib.ndarray

int main():
	ndf a = ndf_new2(2, 2)
	int x = 0
	a[0, 1], x = 1.5, 2
	return x
