# expect_fail
# expect_stderr: parameter without a default follows a parameter with a default
import lib.generator
generator int g(int a = 1, int b):
	yield 1
int main():
	return 0
# wbuild: fixture_group=diagnostic_sites_test
