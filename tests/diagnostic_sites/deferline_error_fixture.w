# expect_fail
# expect_stderr: a statement must follow 'defer' on the same line
int main():
	defer
	return 0
# wbuild: fixture_group=diagnostic_sites_test
