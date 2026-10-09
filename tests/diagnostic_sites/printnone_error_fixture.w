# expect_fail
# expect_stderr: print requires an argument
int main():
	print()
	return 0
# wbuild: fixture_group=diagnostic_sites_test
