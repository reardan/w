# gpu_shared_f32/gpu_barrier are device-only: same rationale as the
# atomic intrinsics (grammar/atomic_builtin.w) — no host lowering is
# provided. Asserted by bin/wfixture in the cuda_diagnostics_test
# target.
# wfixture: x64
# expect_fail
# expect_stderr: gpu_shared_f32/gpu_barrier are only available in gpu code
int main(int argc, int argv):
	gpu_barrier()
	return 0
