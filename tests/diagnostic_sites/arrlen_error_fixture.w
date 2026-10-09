# expect_fail
# expect_stderr: array length must be positive
int main():
	int[0] a
	return 0
# wbuild: fixture_group=diagnostic_sites_test
