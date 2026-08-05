# The comma-index sugar checks its operands like the spelled-out
# accessor calls it lowers to (grammar/ndarray_index.w): indices are
# coerced and checked against the accessors' int parameters, the
# assigned value against the setter's value parameter, each with its
# own frozen warning context.
# expect_stderr: warning: ndarray index type mismatch: expected 'int', got 'char*'
# expect_stderr: warning: ndarray assignment type mismatch: expected 'float', got 'char*'
import lib.ndarray

int main():
	ndf a = ndf_new2(2, 2)
	a[0, c"x"] = 1.0
	a[0, 1] = c"y"
	return 0
