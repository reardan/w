# lib.tensor end-to-end test (docs/projects/torch.md, Stages 1-3 plus the
# Workstream A op-surface widening for autograd/MLP): construction, ndf
# round-trips, elementwise ops (add/sub/mul/scalar/relu/axpy/relu_grad),
# the bias-add broadcast, the atomic tensor_sum reduction plus the
# per-row/per-column reductions (row_sum/col_sum/row_max), the naive
# tensor_matmul2 and its transposed-operand siblings (matmul2_tn,
# matmul2_nt), and the host-side tensor_randn fill -- each cross-checked
# against a straightforward host reference computation (lib/ndarray.w
# where an ndf op exists, a hand-rolled loop otherwise). On a machine
# with a usable GPU every op runs the 'gpu for' path; without one (but
# with libcuda.so.1 installed) the same binary exercises the CPU
# fallbacks.
#
# The tensor_gpu_test target is opt-in next to cuda_test (running needs
# libcuda at load time); tensor_compile_test compiles this file in the
# default umbrella so device-subset regressions are caught GPU-less.
# x64-only (gpu constructs require the x64 target), so no *_test.w
# autotwin: both targets are hand-declared in build.base.json.
import lib.lib
import lib.tensor


# |a - b| <= eps, without pulling in fmath.
int feq(float a, float b, float eps):
	float d = a - b
	if (d < 0.0):
		d = 0.0 - d
	return d <= eps


int check_elementwise():
	# Distinct per-element values so wrong indexing shows up.
	ndf ha = ndf_new1(1000)
	ndf hb = ndf_new1(1000)
	int i = 0
	while (i < 1000):
		ha.data[i] = cast(float, i - 500)
		hb.data[i] = cast(float, 2 * i + 1)
		i = i + 1

	tensor a = tensor_from_ndf(&ha)
	tensor b = tensor_from_ndf(&hb)
	tensor r = tensor_new1(1000)

	# add / mul / scalar ops vs the ndf CPU reference
	tensor_add_into(&r, &a, &b)
	tensor_sync()
	i = 0
	while (i < 1000):
		if (feq(r.data[i], ha.data[i] + hb.data[i], 0.0001) == 0):
			return 0
		i = i + 1

	tensor_mul_into(&r, &a, &b)
	tensor_sync()
	i = 0
	while (i < 1000):
		if (feq(r.data[i], ha.data[i] * hb.data[i], 0.01) == 0):
			return 0
		i = i + 1

	tensor_mul_scalar_into(&r, &a, 3.0)
	tensor_add_scalar_into(&r, &r, 7.0)
	tensor_sync()
	i = 0
	while (i < 1000):
		if (feq(r.data[i], ha.data[i] * 3.0 + 7.0, 0.01) == 0):
			return 0
		i = i + 1

	# relu: negatives clamp to zero, positives pass through
	tensor_relu_into(&r, &a)
	tensor_sync()
	i = 0
	while (i < 1000):
		float want = ha.data[i]
		if (want < 0.0):
			want = 0.0
		if (feq(r.data[i], want, 0.0001) == 0):
			return 0
		i = i + 1

	# round-trip back to an ndf
	ndf back = tensor_to_ndf(&r)
	if (feq(ndf_at1(&back, 0), 0.0, 0.0001) == 0):
		return 0
	if (feq(ndf_at1(&back, 999), 499.0, 0.0001) == 0):
		return 0

	tensor_free(&a)
	tensor_free(&b)
	tensor_free(&r)
	return 1


int check_sum():
	# 1 + 2 + ... + n has an exact closed form; n = 3000 keeps every
	# partial sum inside float32's exact-integer range, so only the
	# accumulation order varies — a tight tolerance still holds.
	int n = 3000
	tensor t = tensor_new1(n)
	int i = 0
	while (i < n):
		t.data[i] = cast(float, i + 1)
		i = i + 1
	float got = tensor_sum(&t)
	float want = cast(float, n * (n + 1) / 2)
	tensor_free(&t)
	return feq(got, want, 0.5)


int check_matmul():
	# 13x7 @ 7x11: odd shapes exercise the i < total guard and the
	# row/col decomposition. Values small enough that float32 keeps the
	# products exact; compare against ndf_matmul2.
	int m = 13
	int kd = 7
	int n = 11
	ndf ha = ndf_new2(m, kd)
	ndf hb = ndf_new2(kd, n)
	int i = 0
	while (i < m * kd):
		ha.data[i] = cast(float, i % 9 - 4)
		i = i + 1
	i = 0
	while (i < kd * n):
		hb.data[i] = cast(float, i % 7 - 3)
		i = i + 1
	ndf want = ndf_new2(m, n)
	ndf_matmul2(&want, &ha, &hb)

	tensor a = tensor_from_ndf(&ha)
	tensor b = tensor_from_ndf(&hb)
	tensor r = tensor_new2(m, n)
	tensor_matmul2(&r, &a, &b)
	tensor_sync()

	i = 0
	while (i < m * n):
		if (feq(r.data[i], want.data[i], 0.001) == 0):
			return 0
		i = i + 1
	tensor_free(&a)
	tensor_free(&b)
	tensor_free(&r)
	return 1


int check_sub_axpy():
	int n = 500
	ndf ha = ndf_new1(n)
	ndf hb = ndf_new1(n)
	int i = 0
	while (i < n):
		ha.data[i] = cast(float, i - 200)
		hb.data[i] = cast(float, 3 * i - 50)
		i = i + 1

	tensor a = tensor_from_ndf(&ha)
	tensor b = tensor_from_ndf(&hb)
	tensor r = tensor_new1(n)

	tensor_sub_into(&r, &a, &b)
	tensor_sync()
	i = 0
	while (i < n):
		if (feq(r.data[i], ha.data[i] - hb.data[i], 0.0001) == 0):
			return 0
		i = i + 1

	# axpy: y += s*x, in place. Start y as a copy of a.
	tensor y = tensor_from_ndf(&ha)
	float s = 2.5
	tensor_axpy_into(&y, s, &b)
	tensor_sync()
	i = 0
	while (i < n):
		if (feq(y.data[i], ha.data[i] + s * hb.data[i], 0.001) == 0):
			return 0
		i = i + 1

	tensor_free(&a)
	tensor_free(&b)
	tensor_free(&r)
	tensor_free(&y)
	return 1


int check_relu_grad():
	int n = 800
	ndf ha = ndf_new1(n)   # forward input
	ndf hd = ndf_new1(n)   # upstream grad
	int i = 0
	while (i < n):
		ha.data[i] = cast(float, i - 400)
		hd.data[i] = cast(float, i % 13 - 6)
		i = i + 1

	tensor a = tensor_from_ndf(&ha)
	tensor dout = tensor_from_ndf(&hd)
	tensor r = tensor_new1(n)
	tensor_relu_grad_into(&r, &a, &dout)
	tensor_sync()

	i = 0
	while (i < n):
		float want = 0.0
		if (ha.data[i] > 0.0):
			want = hd.data[i]
		if (feq(r.data[i], want, 0.0001) == 0):
			return 0
		i = i + 1

	tensor_free(&a)
	tensor_free(&dout)
	tensor_free(&r)
	return 1


int check_add_row():
	int m = 9
	int n = 5
	ndf ha = ndf_new2(m, n)
	ndf hr = ndf_new1(n)
	int i = 0
	while (i < m * n):
		ha.data[i] = cast(float, i % 7 - 3)
		i = i + 1
	i = 0
	while (i < n):
		hr.data[i] = cast(float, i * 2 + 1)
		i = i + 1

	tensor a = tensor_from_ndf(&ha)
	tensor r = tensor_from_ndf(&hr)
	tensor out = tensor_new2(m, n)
	tensor_add_row_into(&out, &a, &r)
	tensor_sync()

	i = 0
	while (i < m):
		int j = 0
		while (j < n):
			float want = ha.data[i * n + j] + hr.data[j]
			if (feq(out.data[i * n + j], want, 0.0001) == 0):
				return 0
			j = j + 1
		i = i + 1

	tensor_free(&a)
	tensor_free(&r)
	tensor_free(&out)
	return 1


int check_row_col_reductions():
	int m = 6
	int n = 8
	ndf ha = ndf_new2(m, n)
	int i = 0
	while (i < m * n):
		ha.data[i] = cast(float, i % 11 - 5)
		i = i + 1

	tensor a = tensor_from_ndf(&ha)
	tensor rsum = tensor_new1(m)
	tensor csum = tensor_new1(n)
	tensor rmax = tensor_new1(m)
	tensor_row_sum_into(&rsum, &a)
	tensor_col_sum_into(&csum, &a)
	tensor_row_max_into(&rmax, &a)
	tensor_sync()

	i = 0
	while (i < m):
		float want = 0.0
		float best = ha.data[i * n]
		int j = 0
		while (j < n):
			float v = ha.data[i * n + j]
			want = want + v
			if (v > best):
				best = v
			j = j + 1
		if (feq(rsum.data[i], want, 0.001) == 0):
			return 0
		if (feq(rmax.data[i], best, 0.0001) == 0):
			return 0
		i = i + 1

	int j2 = 0
	while (j2 < n):
		float want2 = 0.0
		int i2 = 0
		while (i2 < m):
			want2 = want2 + ha.data[i2 * n + j2]
			i2 = i2 + 1
		if (feq(csum.data[j2], want2, 0.001) == 0):
			return 0
		j2 = j2 + 1

	tensor_free(&a)
	tensor_free(&rsum)
	tensor_free(&csum)
	tensor_free(&rmax)
	return 1


# Multi-tile shapes for the Stage 4 tiled GPU kernels: 37x50 @ 50x29
# spans several 16x16 output tiles in both grid dimensions AND several
# k-steps (50 > 3*16), with ragged edges everywhere, so the tile loop,
# the bx/by block decomposition and the zero-padded edge loads are all
# exercised -- check_matmul's 13x7 @ 7x11 fits in a single partial
# tile. Same exact-in-f32 small-integer values, all three variants
# cross-checked against the CPU fallback run on the same tensors'
# host-visible buffers via ndf.
int check_matmul_multitile():
	int m = 37
	int kd = 50
	int n = 29
	ndf ha = ndf_new2(m, kd)
	ndf hat = ndf_new2(kd, m)
	ndf hb = ndf_new2(kd, n)
	ndf hbt = ndf_new2(n, kd)
	int i = 0
	while (i < m * kd):
		ha.data[i] = cast(float, i % 9 - 4)
		i = i + 1
	i = 0
	while (i < kd * n):
		hb.data[i] = cast(float, i % 7 - 3)
		i = i + 1
	# hat = haT, hbt = hbT, so the tn/nt variants must reproduce the
	# same product.
	i = 0
	while (i < m):
		int j = 0
		while (j < kd):
			ndf_set2(&hat, j, i, ndf_at2(&ha, i, j))
			j = j + 1
		i = i + 1
	i = 0
	while (i < kd):
		int j2 = 0
		while (j2 < n):
			ndf_set2(&hbt, j2, i, ndf_at2(&hb, i, j2))
			j2 = j2 + 1
		i = i + 1
	ndf want = ndf_new2(m, n)
	ndf_matmul2(&want, &ha, &hb)

	tensor a = tensor_from_ndf(&ha)
	tensor at = tensor_from_ndf(&hat)
	tensor b = tensor_from_ndf(&hb)
	tensor bt = tensor_from_ndf(&hbt)
	tensor r = tensor_new2(m, n)

	int ok = 1
	tensor_matmul2(&r, &a, &b)
	tensor_sync()
	i = 0
	while (i < m * n):
		if (feq(r.data[i], want.data[i], 0.001) == 0):
			ok = 0
		i = i + 1
	tensor_matmul2_tn(&r, &at, &b)
	tensor_sync()
	i = 0
	while (i < m * n):
		if (feq(r.data[i], want.data[i], 0.001) == 0):
			ok = 0
		i = i + 1
	tensor_matmul2_nt(&r, &a, &bt)
	tensor_sync()
	i = 0
	while (i < m * n):
		if (feq(r.data[i], want.data[i], 0.001) == 0):
			ok = 0
		i = i + 1

	tensor_free(&a)
	tensor_free(&at)
	tensor_free(&b)
	tensor_free(&bt)
	tensor_free(&r)
	return ok


int check_matmul_variants():
	# tn: a is (k, m), b is (k, n), out is (m, n) = aT @ b
	int k = 6
	int m = 4
	int n = 5
	ndf ha = ndf_new2(k, m)
	ndf hb = ndf_new2(k, n)
	int i = 0
	while (i < k * m):
		ha.data[i] = cast(float, i % 5 - 2)
		i = i + 1
	i = 0
	while (i < k * n):
		hb.data[i] = cast(float, i % 4 - 1)
		i = i + 1

	tensor a = tensor_from_ndf(&ha)
	tensor b = tensor_from_ndf(&hb)
	tensor r = tensor_new2(m, n)
	tensor_matmul2_tn(&r, &a, &b)
	tensor_sync()

	int row = 0
	while (row < m):
		int col = 0
		while (col < n):
			float want = 0.0
			int p = 0
			while (p < k):
				want = want + ha.data[p * m + row] * hb.data[p * n + col]
				p = p + 1
			if (feq(r.data[row * n + col], want, 0.001) == 0):
				return 0
			col = col + 1
		row = row + 1

	tensor_free(&a)
	tensor_free(&b)
	tensor_free(&r)

	# nt: a is (m, k), b is (n, k), out is (m, n) = a @ bT
	ndf hc = ndf_new2(m, k)
	ndf hd = ndf_new2(n, k)
	i = 0
	while (i < m * k):
		hc.data[i] = cast(float, i % 6 - 2)
		i = i + 1
	i = 0
	while (i < n * k):
		hd.data[i] = cast(float, i % 3 - 1)
		i = i + 1

	tensor c = tensor_from_ndf(&hc)
	tensor d = tensor_from_ndf(&hd)
	tensor r2 = tensor_new2(m, n)
	tensor_matmul2_nt(&r2, &c, &d)
	tensor_sync()

	row = 0
	while (row < m):
		int col2 = 0
		while (col2 < n):
			float want2 = 0.0
			int p2 = 0
			while (p2 < k):
				want2 = want2 + hc.data[row * k + p2] * hd.data[col2 * k + p2]
				p2 = p2 + 1
			if (feq(r2.data[row * n + col2], want2, 0.001) == 0):
				return 0
			col2 = col2 + 1
		row = row + 1

	tensor_free(&c)
	tensor_free(&d)
	tensor_free(&r2)
	return 1


int check_randn():
	int n = 20000

	tensor t = tensor_new1(n)
	tensor_randn(&t, 42, 0.0, 1.0)
	float sum = 0.0
	int i = 0
	while (i < n):
		sum = sum + t.data[i]
		i = i + 1
	float mean = sum / cast(float, n)
	float varsum = 0.0
	i = 0
	while (i < n):
		float d = t.data[i] - mean
		varsum = varsum + d * d
		i = i + 1
	float variance = varsum / cast(float, n)
	if (feq(mean, 0.0, 0.05) == 0):
		return 0
	if (feq(variance, 1.0, 0.15) == 0):
		return 0

	# determinism: identical seed reproduces the exact same sequence
	tensor t2 = tensor_new1(n)
	tensor_randn(&t2, 42, 0.0, 1.0)
	i = 0
	while (i < n):
		if (feq(t.data[i], t2.data[i], 0.0000001) == 0):
			return 0
		i = i + 1

	# a different seed must not reproduce the same sequence
	tensor t3 = tensor_new1(n)
	tensor_randn(&t3, 43, 0.0, 1.0)
	int differs = 0
	i = 0
	while (i < n):
		if (feq(t.data[i], t3.data[i], 0.0000001) == 0):
			differs = 1
		i = i + 1
	if (differs == 0):
		return 0

	# non-trivial mean/stddev arguments scale and shift correctly
	tensor t4 = tensor_new1(n)
	tensor_randn(&t4, 7, 5.0, 2.0)
	float sum4 = 0.0
	i = 0
	while (i < n):
		sum4 = sum4 + t4.data[i]
		i = i + 1
	float mean4 = sum4 / cast(float, n)
	float varsum4 = 0.0
	i = 0
	while (i < n):
		float d4 = t4.data[i] - mean4
		varsum4 = varsum4 + d4 * d4
		i = i + 1
	float variance4 = varsum4 / cast(float, n)
	if (feq(mean4, 5.0, 0.1) == 0):
		return 0
	if (feq(variance4, 4.0, 0.6) == 0):
		return 0

	tensor_free(&t)
	tensor_free(&t2)
	tensor_free(&t3)
	tensor_free(&t4)
	return 1


int main(int argc, int argv):
	if (gpu_available()):
		println(c"tensor: gpu path")
	else:
		println(c"tensor: cpu fallback")
	if (check_elementwise() == 0):
		println(c"tensor gpu: FAILED (elementwise)")
		return 1
	if (check_sum() == 0):
		println(c"tensor gpu: FAILED (sum)")
		return 1
	if (check_matmul() == 0):
		println(c"tensor gpu: FAILED (matmul)")
		return 1
	if (check_sub_axpy() == 0):
		println(c"tensor gpu: FAILED (sub/axpy)")
		return 1
	if (check_relu_grad() == 0):
		println(c"tensor gpu: FAILED (relu_grad)")
		return 1
	if (check_add_row() == 0):
		println(c"tensor gpu: FAILED (add_row)")
		return 1
	if (check_row_col_reductions() == 0):
		println(c"tensor gpu: FAILED (row/col reductions)")
		return 1
	if (check_matmul_variants() == 0):
		println(c"tensor gpu: FAILED (matmul_tn/nt)")
		return 1
	if (check_matmul_multitile() == 0):
		println(c"tensor gpu: FAILED (multi-tile matmul)")
		return 1
	if (check_randn() == 0):
		println(c"tensor gpu: FAILED (randn)")
		return 1
	println(c"tensor gpu OK")
	return 0
