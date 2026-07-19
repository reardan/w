# gpu_shared_f32/gpu_barrier are device-only: same rationale as the
# atomic intrinsics (grammar/atomic_builtin.w) — no host lowering is
# provided. Compiled with the x64 selector by the cuda_diagnostics_test
# target.
int main(int argc, int argv):
	gpu_barrier()
	return 0
