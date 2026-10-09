# wfixture: --streaming
# expect_fail
# expect_stderr: initializer for global 'A': division by zero in constant expression
const int A = 4 / 0
int main():
	return A
# wbuild: fixture_group=diagnostic_sites_test
