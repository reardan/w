# 'gpu for' emits calls into the lib.cuda host runtime; without the
# import there is nothing to call. Compiled with the x64 selector by
# the cuda_diagnostics_test target.
int main(int argc, int argv):
	int n = 8
	gpu for int i in range(n):
		pass
	return 0
