# expect_fail
# expect_stderr: deferred statement must be a simple expression statement
int main():
	defer if (1): print(1)
	return 0
# wbuild: fixture_group=diagnostic_sites_test
