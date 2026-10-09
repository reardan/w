# expect_fail
# expect_stderr: truncated UTF-8 string literal
int main():
	string s = s"Ã"
	return 0
# wbuild: fixture_group=diagnostic_sites_test
