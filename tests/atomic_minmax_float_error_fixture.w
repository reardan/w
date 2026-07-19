# PTX has no float atom.min/max at the module's sm_52 target: only
# atomic_add supports float32 operands. Compiled with the x64 selector
# by the cuda_diagnostics_test target.
kernel bad(float32* v, int n):
	int i = thread_idx()
	if i < n:
		atomic_min(v, 1.0)

int main(int argc, int argv):
	return 0
