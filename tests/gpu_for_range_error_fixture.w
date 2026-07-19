# 'gpu for' maps thread indexes onto [start, end) directly: the
# one- and two-argument range forms are supported, but a step argument
# is not (future work). Compiled with the x64 selector by the
# cuda_diagnostics_test target.
import lib.lib
import lib.cuda

int main(int argc, int argv):
	int n = 8
	gpu for int i in range(0, n, 2):
		pass
	return 0
