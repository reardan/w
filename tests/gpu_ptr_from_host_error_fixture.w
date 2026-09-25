# The reverse crossing: a plain host pointer passed for a 'gpu T*'
# parameter is an error too (a device deref of host memory faults).
# Asserted by bin/wfixture in the cuda_diagnostics_test target.
# expect_fail
# expect_stderr: function 'take' argument 1 mixes gpu and host pointers: expected 'gpu int*', got 'int*'; use cast() to cross the host/device boundary
import lib.lib


int take(gpu int* p):
	return cast(int, p)


int main(int argc, int argv):
	int* h = cast(int*, malloc(16))
	return take(h)
