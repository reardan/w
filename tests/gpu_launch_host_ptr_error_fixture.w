# A kernel's 'gpu T*' parameter promises device memory, so launching it
# with a plain host pointer is the host/device crossing error (the
# reverse is allowed: a plain kernel pointer parameter accepts a 'gpu
# T*', since kernels already take managed memory through plain ones).
# Asserted by bin/wfixture in the cuda_diagnostics_test target.
# wfixture: x64
# expect_fail
# expect_stderr: function 'bump' argument 1 mixes gpu and host pointers: expected 'gpu int*', got 'int*'
# reject_stderr: argument 2
import lib.cuda

kernel bump(gpu int* v, int* w, int n):
	int i = thread_idx()
	if i < n:
		v[i] = v[i] + w[i]

int main():
	gpu int* d = cast(gpu int*, gpu_device_alloc(64))
	int* h = cast(int*, gpu_alloc(64))
	launch bump[1, 8](h, d, 8)
	return 0
