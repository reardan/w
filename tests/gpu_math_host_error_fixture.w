# gpu_exp/gpu_log are device-only: same rationale as the atomic
# intrinsics (grammar/atomic_builtin.w) — no host lowering is provided.
# Compiled with the x64 selector by the cuda_diagnostics_test target.
int main(int argc, int argv):
	float32 x = 1.0
	gpu_exp(x)
	return 0
