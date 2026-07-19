# 'gpu for' emits calls into the lib.cuda host runtime; without the
# import there is nothing to call.
# wfixture: x64
# expect_fail
# expect_stderr: gpu code requires 'import lib.cuda'
int main(int argc, int argv):
	int n = 8
	gpu for int i in range(n):
		pass
	return 0
