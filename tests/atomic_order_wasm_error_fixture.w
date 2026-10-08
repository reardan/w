# wfixture: wasm
# expect_fail
# expect_stderr: host atomics are not available on this target yet
int main():
	int value = 1
	return atomic_load(&value)
