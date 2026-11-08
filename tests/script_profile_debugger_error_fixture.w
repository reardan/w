# The debugger statement traps (int3), which the engine's fault window
# does not recover.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: debugger statements are not allowed
int main():
	debugger
	return 0
# wbuild: fixture_group=script_profile_error_test
