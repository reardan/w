# lib.tensor end-to-end test (docs/projects/torch.md, Stages 1-3):
# construction, ndf round-trips, elementwise ops, relu, the atomic
# tensor_sum reduction and the naive tensor_matmul2, each cross-checked
# against the lib/ndarray.w CPU implementations. On a machine with a
# usable GPU every op runs the 'gpu for' path; without one (but with
# libcuda.so.1 installed) the same binary exercises the CPU fallbacks.
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
	i = 0
	while (i < 1000):
		if (feq(r.data[i], ha.data[i] + hb.data[i], 0.0001) == 0):
			return 0
		i = i + 1

	tensor_mul_into(&r, &a, &b)
	i = 0
	while (i < 1000):
		if (feq(r.data[i], ha.data[i] * hb.data[i], 0.01) == 0):
			return 0
		i = i + 1

	tensor_mul_scalar_into(&r, &a, 3.0)
	tensor_add_scalar_into(&r, &r, 7.0)
	i = 0
	while (i < 1000):
		if (feq(r.data[i], ha.data[i] * 3.0 + 7.0, 0.01) == 0):
			return 0
		i = i + 1

	# relu: negatives clamp to zero, positives pass through
	tensor_relu_into(&r, &a)
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

	i = 0
	while (i < m * n):
		if (feq(r.data[i], want.data[i], 0.001) == 0):
			return 0
		i = i + 1
	tensor_free(&a)
	tensor_free(&b)
	tensor_free(&r)
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
	println(c"tensor gpu OK")
	return 0
