# GPU-less PTX emitter smoke (docs/projects/cuda.md Stage 2): define
# kernels in W, then print the embedded PTX module so the build target
# can grep it for the load-bearing instructions. Runs on any x64 Linux
# machine — no GPU, no libcuda: defining kernels only adds PTX text and
# the synthesized __w_ptx_module accessor to the binary.
#
# x64-only (gpu kernels require the x64 target), so this file is not
# *_test.w-suffixed: the build target is hand-declared in build.base.json
# (the cuda_smoke precedent) instead of wbuildgen's default-target twin.
import lib.lib

char* __w_ptx_module();


# Float vector add: the cuda.md reference kernel.
kernel add(float32* a, float32* b, float32* c, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		c[i] = a[i] + b[i]


# Integer kernel: while-loop (grid-stride), multiplication, comparisons.
kernel scale(int* v, int n, int k):
	int i = block_idx() * block_dim() + thread_idx()
	int stride = grid_dim() * block_dim()
	while (i < n):
		v[i] = v[i] * k
		i = i + stride


# float64 arithmetic and an int -> float conversion.
kernel axpb64(float64* y, float64 aa, float64 b, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		y[i] = aa * y[i] + b + i


# Atomic reductions (docs/projects/torch.md Stage 1): every thread
# red.add's into single accumulator cells.
kernel accumulate(float32* facc, int* iacc, float32* v, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		gpu_atomic_add(facc, v[i])
		gpu_atomic_add_int(iacc, 1)


int main(int argc, int argv):
	print(__w_ptx_module())
	return 0
