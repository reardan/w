# wfixture: --streaming
# expect_fail
# expect_stderr: declarations must come before the first top-level statement
defer print(1)
int main():
	return 0
# wbuild: fixture_group=diagnostic_sites_test
