# lib/cublas.w + lib/tensor_cublas.w end-to-end (docs/projects/cuda.md,
# "Execution notes (cuBLAS interop)"): cublas_sgemm_rm in all three
# operand layouts plus alpha/beta, cublas_dgemm_rm, and the opt-in
# tensor_matmul_hook through tensor_matmul2/_tn/_nt -- every product on
# non-square shapes that are not multiples of any tile size, checked
# against a float64 CPU reference. Then an informational benchmark of
# the cuBLAS path against lib/tensor.w's 16x16 tiled kernel (printed,
# never asserted).
#
# Opt-in like cuda_test (cublas_test needs a GPU, libcuda and the CUDA
# toolkit's libcublas); cublas_compile_test compiles it in the default
# umbrella. Without cuBLAS (or without a usable GPU) the program prints
# "cublas: unavailable" and exits 0 -- the probe is non-fatal -- so the
# main run step's "cublas gpu OK" expectation is what fails on such a
# machine, and a second step checks the probe itself under
# CUDA_VISIBLE_DEVICES=.
import lib.lib
import lib.format
import lib.time
import lib.tensor
import lib.tensor_cublas


int now_us():
	timespec ts
	sys_clock_gettime(clock_monotonic(), cast(int, &ts))
	return ts.seconds * 1000000 + ts.nanoseconds / 1000


float64 fabs64(float64 x):
	if (x < 0.0):
		return 0.0 - x
	return x


# Deterministic small values in [-1, 1) so FP32 sums stay well-conditioned.
void fill_pattern(float* p, int n, int seed):
	for i in range(n):
		int v = (i * 37 + seed * 101) % 211
		p[i] = cast(float, v - 105) / 105.0


# Row-major reference: C = alpha * op(A) op(B) + beta * C0 in float64.
# ta/tb as in cublas_sgemm_rm; lda/ldb are the stored row pitches.
float64 ref_elem(int ta, int tb, int i, int j, int k, float* a, int lda, float* b, int ldb):
	float64 acc = 0.0
	for p in range(k):
		float av = 0.0
		if (ta == 0):
			av = a[i * lda + p]
		else:
			av = a[p * lda + i]
		float bv = 0.0
		if (tb == 0):
			bv = b[p * ldb + j]
		else:
			bv = b[j * ldb + p]
		acc = acc + cast(float64, av) * cast(float64, bv)
	return acc


# Max |got - want| over the m x n output against the reference.
float64 max_err(int ta, int tb, int m, int n, int k, float alpha, float* a, int lda, float* b, int ldb, float beta, float* c0, float* c):
	float64 worst = 0.0
	for i in range(m):
		int j = 0
		while (j < n):
			float64 want = cast(float64, alpha) * ref_elem(ta, tb, i, j, k, a, lda, b, ldb) + cast(float64, beta) * cast(float64, c0[i * n + j])
			float64 d = fabs64(cast(float64, c[i * n + j]) - want)
			if (d > worst):
				worst = d
			j = j + 1
	return worst


int check_sgemm(int ta, int tb, float alpha, float beta):
	int m = 37
	int k = 53
	int n = 29
	float* a = cast(float*, gpu_alloc(m * k * 4))
	float* b = cast(float*, gpu_alloc(k * n * 4))
	float* c = cast(float*, gpu_alloc(m * n * 4))
	float* c0 = cast(float*, malloc(m * n * 4))
	fill_pattern(a, m * k, 1)
	fill_pattern(b, k * n, 2)
	fill_pattern(c, m * n, 3)
	fill_pattern(c0, m * n, 3)
	# Stored shapes: A is m x k (row pitch k) or, transposed, k x m
	# (pitch m); B is k x n (pitch n) or n x k (pitch k).
	int lda = k
	if (ta == 1):
		lda = m
	int ldb = n
	if (tb == 1):
		ldb = k
	int st = cublas_sgemm_rm(ta, tb, m, n, k, alpha, a, lda, b, ldb, beta, c, n)
	gpu_sync()
	float64 e = max_err(ta, tb, m, n, k, alpha, a, lda, b, ldb, beta, c0, c)
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, b))
	gpu_free(cast(char*, c))
	free(cast(char*, c0))
	if (st != 0):
		print(c"sgemm status ")
		println(itoa(st))
		return 0
	if (e > 0.001):
		print(c"sgemm error too large, ta=")
		print(itoa(ta))
		print(c" tb=")
		println(itoa(tb))
		return 0
	return 1


int check_dgemm():
	int m = 19
	int k = 41
	int n = 23
	float64* a = cast(float64*, gpu_alloc(m * k * 8))
	float64* b = cast(float64*, gpu_alloc(k * n * 8))
	float64* c = cast(float64*, gpu_alloc(m * n * 8))
	int i = 0
	while (i < m * k):
		a[i] = cast(float64, (i * 13) % 17 - 8) / 8.0
		i = i + 1
	i = 0
	while (i < k * n):
		b[i] = cast(float64, (i * 7) % 19 - 9) / 9.0
		i = i + 1
	i = 0
	while (i < m * n):
		c[i] = 0.0
		i = i + 1
	int st = cublas_dgemm_rm(CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, 1.0, a, k, b, n, 0.0, c, n)
	gpu_sync()
	float64 worst = 0.0
	i = 0
	while (i < m):
		int j = 0
		while (j < n):
			float64 want = 0.0
			for p in range(k):
				want = want + a[i * k + p] * b[p * n + j]
			float64 d = fabs64(c[i * n + j] - want)
			if (d > worst):
				worst = d
			j = j + 1
		i = i + 1
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, b))
	gpu_free(cast(char*, c))
	return st == 0 && worst < 0.000000001


# tensor_matmul2 / _tn / _nt with the hook installed vs the reference.
int check_tensor_hook():
	int m = 45
	int k = 70
	int n = 33
	tensor a = tensor_new2(m, k)
	tensor at = tensor_new2(k, m)
	tensor b = tensor_new2(k, n)
	tensor bt = tensor_new2(n, k)
	tensor out = tensor_new2(m, n)
	fill_pattern(a.data, m * k, 4)
	fill_pattern(at.data, m * k, 5)
	fill_pattern(b.data, k * n, 6)
	fill_pattern(bt.data, k * n, 7)
	float* zero = cast(float*, malloc(m * n * 4))
	for i in range(m * n):
		zero[i] = 0.0
	int ok = 1
	tensor_matmul2(&out, &a, &b)
	tensor_sync()
	if (max_err(0, 0, m, n, k, 1.0, a.data, k, b.data, n, 0.0, zero, out.data) > 0.001):
		println(c"tensor_matmul2 via cuBLAS mismatch")
		ok = 0
	tensor_matmul2_tn(&out, &at, &b)
	tensor_sync()
	if (max_err(1, 0, m, n, k, 1.0, at.data, m, b.data, n, 0.0, zero, out.data) > 0.001):
		println(c"tensor_matmul2_tn via cuBLAS mismatch")
		ok = 0
	tensor_matmul2_nt(&out, &a, &bt)
	tensor_sync()
	if (max_err(0, 1, m, n, k, 1.0, a.data, k, bt.data, k, 0.0, zero, out.data) > 0.001):
		println(c"tensor_matmul2_nt via cuBLAS mismatch")
		ok = 0
	free(cast(char*, zero))
	tensor_free(&a)
	tensor_free(&at)
	tensor_free(&b)
	tensor_free(&bt)
	tensor_free(&out)
	return ok


# Microseconds per tensor_matmul2 of an s x s x s product, averaged over
# reps after one warm-up (JIT/module load, cuBLAS heuristics).
int bench_us(tensor* out, tensor* a, tensor* b, int reps):
	tensor_matmul2(out, a, b)
	tensor_sync()
	int t0 = now_us()
	for r in range(reps):
		tensor_matmul2(out, a, b)
	tensor_sync()
	return (now_us() - t0) / reps


void bench(int s, int reps):
	tensor a = tensor_new2(s, s)
	tensor b = tensor_new2(s, s)
	tensor out = tensor_new2(s, s)
	fill_pattern(a.data, s * s, 8)
	fill_pattern(b.data, s * s, 9)
	tensor_disable_cublas()
	int tiled = bench_us(&out, &a, &b, reps)
	tensor_use_cublas()
	int fast = bench_us(&out, &a, &b, reps)
	# GFLOP/s = 2*s^3 / (us * 1000)
	int flops = 2 * s * s * s
	print(c"bench ")
	print(itoa(s))
	print(c"^3: tiled ")
	print(itoa(tiled))
	print(c" us (")
	print(itoa(flops / (tiled * 1000 + 1)))
	print(c" GFLOP/s), cublas ")
	print(itoa(fast))
	print(c" us (")
	print(itoa(flops / (fast * 1000 + 1)))
	print(c" GFLOP/s), speedup x")
	println(ftoa(cast(float, tiled) / cast(float, fast + 1)))
	tensor_free(&a)
	tensor_free(&b)
	tensor_free(&out)


int main():
	if (cublas_available() == 0):
		println(c"cublas: unavailable")
		return 0
	print(c"cublas: version ")
	println(itoa(cublas_version()))
	int ok = 1
	ok = ok && check_sgemm(0, 0, 1.0, 0.0)
	ok = ok && check_sgemm(1, 0, 1.0, 0.0)
	ok = ok && check_sgemm(0, 1, 1.0, 0.0)
	ok = ok && check_sgemm(1, 1, 1.0, 0.0)
	ok = ok && check_sgemm(0, 0, 2.0, 0.5)
	if (check_dgemm() == 0):
		println(c"dgemm mismatch")
		ok = 0
	if (tensor_use_cublas() == 0):
		println(c"tensor_use_cublas failed")
		ok = 0
	ok = ok && check_tensor_hook()
	if (ok == 0):
		println(c"cublas gpu FAILED")
		return 1
	bench(256, 50)
	bench(1024, 10)
	bench(2048, 3)
	cublas_shutdown()
	println(c"cublas gpu OK")
	return 0
