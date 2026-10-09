# wfixture: --streaming
# expect_fail
# expect_stderr: initializer for global 'A': shift count must be 0..31 in a constant expression
const int A = 1 << 40
int main():
	return A
# wbuild: fixture_group=diagnostic_sites_test
