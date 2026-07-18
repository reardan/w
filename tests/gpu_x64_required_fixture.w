# gpu kernels imply the x64 Linux host (libcuda.so is 64-bit only):
# the default 32-bit target rejects the declaration at parse time.
# expect_fail
# expect_stderr: gpu kernels require the x64 target
kernel add(int* v, int n):
	int i = thread_idx()
	if i < n:
		v[i] = v[i] + 1

int main():
	return 0
