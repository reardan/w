# The launch path passes exactly one 8-byte cell per declared kernel
# parameter, so an argument-count mismatch is a hard error (a plain
# function call only warns). Compiled with the x64 selector by the
# cuda_diagnostics_test target.
import lib.cuda

kernel add(int* v, int n):
	int i = thread_idx()
	if i < n:
		v[i] = v[i] + 1

int main():
	launch add[1, 1](0)
	return 0
