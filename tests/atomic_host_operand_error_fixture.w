# Host atomics are word-sized int read-modify-writes: the float32*
# atomic_add form exists only on the GPU (lock-prefixed x86 has no
# float add), so host operands must be int*.
# wfixture: x64
# expect_fail
# expect_stderr: host atomics require an int* first argument
int main(int argc, int argv):
	float32 f = 0.0
	atomic_add(&f, 1.0)
	return 0
