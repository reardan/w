# wfixture: arm64
# expect_fail
# expect_stderr: thread_local is only supported on the x86 and x64 Linux targets
thread_local int counter

int main():
	return 0
