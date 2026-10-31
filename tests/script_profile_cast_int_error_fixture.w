# A cast from an integer to a pointer forges an address.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: cast to a pointer type is not allowed
int main():
	int address = 4096
	int* p = cast(int*, address)
	return p[0]
# wbuild: fixture_group=script_profile_error_test
