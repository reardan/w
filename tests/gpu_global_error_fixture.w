# Device (PTX) bodies cannot reach host globals: the module's data
# segment lives in host memory, not on the GPU. Compiled with the x64
# selector by the cuda_diagnostics_test target.
int counter

kernel bad(int* v, int n):
	int i = thread_idx()
	if i < n:
		v[i] = counter

int main():
	return 0
