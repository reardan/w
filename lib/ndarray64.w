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
(construction variants, per-rank checked accessors, contiguous-only
views, explicit in-place elementwise ops + map, 2-D matmul) with float
replaced by float64 throughout: every function is the same generic ndx_
core lib/ndarray.w instantiates for ndf, here at (ndf64, float64) --
generic bodies are only compiled when instantiated, so lib.ndarray stays
importable on the 32-bit default where float64 is a compile error. See
that file's header for the shared design rationale and
docs/projects/ndarray.md for the full spec. Bounds/shape asserts,
aliasing rules and the "no operator arithmetic" stance are identical to
the float32 module.
*/
import lib.lib
import lib.assert
import lib.ndarray


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


int ndf64_init_shape(ndf64* a, int rank, int n0, int n1, int n2, int n3): return ndx_init_shape[ndf64](a, rank, n0, n1, n2, n3)


# A fresh zero-filled ndf64 of the given rank and extents.
ndf64 ndf64_new_shape(int rank, int n0, int n1, int n2, int n3):
	ndf64 a
	a.data = new float64[ndx_init_shape[ndf64](&a, rank, n0, n1, n2, n3)]
	return a


ndf64 ndf64_new1(int n0): return ndf64_new_shape(1, n0, 1, 1, 1)
ndf64 ndf64_new2(int n0, int n1): return ndf64_new_shape(2, n0, n1, 1, 1)
ndf64 ndf64_new3(int n0, int n1, int n2): return ndf64_new_shape(3, n0, n1, n2, 1)
ndf64 ndf64_new4(int n0, int n1, int n2, int n3): return ndf64_new_shape(4, n0, n1, n2, n3)
void ndf64_fill(ndf64* a, float64 v): ndx_fill[ndf64, float64](a, v)
ndf64 ndf64_ones1(int n0): return ndx_filled[ndf64, float64](ndf64_new_shape(1, n0, 1, 1, 1), 1.0)
ndf64 ndf64_ones2(int n0, int n1): return ndx_filled[ndf64, float64](ndf64_new_shape(2, n0, n1, 1, 1), 1.0)
ndf64 ndf64_ones3(int n0, int n1, int n2): return ndx_filled[ndf64, float64](ndf64_new_shape(3, n0, n1, n2, 1), 1.0)
ndf64 ndf64_ones4(int n0, int n1, int n2, int n3): return ndx_filled[ndf64, float64](ndf64_new_shape(4, n0, n1, n2, n3), 1.0)
ndf64 ndf64_full1(int n0, float64 v): return ndx_filled[ndf64, float64](ndf64_new_shape(1, n0, 1, 1, 1), v)
ndf64 ndf64_full2(int n0, int n1, float64 v): return ndx_filled[ndf64, float64](ndf64_new_shape(2, n0, n1, 1, 1), v)
ndf64 ndf64_full3(int n0, int n1, int n2, float64 v): return ndx_filled[ndf64, float64](ndf64_new_shape(3, n0, n1, n2, 1), v)
ndf64 ndf64_full4(int n0, int n1, int n2, int n3, float64 v): return ndx_filled[ndf64, float64](ndf64_new_shape(4, n0, n1, n2, n3), v)
ndf64 ndf64_wrap1(float64[] data, int n0): return ndx_wrap[ndf64, float64](data, 1, n0, 1, 1, 1, c"ndf64_wrap1")
ndf64 ndf64_wrap2(float64[] data, int n0, int n1): return ndx_wrap[ndf64, float64](data, 2, n0, n1, 1, 1, c"ndf64_wrap2")
ndf64 ndf64_wrap3(float64[] data, int n0, int n1, int n2): return ndx_wrap[ndf64, float64](data, 3, n0, n1, n2, 1, c"ndf64_wrap3")
ndf64 ndf64_wrap4(float64[] data, int n0, int n1, int n2, int n3): return ndx_wrap[ndf64, float64](data, 4, n0, n1, n2, n3, c"ndf64_wrap4")
void ndf64_free(ndf64* a): ndx_free[ndf64, float64](a)

float64 ndf64_at1(ndf64* a, int i): return ndx_at1[ndf64, float64](a, i, c"ndf64_at1")
void ndf64_set1(ndf64* a, int i, float64 v): ndx_set1[ndf64, float64](a, i, v, c"ndf64_set1")
float64 ndf64_at2(ndf64* a, int i, int j): return ndx_at2[ndf64, float64](a, i, j, c"ndf64_at2")
void ndf64_set2(ndf64* a, int i, int j, float64 v): ndx_set2[ndf64, float64](a, i, j, v, c"ndf64_set2")
float64 ndf64_at3(ndf64* a, int i, int j, int k): return ndx_at3[ndf64, float64](a, i, j, k, c"ndf64_at3")
void ndf64_set3(ndf64* a, int i, int j, int k, float64 v): ndx_set3[ndf64, float64](a, i, j, k, v, c"ndf64_set3")
float64 ndf64_at4(ndf64* a, int i, int j, int k, int l): return ndx_at4[ndf64, float64](a, i, j, k, l, c"ndf64_at4")
void ndf64_set4(ndf64* a, int i, int j, int k, int l, float64 v): ndx_set4[ndf64, float64](a, i, j, k, l, v, c"ndf64_set4")


# The float64[] row slice of a rank-2 array -- the inner-loop workhorse.
# Aliases a's buffer (slice semantics): writes through the returned
# slice are visible in a. (Not in the ndx_ core: a generic cannot
# return a T[] slice yet.)
float64[] ndf64_row(ndf64* a, int i):
	ndx_check(a.rank == 2, c"ndf64_row", c": rank must be 2")
	ndx_check(i >= 0 && i < a.n0, c"ndf64_row", c": index out of range")
	return a.data[i * a.s0 : i * a.s0 + a.n1]


ndf64 ndf64_sub(ndf64* a, int i0, int i1): return ndx_sub[ndf64](a, i0, i1, c"ndf64_sub")
int ndf64_is_contiguous(ndf64* a): return ndx_is_contiguous[ndf64](a)

void ndf64_assert_same_shape(ndf64* a, ndf64* b, char* who): asserts(who, ndx_same_shape[ndf64](a, b))
void ndf64_add_into(ndf64* out, ndf64* a, ndf64* b): ndx_add_into[ndf64](out, a, b, c"ndf64_add_into")
void ndf64_mul_into(ndf64* out, ndf64* a, ndf64* b): ndx_mul_into[ndf64](out, a, b, c"ndf64_mul_into")
void ndf64_add_scalar_into(ndf64* out, ndf64* a, float64 s): ndx_add_scalar_into[ndf64, float64](out, a, s, c"ndf64_add_scalar_into")
void ndf64_mul_scalar_into(ndf64* out, ndf64* a, float64 s): ndx_mul_scalar_into[ndf64, float64](out, a, s, c"ndf64_mul_scalar_into")
void ndf64_axpy_into(ndf64* out, float64 s, ndf64* x, ndf64* y): ndx_axpy_into[ndf64, float64](out, s, x, y, c"ndf64_axpy_into")
float64 ndf64_sum(ndf64* a): return ndx_sum[ndf64, float64](a)
void ndf64_matmul2(ndf64* out, ndf64* a, ndf64* b): ndx_matmul2[ndf64, float64](out, a, b, c"ndf64_matmul2")


type ndf64_map_fn = fn(float64) -> float64


# out[i] = fn(a[i]) for every flat element; out may alias a for an
# in-place map.
void ndf64_map(ndf64* out, ndf64* a, ndf64_map_fn* fn):
	ndx_check(ndx_same_shape[ndf64](a, out), c"ndf64_map", c": output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = fn(a.data[i])
		i = i + 1
