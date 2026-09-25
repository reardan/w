# expect_fail
# expect_stderr: thread_local variables cannot have an initializer; they start zeroed
thread_local int counter = 3

int main():
	return 0
# wbuild: fixture_group=thread_local_error_test
