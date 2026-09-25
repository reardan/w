# void* is the host domain's untyped pointer: it does not launder a
# 'gpu T*' across the boundary ('gpu void*' is the device-side one).
# Asserted by bin/wfixture in the cuda_diagnostics_test target.
# expect_fail
# expect_stderr: assignment mixes gpu and host pointers: expected 'void*', got 'gpu int*'
import lib.lib


int main(int argc, int argv):
	gpu int* d = cast(gpu int*, malloc(16))
	void* v = 0
	v = d
	return cast(int, v)
