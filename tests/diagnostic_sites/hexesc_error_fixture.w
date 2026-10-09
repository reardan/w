# expect_fail
# expect_stderr: invalid hex digit in string literal
int main():
	char* s = c"\xzz"
	return 0
# wbuild: fixture_group=diagnostic_sites_test
