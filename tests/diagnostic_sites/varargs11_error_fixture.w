# expect_fail
# expect_stderr: variadic functions support at most 10 parameters
int f(int a, int b, int c, int d, int e, int f1, int g, int h, int i, int j, int k, int... rest):
	return 0
int main():
	return 0
# wbuild: fixture_group=diagnostic_sites_test
