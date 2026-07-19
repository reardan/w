# 'launch' emits calls into the lib.cuda host runtime; without the
# import there is nothing to call (the lib.generator precedent).
# wfixture: x64
# expect_fail
# expect_stderr: gpu code requires 'import lib.cuda'
kernel add(int* v, int n):
	int i = thread_idx()
	if i < n:
		v[i] = v[i] + 1

int main():
	launch add[1, 1](0, 0)
	return 0
