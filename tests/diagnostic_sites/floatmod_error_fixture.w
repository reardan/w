# expect_fail
# expect_stderr: float operands do not support %
int main():
	float x = 1.5
	float y = x % 2.0
	return 0
# wbuild: fixture_group=diagnostic_sites_test
