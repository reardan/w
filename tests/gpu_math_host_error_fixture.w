# gpu_exp/gpu_log are device-only: same rationale as the atomic
# intrinsics (grammar/atomic_builtin.w) — no host lowering is provided.
# wfixture: x64
# expect_fail
# expect_stderr: gpu_exp/gpu_log are only available in gpu code
int main(int argc, int argv):
	float32 x = 1.0
	gpu_exp(x)
	return 0
