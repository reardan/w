# A kernel's body lives in the PTX module, not at a host code address:
# calling it like a function can only be a miscall.
# wfixture: x64
# expect_fail
# expect_stderr: kernels cannot be called; use 'launch'
kernel add(int* v, int n):
	int i = thread_idx()
	if i < n:
		v[i] = v[i] + 1

int main():
	int x = 5
	add(&x, 1)
	return 0
