# Reading through a 'gpu T*' in host code: device memory from
# gpu_device_alloc is not mapped into the host address space, so the
# load is rejected at compile time. Asserted by bin/wfixture in the
# cuda_diagnostics_test target.
# expect_fail
# expect_stderr: cannot dereference a gpu pointer in host code; copy the data with gpu_memcpy_from, or cast() to a host pointer for managed memory
import lib.lib


int main(int argc, int argv):
	gpu float32* d = cast(gpu float32*, malloc(16))
	float32 x = d[1]
	return cast(int, x)
