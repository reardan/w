# The launch path passes exactly one 8-byte cell per declared kernel
# parameter, so an argument-count mismatch is a hard error (a plain
# function call only warns).
# wfixture: x64
# expect_fail
# expect_stderr: kernel 'add' expects 2 arguments, got 1
import lib.cuda

kernel add(int* v, int n):
	int i = thread_idx()
	if i < n:
		v[i] = v[i] + 1

int main():
	launch add[1, 1](0)
	return 0
