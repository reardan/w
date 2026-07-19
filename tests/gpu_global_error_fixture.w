# Device (PTX) bodies cannot reach host globals: the module's data
# segment lives in host memory, not on the GPU.
# wfixture: x64
# expect_fail
# expect_stderr: global variables are not accessible in gpu code
int counter

kernel bad(int* v, int n):
	int i = thread_idx()
	if i < n:
		v[i] = counter

int main():
	return 0
