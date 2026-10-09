# expect_fail
# expect_stderr: invalid unicode surrogate
int main():
	string s = s"\uD800"
	return 0
# wbuild: fixture_group=diagnostic_sites_test
