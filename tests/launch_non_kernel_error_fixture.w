# 'launch' only accepts kernel symbols: an ordinary function's body is
# host code with a host calling convention. Compiled with the x64
# selector by the cuda_diagnostics_test target.
import lib.cuda

int helper(int x):
	return x + 1

int main():
	launch helper[1, 1](5)
	return 0
