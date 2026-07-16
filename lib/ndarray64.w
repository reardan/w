/*
lib.ndarray64: float64 port of lib.ndarray's ndf, stage 2 of
docs/projects/ndarray.md ("lib/ndarray64.w -- float64 twin. Mirrors the
module per the lib/fmath64.w conventions.").

float64 is a compile error on the default 32-bit target
(docs/projects/float.md: one-word stack slots cannot hold 8 bytes), so
this module only compiles where float64 does: x64-class targets. Import
it only from code already gated to those targets (as
tests/x64_ndarray64_test.w does), the same way lib/fmath64.w is x64-only
in practice despite carrying no explicit guard of its own.

Every symbol is ndf64_-prefixed (imports merge into one flat global
namespace, and lib.ndarray already owns the ndf_/ndi_/ndarray_ names for
float32/int). There is no int64 twin here: `int` is already word-sized
(8 bytes on x64), so lib.ndarray's `ndi` covers index maps on every
target without a port.

This mirrors lib/ndarray.w's ndf surface function-for-function
(shape/stride math, construction variants, per-rank checked accessors,
contiguous-only views, explicit in-place elementwise ops + map, 2-D
matmul) with float replaced by float64 throughout; see that file's
header for the shared design rationale and docs/projects/ndarray.md for
the full spec. Bounds/shape asserts, aliasing rules and the "no operator
arithmetic" stance are identical to the float32 module.
*/
import lib.lib
import lib.assert


# Row-major strides for extents (n0, n1, n2, n3), the float64-twin copy
# of lib.ndarray's ndarray_shape_init (kept as a separate copy rather
# than a shared import: lib.ndarray must stay importable on every
# target, including the 32-bit default where float64 is a compile
# error, so nothing in this file can be pulled in from there).
int ndarray64_int_max():
	int low = 1
	while (low > 0):
		low = low << 1
	return 0 - (low + 1)


int ndarray64_mul_checked(int a, int b):
	if (a == 0 || b == 0):
		return 0
	asserts(c"ndarray64: extent product overflow", a <= ndarray64_int_max() / b)
	return a * b


int ndarray64_shape_init(int n0, int n1, int n2, int n3, int* s0_out, int* s1_out, int* s2_out, int* s3_out):
	asserts(c"ndarray64: extents must be positive", n0 > 0 && n1 > 0 && n2 > 0 && n3 > 0)
	*s3_out = 1
	*s2_out = n3
	*s1_out = ndarray64_mul_checked(n2, n3)
	*s0_out = ndarray64_mul_checked(n1, *s1_out)
	return ndarray64_mul_checked(n0, *s0_out)


struct ndf64:
	float64[] data   # flat backing buffer; length = n0*n1*n2*n3
	int rank         # 1..4
	int n0           # extents; unused trailing axes hold 1
	int n1
	int n2
	int n3
	int s0           # element strides; row-major at construction
	int s1
	int s2
	int s3


int ndf64_init_shape(ndf64* a, int rank, int n0, int n1, int n2, int n3):
	a.rank = rank
	a.n0 = n0
	a.n1 = n1
	a.n2 = n2
	a.n3 = n3
	return ndarray64_shape_init(n0, n1, n2, n3, &a.s0, &a.s1, &a.s2, &a.s3)


##### construction #####


ndf64 ndf64_new1(int n0):
	ndf64 a
	int n = ndf64_init_shape(&a, 1, n0, 1, 1, 1)
	a.data = new float64[n]
	return a


ndf64 ndf64_new2(int n0, int n1):
	ndf64 a
	int n = ndf64_init_shape(&a, 2, n0, n1, 1, 1)
	a.data = new float64[n]
	return a


ndf64 ndf64_new3(int n0, int n1, int n2):
	ndf64 a
	int n = ndf64_init_shape(&a, 3, n0, n1, n2, 1)
	a.data = new float64[n]
	return a


ndf64 ndf64_new4(int n0, int n1, int n2, int n3):
	ndf64 a
	int n = ndf64_init_shape(&a, 4, n0, n1, n2, n3)
	a.data = new float64[n]
	return a


void ndf64_fill(ndf64* a, float64 v):
	int i = 0
	while (i < a.data.length):
		a.data[i] = v
		i = i + 1


ndf64 ndf64_ones1(int n0):
	ndf64 a = ndf64_new1(n0)
	ndf64_fill(&a, 1.0)
	return a


ndf64 ndf64_ones2(int n0, int n1):
	ndf64 a = ndf64_new2(n0, n1)
	ndf64_fill(&a, 1.0)
	return a


ndf64 ndf64_ones3(int n0, int n1, int n2):
	ndf64 a = ndf64_new3(n0, n1, n2)
	ndf64_fill(&a, 1.0)
	return a


ndf64 ndf64_ones4(int n0, int n1, int n2, int n3):
	ndf64 a = ndf64_new4(n0, n1, n2, n3)
	ndf64_fill(&a, 1.0)
	return a


ndf64 ndf64_full1(int n0, float64 v):
	ndf64 a = ndf64_new1(n0)
	ndf64_fill(&a, v)
	return a


ndf64 ndf64_full2(int n0, int n1, float64 v):
	ndf64 a = ndf64_new2(n0, n1)
	ndf64_fill(&a, v)
	return a


ndf64 ndf64_full3(int n0, int n1, int n2, float64 v):
	ndf64 a = ndf64_new3(n0, n1, n2)
	ndf64_fill(&a, v)
	return a


ndf64 ndf64_full4(int n0, int n1, int n2, int n3, float64 v):
	ndf64 a = ndf64_new4(n0, n1, n2, n3)
	ndf64_fill(&a, v)
	return a


ndf64 ndf64_wrap1(float64[] data, int n0):
	ndf64 a
	int n = ndf64_init_shape(&a, 1, n0, 1, 1, 1)
	asserts(c"ndf64_wrap1: buffer length does not match extents", data.length == n)
	a.data = data
	return a


ndf64 ndf64_wrap2(float64[] data, int n0, int n1):
	ndf64 a
	int n = ndf64_init_shape(&a, 2, n0, n1, 1, 1)
	asserts(c"ndf64_wrap2: buffer length does not match extents", data.length == n)
	a.data = data
	return a


ndf64 ndf64_wrap3(float64[] data, int n0, int n1, int n2):
	ndf64 a
	int n = ndf64_init_shape(&a, 3, n0, n1, n2, 1)
	asserts(c"ndf64_wrap3: buffer length does not match extents", data.length == n)
	a.data = data
	return a


ndf64 ndf64_wrap4(float64[] data, int n0, int n1, int n2, int n3):
	ndf64 a
	int n = ndf64_init_shape(&a, 4, n0, n1, n2, n3)
	asserts(c"ndf64_wrap4: buffer length does not match extents", data.length == n)
	a.data = data
	return a


##### accessors: per-axis bounds-checked, one pair per rank #####


float64 ndf64_at1(ndf64* a, int i):
	asserts(c"ndf64_at1: index out of range", i >= 0 && i < a.n0)
	return a.data[i]


void ndf64_set1(ndf64* a, int i, float64 v):
	asserts(c"ndf64_set1: index out of range", i >= 0 && i < a.n0)
	a.data[i] = v


float64 ndf64_at2(ndf64* a, int i, int j):
	asserts(c"ndf64_at2: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1)
	return a.data[i * a.s0 + j]


void ndf64_set2(ndf64* a, int i, int j, float64 v):
	asserts(c"ndf64_set2: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1)
	a.data[i * a.s0 + j] = v


float64 ndf64_at3(ndf64* a, int i, int j, int k):
	asserts(c"ndf64_at3: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2)
	return a.data[i * a.s0 + j * a.s1 + k]


void ndf64_set3(ndf64* a, int i, int j, int k, float64 v):
	asserts(c"ndf64_set3: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2)
	a.data[i * a.s0 + j * a.s1 + k] = v


float64 ndf64_at4(ndf64* a, int i, int j, int k, int l):
	asserts(c"ndf64_at4: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2 && l >= 0 && l < a.n3)
	return a.data[i * a.s0 + j * a.s1 + k * a.s2 + l]


void ndf64_set4(ndf64* a, int i, int j, int k, int l, float64 v):
	asserts(c"ndf64_set4: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2 && l >= 0 && l < a.n3)
	a.data[i * a.s0 + j * a.s1 + k * a.s2 + l] = v


##### views: contiguous only, per the doc (general strided views deferred) #####


float64[] ndf64_row(ndf64* a, int i):
	asserts(c"ndf64_row: rank must be 2", a.rank == 2)
	asserts(c"ndf64_row: index out of range", i >= 0 && i < a.n0)
	return a.data[i * a.s0 : i * a.s0 + a.n1]


ndf64 ndf64_sub(ndf64* a, int i0, int i1):
	asserts(c"ndf64_sub: index range out of bounds", i0 >= 0 && i1 <= a.n0 && i0 <= i1)
	ndf64 out
	out.rank = a.rank
	out.n0 = i1 - i0
	out.n1 = a.n1
	out.n2 = a.n2
	out.n3 = a.n3
	out.s0 = a.s0
	out.s1 = a.s1
	out.s2 = a.s2
	out.s3 = a.s3
	out.data = a.data[i0 * a.s0 : i1 * a.s0]
	return out


int ndf64_is_contiguous(ndf64* a):
	int expected_s2 = a.n3
	int expected_s1 = a.n2 * a.n3
	int expected_s0 = a.n1 * a.n2 * a.n3
	return a.s3 == 1 && a.s2 == expected_s2 && a.s1 == expected_s1 && a.s0 == expected_s0


##### elementwise ops: explicit, non-allocating, in-place forms #####


void ndf64_assert_same_shape(ndf64* a, ndf64* b, char* who):
	asserts(who, a.rank == b.rank && a.n0 == b.n0 && a.n1 == b.n1 && a.n2 == b.n2 && a.n3 == b.n3)


void ndf64_add_into(ndf64* out, ndf64* a, ndf64* b):
	ndf64_assert_same_shape(a, b, c"ndf64_add_into: shape mismatch")
	ndf64_assert_same_shape(a, out, c"ndf64_add_into: output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] + b.data[i]
		i = i + 1


void ndf64_mul_into(ndf64* out, ndf64* a, ndf64* b):
	ndf64_assert_same_shape(a, b, c"ndf64_mul_into: shape mismatch")
	ndf64_assert_same_shape(a, out, c"ndf64_mul_into: output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] * b.data[i]
		i = i + 1


void ndf64_add_scalar_into(ndf64* out, ndf64* a, float64 s):
	ndf64_assert_same_shape(a, out, c"ndf64_add_scalar_into: output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] + s
		i = i + 1


void ndf64_mul_scalar_into(ndf64* out, ndf64* a, float64 s):
	ndf64_assert_same_shape(a, out, c"ndf64_mul_scalar_into: output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] * s
		i = i + 1


type ndf64_map_fn = fn(float64) -> float64


void ndf64_map(ndf64* out, ndf64* a, ndf64_map_fn* fn):
	ndf64_assert_same_shape(a, out, c"ndf64_map: output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = fn(a.data[i])
		i = i + 1


##### matmul: 2-D only #####


void ndf64_matmul2(ndf64* out, ndf64* a, ndf64* b):
	asserts(c"ndf64_matmul2: rank must be 2", a.rank == 2 && b.rank == 2 && out.rank == 2)
	asserts(c"ndf64_matmul2: inner dimensions must match", a.n1 == b.n0)
	asserts(c"ndf64_matmul2: output shape mismatch", out.n0 == a.n0 && out.n1 == b.n1)
	asserts(c"ndf64_matmul2: output must not alias an input", out != a && out != b)
	int i = 0
	while (i < a.n0):
		int j = 0
		while (j < b.n1):
			float64 sum = 0.0
			int k = 0
			while (k < a.n1):
				sum = sum + ndf64_at2(a, i, k) * ndf64_at2(b, k, j)
				k = k + 1
			ndf64_set2(out, i, j, sum)
			j = j + 1
		i = i + 1
