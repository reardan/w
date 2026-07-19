# 'gpu for' maps thread indexes onto [start, end) directly: the
# one- and two-argument range forms are supported, but a step argument
# is not (future work).
# wfixture: x64
# expect_fail
# expect_stderr: 'gpu for' supports only range(end) and range(start, end)
import lib.lib
import lib.cuda

int main(int argc, int argv):
	int n = 8
	gpu for int i in range(0, n, 2):
		pass
	return 0
