# A system call built-in reaches the kernel past every host API.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: built-in 'syscall' is not allowed
int main():
	return syscall(20, 0, 0, 0)
# wbuild: fixture_group=script_profile_error_test
