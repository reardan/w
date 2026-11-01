# c_lib links a native shared library.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: c_lib is not allowed
c_lib "libc.so.6"


int main():
	return 0
# wbuild: fixture_group=script_profile_error_test
