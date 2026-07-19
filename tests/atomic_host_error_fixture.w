# The atomic intrinsics are device-only: on the host they would need a
# different lowering (lock-prefixed instructions) that Stage 4 does not
# provide.
# wfixture: x64
# expect_fail
# expect_stderr: atomic_add/atomic_min/atomic_max are only available in gpu code
int main(int argc, int argv):
	int x = 0
	atomic_add(&x, 1)
	return 0
