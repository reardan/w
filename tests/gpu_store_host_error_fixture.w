# Writing through a 'gpu T*' in host code (unary '*' here; indexing and
# struct fields take the same check). Asserted by bin/wfixture in the
# cuda_diagnostics_test target.
# expect_fail
# expect_stderr: cannot dereference a gpu pointer in host code
import lib.lib


int main(int argc, int argv):
	gpu int* d = cast(gpu int*, malloc(16))
	*d = 5
	return 0
