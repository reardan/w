# expect_fail
# expect_stderr: 'export' must be followed by a function definition
export T id[T](T x):
	return x
int main():
	return 0
# wbuild: fixture_group=diagnostic_sites_test
