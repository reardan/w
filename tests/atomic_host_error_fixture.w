# The atomic intrinsics are device-only: on the host they would need a
# different lowering (lock-prefixed instructions) that Stage 4 does not
# provide. Compiled with the x64 selector by the cuda_diagnostics_test
# target.
int main(int argc, int argv):
	int x = 0
	atomic_add(&x, 1)
	return 0
