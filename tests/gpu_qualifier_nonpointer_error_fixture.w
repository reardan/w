# The gpu qualifier only marks pointers into device memory; a gpu
# scalar has no meaning in host code. Asserted by bin/wfixture in the
# cuda_diagnostics_test target.
# expect_fail
# expect_stderr: the gpu qualifier requires a pointer type: 'gpu T*'
int main(int argc, int argv):
	gpu int x = 0
	return x
