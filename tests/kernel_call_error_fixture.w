# A kernel's body lives in the PTX module, not at a host code address:
# calling it like a function can only be a miscall. Compiled with the
# x64 selector by the cuda_diagnostics_test target.
kernel add(int* v, int n):
	int i = thread_idx()
	if i < n:
		v[i] = v[i] + 1

int main():
	int x = 5
	add(&x, 1)
	return 0
