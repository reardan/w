# thread_create starts native threads outside the host's control.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: built-in 'thread_create' is not allowed
int worker(int arg):
	return arg


int main():
	return thread_create(worker, 0)
# wbuild: fixture_group=script_profile_error_test
