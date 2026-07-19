# GPU end-to-end test for W-authored kernels (docs/projects/cuda.md
# Stage 2/3): a 'gpu for' vector add and a saxpy through the raw
# kernel/launch surface, both verified against CPU results. Needs a
# real NVIDIA GPU and driver, so the cuda_test target stays out of the
# default './wbuild tests' umbrella, next to cuda_smoke (x64 only:
# libcuda.so is 64-bit). The gpu_ptx_emit_test target also compiles
# this file with --ptx to assert the outlined kernel's PTX GPU-less.
import lib.lib
import lib.cuda
import lib.fmath

kernel saxpy(float32* y, float32* x, float32 a, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		y[i] = a * x[i] + y[i]


# gpu_exp/gpu_log (docs/projects/torch.md Workstream E): device
# transcendentals, cross-checked below against the host lib.fmath
# fexp/flog implementations.
kernel transcendental(float32* xe, float32* ye, float32* xl, float32* yl, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		ye[i] = gpu_exp(xe[i])
		yl[i] = gpu_log(xl[i])


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


# range(start, end): threads cover [100, n); cells below 100 must stay
# untouched.
int range_offset_check(int n):
	int* c = cast(int*, gpu_alloc(n * 8))
	int i = 0
	while (i < n):
		c[i] = 0 - 1
		i = i + 1

	gpu for int j in range(100, n):
		c[j] = 2 * j
	gpu_sync()

	int ok = 1
	i = 0
	while (i < 100):
		if (c[i] != 0 - 1):
			ok = 0
		i = i + 1
	while (i < n):
		if (c[i] != 2 * i):
			ok = 0
		i = i + 1
	gpu_free(cast(char*, c))
	return ok


# Explicit memory path: host buffers, gpu_device_alloc +
# gpu_memcpy_to/from around a doubling kernel. No gpu_sync: the
# non-async copy-back is ordered after the launch on the default
# stream and blocks until the kernel finishes.
int explicit_memory_check(int n):
	int bytes = n * 8
	int* host_in = cast(int*, malloc(bytes))
	int* host_out = cast(int*, malloc(bytes))
	int i = 0
	while (i < n):
		host_in[i] = 7 * i + 3
		i = i + 1

	int* dev = cast(int*, gpu_device_alloc(bytes))
	gpu_memcpy_to(cast(char*, dev), cast(char*, host_in), bytes)
	gpu for int j in range(n):
		dev[j] = dev[j] * 2
	gpu_memcpy_from(cast(char*, host_out), cast(char*, dev), bytes)

	int ok = 1
	i = 0
	while (i < n):
		if (host_out[i] != (7 * i + 3) * 2):
			ok = 0
		i = i + 1
	gpu_free(cast(char*, dev))
	free(cast(char*, host_in))
	free(cast(char*, host_out))
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


# gpu_shared_f32 + gpu_barrier (docs/projects/torch.md Stage 4): each
# 256-thread block stages its slice of p in shared memory, tree-halves
# it with barriers, then adds one per-block partial into the global
# accumulator. Data is exact-in-f32 quarters (i % 8 * 0.25), so every
# partial sum is exact and the check needs no tolerance despite the
# nondeterministic block order.
kernel shared_reduce(float* p, float32* out, int n):
	float* buf = gpu_shared_f32(256)
	int tid = thread_idx()
	int gid = block_idx() * block_dim() + tid
	float v = 0.0
	if (gid < n):
		v = p[gid]
	buf[tid] = v
	gpu_barrier()
	int s = 128
	while (s > 0):
		if (tid < s):
			buf[tid] = buf[tid] + buf[tid + s]
		gpu_barrier()
		s = s / 2
	if (tid == 0):
		atomic_add(out, buf[0])


int shared_reduce_check(int n):
	float* p = cast(float*, gpu_alloc(n * 4))
	float32* acc = cast(float32*, gpu_alloc(4))
	float want = 0.0
	int i = 0
	while (i < n):
		float v = cast(float, i % 8) * 0.25
		p[i] = v
		want = want + v
		i = i + 1
	acc[0] = 0.0

	int threads = 256
	int blocks = (n + threads - 1) / threads
	launch shared_reduce[blocks, threads](p, acc, n)
	gpu_sync()

	int ok = 1
	if (acc[0] != want):
		ok = 0
	gpu_free(cast(char*, p))
	gpu_free(cast(char*, acc))
	return ok


# gpu_exp/gpu_log cross-checked against the host lib.fmath fexp/flog.
# The PTX .approx variants (ex2.approx.f32/lg2.approx.f32) are the
# ML-precision tradeoff CUDA's fast-math makes, not IEEE-correctly
# rounded, so the tolerance is relative (falling back to an absolute
# check near zero, where a relative one would be meaningless): 1e-4
# relative over exp inputs in [-8, 8] and log inputs in [1e-3, 1e3].
int transcendental_check(int n):
	float32* xe = cast(float32*, gpu_alloc(n * 4))
	float32* ye = cast(float32*, gpu_alloc(n * 4))
	float32* xl = cast(float32*, gpu_alloc(n * 4))
	float32* yl = cast(float32*, gpu_alloc(n * 4))
	int i = 0
	while (i < n):
		float32 t = i
		t = t / cast(float32, n - 1)
		xe[i] = -8.0 + t * 16.0
		xl[i] = 0.001 + t * 999.999
		i = i + 1

	int threads = 256
	int blocks = (n + threads - 1) / threads
	launch transcendental[blocks, threads](xe, ye, xl, yl, n)
	gpu_sync()

	int ok = 1
	float32 rel_tol = 0.0001
	float32 one = 1.0
	i = 0
	while (i < n):
		float32 want_e = fexp(xe[i])
		float32 err_e = fabs(ye[i] - want_e)
		if (fabs(want_e) > one):
			err_e = err_e / fabs(want_e)
		if (err_e > rel_tol):
			ok = 0
		float32 want_l = flog(xl[i])
		float32 err_l = fabs(yl[i] - want_l)
		if (fabs(want_l) > one):
			err_l = err_l / fabs(want_l)
		if (err_l > rel_tol):
			ok = 0
		i = i + 1
	gpu_free(cast(char*, xe))
	gpu_free(cast(char*, ye))
	gpu_free(cast(char*, xl))
	gpu_free(cast(char*, yl))
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
	if (range_offset_check(400) == 0):
		println(c"cuda gpu: FAILED (range(start, end) wrong results)")
		return 1
	if (explicit_memory_check(256) == 0):
		println(c"cuda gpu: FAILED (explicit memory wrong results)")
		return 1
	if (saxpy_launch(1024) == 0):
		println(c"cuda gpu: FAILED (saxpy wrong results)")
		return 1
	if (transcendental_check(256) == 0):
		println(c"cuda gpu: FAILED (gpu_exp/gpu_log wrong results)")
		return 1
	if (shared_reduce_check(100000) == 0):
		println(c"cuda gpu: FAILED (shared-memory reduction wrong results)")
		return 1
	println(c"cuda gpu OK")
	return 0
