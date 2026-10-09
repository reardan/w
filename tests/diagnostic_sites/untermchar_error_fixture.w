# expect_fail
# expect_stderr: unterminated char literal
int main():
	int c = 'a
# wbuild: fixture_group=diagnostic_sites_test
