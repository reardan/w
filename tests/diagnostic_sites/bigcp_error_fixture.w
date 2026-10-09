# expect_fail
# expect_stderr: unicode codepoint out of range
int main():
	string s = s"\U00110000"
	return 0
# wbuild: fixture_group=diagnostic_sites_test
