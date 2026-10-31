# A cast between pointer types reinterprets memory: rejected like an
# integer-to-pointer cast.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: cast to a pointer type is not allowed
int main():
	char* text = c"abcd"
	int* words = cast(int*, text)
	return words[0]
# wbuild: fixture_group=script_profile_error_test
