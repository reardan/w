# expect_fail
# expect_stderr: only functions can be exported
export int x = 3
int main():
	return 0
# wbuild: fixture_group=diagnostic_sites_test
