# 'launch' only accepts kernel symbols: an ordinary function's body is
# host code with a host calling convention.
# wfixture: x64
# expect_fail
# expect_stderr: 'helper' is not a kernel
import lib.cuda

int helper(int x):
	return x + 1

int main():
	launch helper[1, 1](5)
	return 0
