# expect_fail
# expect_stderr: declarations must come before the first top-level statement
print(1)
int f():
	return 1
# wbuild: fixture_group=diagnostic_sites_test
