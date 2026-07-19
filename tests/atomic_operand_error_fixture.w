# float64 atomics need sm_60 and the embedded module targets sm_52, so
# only int* and float32* atomic targets are accepted.
# wfixture: x64
# expect_fail
# expect_stderr: gpu atomics require an int* or float32* first argument
kernel bad(float64* v, int n):
	int i = thread_idx()
	if i < n:
		atomic_add(v, 1.0)

int main(int argc, int argv):
	return 0
