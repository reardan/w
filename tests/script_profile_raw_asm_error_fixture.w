# raw_asm emits arbitrary machine code bytes.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: raw_asm is not allowed
int main():
	raw_asm("\x90")
	return 0
# wbuild: fixture_group=script_profile_error_test
