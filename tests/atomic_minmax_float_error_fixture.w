# PTX has no float atom.min/max at the module's sm_52 target: only
# atomic_add supports float32 operands.
# wfixture: x64
# expect_fail
# expect_stderr: atomic_min/atomic_max require an int* first argument
kernel bad(float32* v, int n):
	int i = thread_idx()
	if i < n:
		atomic_min(v, 1.0)

int main(int argc, int argv):
	return 0
