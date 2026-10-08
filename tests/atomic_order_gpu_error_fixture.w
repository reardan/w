# wfixture: x64
# expect_fail
# expect_stderr: host atomics are not available on this target yet
kernel ordering(int* value):
	atomic_store(value, 1)

int main(): return 0
