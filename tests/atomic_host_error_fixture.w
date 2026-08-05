# atomic_min/atomic_max are device-only: their host lowering would need
# a cmpxchg loop that the host-atomics stage does not provide — host
# code gets atomic_add/atomic_cas instead (docs/projects/threads.md).
# wfixture: x64
# expect_fail
# expect_stderr: atomic_min/atomic_max are only available in gpu code
int main(int argc, int argv):
	int x = 0
	atomic_min(&x, 1)
	return 0
