# float64 atomics need sm_60 and the embedded module targets sm_52, so
# only int* and float32* atomic targets are accepted. Compiled with the
# x64 selector by the cuda_diagnostics_test target.
kernel bad(float64* v, int n):
	int i = thread_idx()
	if i < n:
		atomic_add(v, 1.0)

int main(int argc, int argv):
	return 0
