# expect_fail
# expect_stderr: generator functions require 'import lib.generator'
generator int g():
	yield 1
int main():
	return 0
# wbuild: fixture_group=diagnostic_sites_test
