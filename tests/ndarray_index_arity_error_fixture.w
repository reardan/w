# The index count selects the accessor arity at compile time and
# lib/ndarray.w is rank <= 4 by design (docs/projects/ndarray.md), so
# a fifth comma-separated index is a compile error.
# expect_fail
# expect_stderr: ndarray index supports at most 4 indices
import lib.ndarray

int main():
	ndf a = ndf_new4(2, 2, 2, 2)
	float v = a[0, 0, 0, 0, 0]
	return 0
