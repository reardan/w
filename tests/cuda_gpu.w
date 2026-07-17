# GPU end-to-end test for W-authored kernels (docs/projects/cuda.md
# Stage 2/3): a 'gpu for' vector add and a saxpy through the raw
# kernel/launch surface, both verified against CPU results. Needs a
# real NVIDIA GPU and driver, so the cuda_test target stays out of the
# default './wbuild tests' umbrella, next to cuda_smoke (x64 only:
# libcuda.so is 64-bit). The gpu_ptx_emit_test target also compiles
# this file with --ptx to assert the outlined kernel's PTX GPU-less.
import lib.lib
import lib.cuda

kernel saxpy(float32* y, float32* x, float32 a, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		y[i] = a * x[i] + y[i]


int gpu_for_vector_add(int n):
	int* a = cast(int*, gpu_alloc(n * 8))
	int* b = cast(int*, gpu_alloc(n * 8))
	int* c = cast(int*, gpu_alloc(n * 8))
	int i = 0
	while (i < n):
		a[i] = i
		b[i] = 2 * i + 7
		c[i] = 0
		i = i + 1

	gpu for int j in range(n):
		c[j] = a[j] + b[j]
	gpu_sync()

	int ok = 1
	i = 0
	while (i < n):
		if (c[i] != 3 * i + 7):
			ok = 0
		i = i + 1
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, b))
	gpu_free(cast(char*, c))
	return ok


int saxpy_launch(int n):
	float32* x = cast(float32*, gpu_alloc(n * 4))
	float32* y = cast(float32*, gpu_alloc(n * 4))
	int i = 0
	while (i < n):
		x[i] = i
		y[i] = 2.0
		i = i + 1

	int threads = 256
	int blocks = (n + threads - 1) / threads
	launch saxpy[blocks, threads](y, x, 3.0, n)
	gpu_sync()

	int ok = 1
	i = 0
	while (i < n):
		float32 want = cast(float32, 3 * i + 2)
		if (y[i] != want):
			ok = 0
		i = i + 1
	gpu_free(cast(char*, x))
	gpu_free(cast(char*, y))
	return ok


int main(int argc, int argv):
	if (gpu_for_vector_add(1000) == 0):
		println(c"cuda gpu: FAILED (gpu for wrong results)")
		return 1
	if (saxpy_launch(1024) == 0):
		println(c"cuda gpu: FAILED (saxpy wrong results)")
		return 1
	println(c"cuda gpu OK")
	return 0
