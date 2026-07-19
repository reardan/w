# Each 'gpu for' iteration is one GPU thread: there is no host frame
# to return from inside the outlined body.
# wfixture: x64
# expect_fail
# expect_stderr: 'return' is not supported in 'gpu for'
import lib.lib
import lib.cuda

int scan(int* v, int n):
	gpu for int i in range(n):
		if v[i] < 0:
			return 1
	return 0

int main(int argc, int argv):
	return 0
