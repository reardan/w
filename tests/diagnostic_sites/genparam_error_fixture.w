# expect_fail
# expect_stderr: variadic generator parameters are not supported
import lib.generator
generator int g(int... xs):
	yield 1
int main():
	return 0
# wbuild: fixture_group=diagnostic_sites_test
