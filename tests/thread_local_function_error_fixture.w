# expect_fail
# expect_stderr: thread_local applies to variables, not functions
thread_local int helper():
	return 1

int main():
	return 0
# wbuild: fixture_group=thread_local_error_test
