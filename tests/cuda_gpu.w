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


# Sum/min/max of data[0..n-1] via gpu atomics, CPU-verified: data[i] =
# i+1, so sum = n(n+1)/2, min = 1, max = n. cells[0..2] hold the
# accumulators (captured as one pointer; the kernel indexes it).
int atomic_reduce(int n):
	int* cells = cast(int*, gpu_alloc(3 * 8))
	int* data = cast(int*, gpu_alloc(n * 8))
	int i = 0
	while (i < n):
		data[i] = i + 1
		i = i + 1
	cells[0] = 0
	cells[1] = 1 << 30
	cells[2] = 0 - (1 << 30)
	# The atomic target must be a pointer-TYPED expression (W's '&' and
	# pointer arithmetic yield untyped constants), so each accumulator
	# cell gets its own typed pointer local.
	int* sum_cell = cells
	int* min_cell = &cells[1]
	int* max_cell = &cells[2]

	gpu for int j in range(n):
		atomic_add(sum_cell, data[j])
		atomic_min(min_cell, data[j])
		atomic_max(max_cell, data[j])
	gpu_sync()

	int ok = 1
	if (cells[0] != n * (n + 1) / 2):
		ok = 0
	if (cells[1] != 1):
		ok = 0
	if (cells[2] != n):
		ok = 0
	gpu_free(cast(char*, cells))
	gpu_free(cast(char*, data))
	return ok


# The nine 32-bit limb/bit intrinsics, combined into one value. Runs
# natively on the host and inside the outlined kernel below — the same
# source on both targets is a free cross-target oracle.
int bits_mix(int x):
	int hi = 0
	int carry = 0
	int acc = mul_hi(x, 0x10001)
	acc = acc + mul_wide(x, 3, &hi) + hi
	acc = acc + add_carry(x, x, &carry) + carry
	acc = acc + shr(x, 3) + rotl(x, 5) + rotr(x, 7)
	acc = acc + popcount(x) + clz(x) + ctz(x)
	return acc


int device_bits_check(int n):
	int* v = cast(int*, gpu_alloc(n * 8))
	int i = 0
	while (i < n):
		v[i] = i * 40503 + 12345
		i = i + 1

	gpu for int j in range(n):
		int x = v[j]
		int hi = 0
		int carry = 0
		int acc = mul_hi(x, 0x10001)
		acc = acc + mul_wide(x, 3, &hi) + hi
		acc = acc + add_carry(x, x, &carry) + carry
		acc = acc + shr(x, 3) + rotl(x, 5) + rotr(x, 7)
		acc = acc + popcount(x) + clz(x) + ctz(x)
		v[j] = acc
	gpu_sync()

	int ok = 1
	i = 0
	while (i < n):
		if (v[i] != bits_mix(i * 40503 + 12345)):
			ok = 0
		i = i + 1
	gpu_free(cast(char*, v))
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
	if (atomic_reduce(500) == 0):
		println(c"cuda gpu: FAILED (atomic reduction wrong results)")
		return 1
	if (device_bits_check(64) == 0):
		println(c"cuda gpu: FAILED (device intrinsics disagree with host)")
		return 1
	if (saxpy_launch(1024) == 0):
		println(c"cuda gpu: FAILED (saxpy wrong results)")
		return 1
	println(c"cuda gpu OK")
	return 0
