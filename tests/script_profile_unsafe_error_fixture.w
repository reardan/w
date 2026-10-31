# unsafe: blocks mark raw operations.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: unsafe blocks are not allowed
int main():
	int x = 5
	unsafe:
		x = 6
	return x
# wbuild: fixture_group=script_profile_error_test
