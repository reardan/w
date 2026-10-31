# extern declarations bind native library symbols.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: extern declarations are not allowed
extern int puts(char* text)


int main():
	return 0
# wbuild: fixture_group=script_profile_error_test
