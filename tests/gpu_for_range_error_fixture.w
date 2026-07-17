# The MVP 'gpu for' maps thread indexes 0..n-1 directly: only the
# one-argument range(end) form is supported (start/step are future
# work). Compiled with the x64 selector by the cuda_diagnostics_test
# target.
import lib.lib
import lib.cuda

int main(int argc, int argv):
	int n = 8
	gpu for int i in range(2, n):
		pass
	return 0
