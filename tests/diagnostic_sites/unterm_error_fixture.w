# expect_fail
# expect_stderr: unterminated string literal
int main():
	char* s = "abc
# wbuild: fixture_group=diagnostic_sites_test
