/*
lib.ndarray: dense row-major multi-dimensional arrays (rank 1-4), v1 of
docs/projects/ndarray.md. Two types, every target:

- ndf: float32 backing buffer, for solver/CFD-shaped numeric data.
- ndi: int backing buffer, for index maps and connectivity.

Design recap (see the doc for the full rationale): an ndarray is not a
new compiler descriptor -- it is the existing two-word T[] slice
descriptor (docs/projects/arrays_slices_strings.md) plus an ordinary
struct carrying shape/stride metadata. Rank is fixed at <= 4 (scalar
per-axis fields, not a fixed-array `int[4] shape`, so the struct stays a
plain copyable word-struct); unused trailing axes hold extent 1 and
stride 1. Layout is always row-major/C-order at construction (innermost
stride 1), matching what parallel_for chunking and a future PTX/SIMD
lowering want (docs/todo.txt; docs/projects/cuda.md Stage 2). General
strided views (transposes, column views) are out of scope for v1 -- the
stride fields exist so that story can land later without a struct
change.

Grammar-level indexing sugar (`a[i, j]`) is explicitly deferred by the
design doc; this is the library-accessor surface only (`a.at2(i, j)` /
`a.set2(i, j, v)` via struct-method sugar, docs/projects/struct_methods.md).

Bounds policy, per the doc:
1. Default accessors (atN/setN) are per-axis checked unconditionally
   (fatal assert on failure, lib/stats.w precedent) -- a flat slice trap
   alone cannot catch a wrapped column index, and a library cannot see
   --bounds.
2. Code indexing `.data` or a `.row()` slice directly gets the standard
   inline slice traps, governed by --bounds like any other buffer access.
3. Hot loops that hoist a raw `T*` off `.data.data` are unchecked by
   design (docs/projects/arrays_slices_strings.md keeps legacy `p[i]`
   outside the bounds machinery) -- not reproduced here, see the doc.

Freeing: ndf_free/ndi_free release the backing buffer through the
slice-level array_free helper (lib/array.w, the
docs/projects/arrays_slices_strings.md Milestone 5 shape). Free only
arrays that OWN their buffer (from ndX_newN/onesN/fullN, or a wrapN
over a full `new T[n]` slice): there is no is-view flag, so freeing a
row/sub view is on the caller -- array_free's header assert refuses
proper sub views best-effort, but a full-range view frees the one
shared buffer for every alias. See ndf_free below for the poisoned
post-free state.

Parallel variants: lib/ndarray_par.w (a separate module because it
imports lib.thread, which is Linux x86/x64 only -- this file stays
importable on every target) carries the parallel_for-chunked twins of
the elementwise ops and the two-phase sum reduction, Stage 3 of the
design doc.

Naming: imports merge into one flat global namespace, so every symbol is
prefixed ndf_/ndi_ (ndarray_ for the handful of shape-math helpers the
two types share). Every ndf_/ndi_ function (and lib/ndarray64.w's
ndf64_ twin) is a one-line instantiation of the generic ndx_ core below,
generic over the struct type A and its element type T; the public names
stay because the `a[i, j]` sugar (grammar/ndarray_index.w) and the
struct-method sugar resolve accessors by name. Elementwise ops and matmul exist only for ndf --
CFD-shaped arithmetic is the float use case; ndi is index maps, not a
math type. No operator arithmetic (`u + v`) by design: every op is an
explicit, non-allocating in-place form (`ndf_add_into` etc.), matching
the doc's Explicit non-goals -- solvers want to control allocation.
*/
import lib.lib
import lib.assert
import lib.array


########################## shared shape helpers ##########################
#
# Row-major stride/length computation, identical for ndf and ndi (pure
# int arithmetic, no struct dependency), so both types' init_shape
# helpers below call through this one copy.


# Native int limits, computed by shifting a 1 into the sign bit so the
# same code is right on the 32-bit and 64-bit targets (structures/json.w
# precedent).
int ndarray_int_max():
	int low = 1
	while (low > 0):
		low = low << 1
	return 0 - (low + 1)


# a * b, fatally asserting on overflow. Callers only ever pass positive
# operands (extents, or products of extents already checked positive),
# so the standard a > max/b overflow test applies directly.
int ndarray_mul_checked(int a, int b):
	if (a == 0 || b == 0):
		return 0
	asserts(c"ndarray: extent product overflow", a <= ndarray_int_max() / b)
	return a * b


# Row-major strides for extents (n0, n1, n2, n3): s3 = 1, s2 = n3,
# s1 = n2*n3, s0 = n1*n2*n3, written through the out pointers. Returns
# the total element count n0*n1*n2*n3. Extents must be positive (fatal
# assert); rank <= 4 means unused trailing axes are always passed as 1
# by the per-rank constructors, so this function never sees a "true"
# rank -- it just does the row-major math for four extents.
int ndarray_shape_init(int n0, int n1, int n2, int n3, int* s0_out, int* s1_out, int* s2_out, int* s3_out):
	asserts(c"ndarray: extents must be positive", n0 > 0 && n1 > 0 && n2 > 0 && n3 > 0)
	*s3_out = 1
	*s2_out = n3
	*s1_out = ndarray_mul_checked(n2, n3)
	*s0_out = ndarray_mul_checked(n1, *s1_out)
	return ndarray_mul_checked(n0, *s0_out)


############################ generic ndx_ core ############################
#
# A is a struct shaped like ndf (a T[] data slice plus rank, n0..n3 and
# s0..s3); every public ndf_/ndi_/ndf64_ function instantiates one of
# these with its own struct and element type. Fatal asserts name the
# public function: `who` is its name and the failure text is
# "<who>: <what>", exactly what the per-type copies used to print.


# asserts(), with the message split into the caller's name and the
# failure text so the generic bodies need no per-type literals.
void ndx_check(int ok, char* who, char* what):
	if (ok == 0):
		print_error(who)
		asserts(what, 0)


# Fills in rank/extents and row-major strides on *a, returns the total
# element count. Does not touch a.data -- callers allocate or attach a
# buffer afterward.
int ndx_init_shape[A](A* a, int rank, int n0, int n1, int n2, int n3):
	a.rank = rank
	a.n0 = n0
	a.n1 = n1
	a.n2 = n2
	a.n3 = n3
	return ndarray_shape_init(n0, n1, n2, n3, &a.s0, &a.s1, &a.s2, &a.s3)


##### construction #####
#
# newN allocates a fresh zero-filled buffer (new T[n] zeroes its
# payload, docs/projects/arrays_slices_strings.md Milestone 5, so v1
# inherits zero-init rather than reimplementing it); that allocation is
# each type's own X_new_shape, since a generic cannot say `new T[n]`
# yet. onesN/fullN are newN plus an explicit refill. wrapN attaches an already-allocated
# buffer without copying or allocating, for zero-copy interop; the
# buffer's length must exactly match the extent product.


# Explicit refill: overwrite every element (constructors already start
# zero-filled, so this is for reuse / non-zero/non-constant refills).
void ndx_fill[A, T](A* a, T v):
	int i = 0
	while (i < a.data.length):
		a.data[i] = v
		i = i + 1


# a, refilled with v (onesN/fullN: a fresh newN array plus the refill).
A ndx_filled[A, T](A a, T v):
	ndx_fill[A, T](&a, v)
	return a


A ndx_wrap[A, T](T[] data, int rank, int n0, int n1, int n2, int n3, char* who):
	A a
	int n = ndx_init_shape[A](&a, rank, n0, n1, n2, n3)
	ndx_check(data.length == n, who, c": buffer length does not match extents")
	a.data = data
	return a


##### freeing #####
#
# Releases the backing buffer through lib/array.w's array_free (see
# that file for exactly which buffers may be freed and which misuses
# the header assert catches). The descriptor is dead afterwards: rank
# and every extent are zeroed, so every checked atN/setN call on a
# freed array fails its bounds assert instead of touching freed memory
# (a.data itself is left dangling -- raw `.data` access after free is
# use-after-free, same as any freed pointer). Views (row/sub results)
# share the freed buffer and are dead too; there is no is-view flag, so
# nothing stops a caller from freeing THROUGH a full-range view -- it is
# the same one buffer either way.


void ndx_free[A, T](A* a):
	array_free[T](a.data)
	a.rank = 0
	a.n0 = 0
	a.n1 = 0
	a.n2 = 0
	a.n3 = 0


##### accessors: per-axis bounds-checked, one pair per rank #####


T ndx_at1[A, T](A* a, int i, char* who):
	ndx_check(i >= 0 && i < a.n0, who, c": index out of range")
	return a.data[i]


void ndx_set1[A, T](A* a, int i, T v, char* who):
	ndx_check(i >= 0 && i < a.n0, who, c": index out of range")
	a.data[i] = v


T ndx_at2[A, T](A* a, int i, int j, char* who):
	ndx_check(i >= 0 && i < a.n0 && j >= 0 && j < a.n1, who, c": index out of range")
	return a.data[i * a.s0 + j]


void ndx_set2[A, T](A* a, int i, int j, T v, char* who):
	ndx_check(i >= 0 && i < a.n0 && j >= 0 && j < a.n1, who, c": index out of range")
	a.data[i * a.s0 + j] = v


T ndx_at3[A, T](A* a, int i, int j, int k, char* who):
	ndx_check(i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2, who, c": index out of range")
	return a.data[i * a.s0 + j * a.s1 + k]


void ndx_set3[A, T](A* a, int i, int j, int k, T v, char* who):
	ndx_check(i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2, who, c": index out of range")
	a.data[i * a.s0 + j * a.s1 + k] = v


T ndx_at4[A, T](A* a, int i, int j, int k, int l, char* who):
	ndx_check(i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2 && l >= 0 && l < a.n3, who, c": index out of range")
	return a.data[i * a.s0 + j * a.s1 + k * a.s2 + l]


void ndx_set4[A, T](A* a, int i, int j, int k, int l, T v, char* who):
	ndx_check(i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2 && l >= 0 && l < a.n3, who, c": index out of range")
	a.data[i * a.s0 + j * a.s1 + k * a.s2 + l] = v


##### views: contiguous only, per the doc (general strided views deferred) #####


# Leading-axis subrange [i0, i1): an array sharing a's buffer, n0 = i1 -
# i0, trailing extents/strides unchanged. Domain decomposition without
# copies -- the parallel_for contract's per-worker block.
A ndx_sub[A](A* a, int i0, int i1, char* who):
	ndx_check(i0 >= 0 && i1 <= a.n0 && i0 <= i1, who, c": index range out of bounds")
	A out
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


# 1 when the strides match the row-major product of the extents -- the
# precondition views/kernels/I/O can rely on (constructed arrays are
# always contiguous; sub preserves it, since it only shrinks n0).
int ndx_is_contiguous[A](A* a):
	int expected_s2 = a.n3
	int expected_s1 = a.n2 * a.n3
	int expected_s0 = a.n1 * a.n2 * a.n3
	return a.s3 == 1 && a.s2 == expected_s2 && a.s1 == expected_s1 && a.s0 == expected_s0


##### elementwise ops (float types only): explicit, non-allocating, in-place #####
#
# No `u + v` operator sugar (docs/projects/operator_overloading.md v1
# excludes struct []; each such use would also silently allocate a
# result array, which solvers don't want). out may alias a and/or b --
# every op reads a.data[i]/b.data[i] before writing out.data[i], so
# aliasing the same index is safe; the shapes must match exactly (rank
# and every extent), fatal assert otherwise.


int ndx_same_shape[A](A* a, A* b):
	return a.rank == b.rank && a.n0 == b.n0 && a.n1 == b.n1 && a.n2 == b.n2 && a.n3 == b.n3


void ndx_add_into[A](A* out, A* a, A* b, char* who):
	ndx_check(ndx_same_shape[A](a, b), who, c": shape mismatch")
	ndx_check(ndx_same_shape[A](a, out), who, c": output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] + b.data[i]
		i = i + 1


void ndx_mul_into[A](A* out, A* a, A* b, char* who):
	ndx_check(ndx_same_shape[A](a, b), who, c": shape mismatch")
	ndx_check(ndx_same_shape[A](a, out), who, c": output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] * b.data[i]
		i = i + 1


void ndx_add_scalar_into[A, T](A* out, A* a, T s, char* who):
	ndx_check(ndx_same_shape[A](a, out), who, c": output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] + s
		i = i + 1


void ndx_mul_scalar_into[A, T](A* out, A* a, T s, char* who):
	ndx_check(ndx_same_shape[A](a, out), who, c": output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] * s
		i = i + 1


# out[i] = s * x[i] + y[i] (the axpy shape); out may alias x and/or y.
# The serial reference for lib/ndarray_par.w's ndf_axpy_into_par, which
# must produce bit-identical results.
void ndx_axpy_into[A, T](A* out, T s, A* x, A* y, char* who):
	ndx_check(ndx_same_shape[A](x, y), who, c": shape mismatch")
	ndx_check(ndx_same_shape[A](x, out), who, c": output shape mismatch")
	int i = 0
	while (i < x.data.length):
		out.data[i] = s * x.data[i] + y.data[i]
		i = i + 1


# Left-to-right sum of every element in flat (row-major) order. The
# serial reference for lib/ndarray_par.w's two-phase ndf_sum_par, which
# matches it bit-for-bit only in the single-chunk case (a different
# chunking changes the float association, not correctness).
T ndx_sum[A, T](A* a):
	T total = 0.0
	int i = 0
	while (i < a.data.length):
		total = total + a.data[i]
		i = i + 1
	return total


##### matmul: 2-D only #####


# out = a @ b for rank-2 a (m x k), b (k x n), out (m x n). Naive
# O(m*n*k) triple loop -- v1 has no SIMD/blocking. The shape asserts
# up front are exactly the at2/set2 bounds, so the loop indexes the flat
# buffers directly. out must not be the same descriptor as a or b
# (asserted); aliasing the same underlying buffer through separately
# constructed descriptors is undefined, per the doc's aliasing rule.
void ndx_matmul2[A, T](A* out, A* a, A* b, char* who):
	ndx_check(a.rank == 2 && b.rank == 2 && out.rank == 2, who, c": rank must be 2")
	ndx_check(a.n1 == b.n0, who, c": inner dimensions must match")
	ndx_check(out.n0 == a.n0 && out.n1 == b.n1, who, c": output shape mismatch")
	ndx_check(out != a && out != b, who, c": output must not alias an input")
	int i = 0
	while (i < a.n0):
		int j = 0
		while (j < b.n1):
			T sum = 0.0
			int k = 0
			while (k < a.n1):
				sum = sum + a.data[i * a.s0 + k] * b.data[k * b.s0 + j]
				k = k + 1
			out.data[i * out.s0 + j] = sum
			j = j + 1
		i = i + 1


############################## ndf: float32 ###############################


struct ndf:
	float[] data   # flat backing buffer; length = n0*n1*n2*n3
	int rank       # 1..4
	int n0         # extents; unused trailing axes hold 1
	int n1
	int n2
	int n3
	int s0         # element strides; row-major at construction
	int s1
	int s2
	int s3


# The public ndf surface: each is the ndx_ core above at (ndf, float).
int ndf_init_shape(ndf* a, int rank, int n0, int n1, int n2, int n3): return ndx_init_shape[ndf](a, rank, n0, n1, n2, n3)


# A fresh zero-filled ndf of the given rank and extents.
ndf ndf_new_shape(int rank, int n0, int n1, int n2, int n3):
	ndf a
	a.data = new float[ndx_init_shape[ndf](&a, rank, n0, n1, n2, n3)]
	return a


ndf ndf_new1(int n0): return ndf_new_shape(1, n0, 1, 1, 1)
ndf ndf_new2(int n0, int n1): return ndf_new_shape(2, n0, n1, 1, 1)
ndf ndf_new3(int n0, int n1, int n2): return ndf_new_shape(3, n0, n1, n2, 1)
ndf ndf_new4(int n0, int n1, int n2, int n3): return ndf_new_shape(4, n0, n1, n2, n3)
void ndf_fill(ndf* a, float v): ndx_fill[ndf, float](a, v)
ndf ndf_ones1(int n0): return ndx_filled[ndf, float](ndf_new_shape(1, n0, 1, 1, 1), 1.0)
ndf ndf_ones2(int n0, int n1): return ndx_filled[ndf, float](ndf_new_shape(2, n0, n1, 1, 1), 1.0)
ndf ndf_ones3(int n0, int n1, int n2): return ndx_filled[ndf, float](ndf_new_shape(3, n0, n1, n2, 1), 1.0)
ndf ndf_ones4(int n0, int n1, int n2, int n3): return ndx_filled[ndf, float](ndf_new_shape(4, n0, n1, n2, n3), 1.0)
ndf ndf_full1(int n0, float v): return ndx_filled[ndf, float](ndf_new_shape(1, n0, 1, 1, 1), v)
ndf ndf_full2(int n0, int n1, float v): return ndx_filled[ndf, float](ndf_new_shape(2, n0, n1, 1, 1), v)
ndf ndf_full3(int n0, int n1, int n2, float v): return ndx_filled[ndf, float](ndf_new_shape(3, n0, n1, n2, 1), v)
ndf ndf_full4(int n0, int n1, int n2, int n3, float v): return ndx_filled[ndf, float](ndf_new_shape(4, n0, n1, n2, n3), v)
ndf ndf_wrap1(float[] data, int n0): return ndx_wrap[ndf, float](data, 1, n0, 1, 1, 1, c"ndf_wrap1")
ndf ndf_wrap2(float[] data, int n0, int n1): return ndx_wrap[ndf, float](data, 2, n0, n1, 1, 1, c"ndf_wrap2")
ndf ndf_wrap3(float[] data, int n0, int n1, int n2): return ndx_wrap[ndf, float](data, 3, n0, n1, n2, 1, c"ndf_wrap3")
ndf ndf_wrap4(float[] data, int n0, int n1, int n2, int n3): return ndx_wrap[ndf, float](data, 4, n0, n1, n2, n3, c"ndf_wrap4")
void ndf_free(ndf* a): ndx_free[ndf, float](a)

float ndf_at1(ndf* a, int i): return ndx_at1[ndf, float](a, i, c"ndf_at1")
void ndf_set1(ndf* a, int i, float v): ndx_set1[ndf, float](a, i, v, c"ndf_set1")
float ndf_at2(ndf* a, int i, int j): return ndx_at2[ndf, float](a, i, j, c"ndf_at2")
void ndf_set2(ndf* a, int i, int j, float v): ndx_set2[ndf, float](a, i, j, v, c"ndf_set2")
float ndf_at3(ndf* a, int i, int j, int k): return ndx_at3[ndf, float](a, i, j, k, c"ndf_at3")
void ndf_set3(ndf* a, int i, int j, int k, float v): ndx_set3[ndf, float](a, i, j, k, v, c"ndf_set3")
float ndf_at4(ndf* a, int i, int j, int k, int l): return ndx_at4[ndf, float](a, i, j, k, l, c"ndf_at4")
void ndf_set4(ndf* a, int i, int j, int k, int l, float v): ndx_set4[ndf, float](a, i, j, k, l, v, c"ndf_set4")


# The float[] row slice of a rank-2 array -- the inner-loop workhorse.
# Aliases a's buffer (slice semantics): writes through the returned
# slice are visible in a. (Not in the ndx_ core: a generic cannot
# return a T[] slice yet.)
float[] ndf_row(ndf* a, int i):
	ndx_check(a.rank == 2, c"ndf_row", c": rank must be 2")
	ndx_check(i >= 0 && i < a.n0, c"ndf_row", c": index out of range")
	return a.data[i * a.s0 : i * a.s0 + a.n1]


ndf ndf_sub(ndf* a, int i0, int i1): return ndx_sub[ndf](a, i0, i1, c"ndf_sub")
int ndf_is_contiguous(ndf* a): return ndx_is_contiguous[ndf](a)

void ndf_assert_same_shape(ndf* a, ndf* b, char* who): asserts(who, ndx_same_shape[ndf](a, b))
void ndf_add_into(ndf* out, ndf* a, ndf* b): ndx_add_into[ndf](out, a, b, c"ndf_add_into")
void ndf_mul_into(ndf* out, ndf* a, ndf* b): ndx_mul_into[ndf](out, a, b, c"ndf_mul_into")
void ndf_add_scalar_into(ndf* out, ndf* a, float s): ndx_add_scalar_into[ndf, float](out, a, s, c"ndf_add_scalar_into")
void ndf_mul_scalar_into(ndf* out, ndf* a, float s): ndx_mul_scalar_into[ndf, float](out, a, s, c"ndf_mul_scalar_into")
void ndf_axpy_into(ndf* out, float s, ndf* x, ndf* y): ndx_axpy_into[ndf, float](out, s, x, y, c"ndf_axpy_into")
float ndf_sum(ndf* a): return ndx_sum[ndf, float](a)
void ndf_matmul2(ndf* out, ndf* a, ndf* b): ndx_matmul2[ndf, float](out, a, b, c"ndf_matmul2")


type ndf_map_fn = fn(float) -> float


# out[i] = fn(a[i]) for every flat element; out may alias a for an
# in-place map.
void ndf_map(ndf* out, ndf* a, ndf_map_fn* fn):
	ndx_check(ndx_same_shape[ndf](a, out), c"ndf_map", c": output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = fn(a.data[i])
		i = i + 1


################################ ndi: int #################################
#
# Index maps and connectivity: same shape/stride/view surface as ndf,
# minus the arithmetic (elementwise ops, matmul) -- those are ndf's job.


struct ndi:
	int[] data     # flat backing buffer; length = n0*n1*n2*n3
	int rank       # 1..4
	int n0         # extents; unused trailing axes hold 1
	int n1
	int n2
	int n3
	int s0         # element strides; row-major at construction
	int s1
	int s2
	int s3


int ndi_init_shape(ndi* a, int rank, int n0, int n1, int n2, int n3): return ndx_init_shape[ndi](a, rank, n0, n1, n2, n3)


# A fresh zero-filled ndi of the given rank and extents.
ndi ndi_new_shape(int rank, int n0, int n1, int n2, int n3):
	ndi a
	a.data = new int[ndx_init_shape[ndi](&a, rank, n0, n1, n2, n3)]
	return a


ndi ndi_new1(int n0): return ndi_new_shape(1, n0, 1, 1, 1)
ndi ndi_new2(int n0, int n1): return ndi_new_shape(2, n0, n1, 1, 1)
ndi ndi_new3(int n0, int n1, int n2): return ndi_new_shape(3, n0, n1, n2, 1)
ndi ndi_new4(int n0, int n1, int n2, int n3): return ndi_new_shape(4, n0, n1, n2, n3)
void ndi_fill(ndi* a, int v): ndx_fill[ndi, int](a, v)
ndi ndi_ones1(int n0): return ndx_filled[ndi, int](ndi_new_shape(1, n0, 1, 1, 1), 1)
ndi ndi_ones2(int n0, int n1): return ndx_filled[ndi, int](ndi_new_shape(2, n0, n1, 1, 1), 1)
ndi ndi_ones3(int n0, int n1, int n2): return ndx_filled[ndi, int](ndi_new_shape(3, n0, n1, n2, 1), 1)
ndi ndi_ones4(int n0, int n1, int n2, int n3): return ndx_filled[ndi, int](ndi_new_shape(4, n0, n1, n2, n3), 1)
ndi ndi_full1(int n0, int v): return ndx_filled[ndi, int](ndi_new_shape(1, n0, 1, 1, 1), v)
ndi ndi_full2(int n0, int n1, int v): return ndx_filled[ndi, int](ndi_new_shape(2, n0, n1, 1, 1), v)
ndi ndi_full3(int n0, int n1, int n2, int v): return ndx_filled[ndi, int](ndi_new_shape(3, n0, n1, n2, 1), v)
ndi ndi_full4(int n0, int n1, int n2, int n3, int v): return ndx_filled[ndi, int](ndi_new_shape(4, n0, n1, n2, n3), v)
ndi ndi_wrap1(int[] data, int n0): return ndx_wrap[ndi, int](data, 1, n0, 1, 1, 1, c"ndi_wrap1")
ndi ndi_wrap2(int[] data, int n0, int n1): return ndx_wrap[ndi, int](data, 2, n0, n1, 1, 1, c"ndi_wrap2")
ndi ndi_wrap3(int[] data, int n0, int n1, int n2): return ndx_wrap[ndi, int](data, 3, n0, n1, n2, 1, c"ndi_wrap3")
ndi ndi_wrap4(int[] data, int n0, int n1, int n2, int n3): return ndx_wrap[ndi, int](data, 4, n0, n1, n2, n3, c"ndi_wrap4")
void ndi_free(ndi* a): ndx_free[ndi, int](a)

int ndi_at1(ndi* a, int i): return ndx_at1[ndi, int](a, i, c"ndi_at1")
void ndi_set1(ndi* a, int i, int v): ndx_set1[ndi, int](a, i, v, c"ndi_set1")
int ndi_at2(ndi* a, int i, int j): return ndx_at2[ndi, int](a, i, j, c"ndi_at2")
void ndi_set2(ndi* a, int i, int j, int v): ndx_set2[ndi, int](a, i, j, v, c"ndi_set2")
int ndi_at3(ndi* a, int i, int j, int k): return ndx_at3[ndi, int](a, i, j, k, c"ndi_at3")
void ndi_set3(ndi* a, int i, int j, int k, int v): ndx_set3[ndi, int](a, i, j, k, v, c"ndi_set3")
int ndi_at4(ndi* a, int i, int j, int k, int l): return ndx_at4[ndi, int](a, i, j, k, l, c"ndi_at4")
void ndi_set4(ndi* a, int i, int j, int k, int l, int v): ndx_set4[ndi, int](a, i, j, k, l, v, c"ndi_set4")


# The int[] row slice of a rank-2 array -- the inner-loop workhorse.
# Aliases a's buffer (slice semantics): writes through the returned
# slice are visible in a. (Not in the ndx_ core: a generic cannot
# return a T[] slice yet.)
int[] ndi_row(ndi* a, int i):
	ndx_check(a.rank == 2, c"ndi_row", c": rank must be 2")
	ndx_check(i >= 0 && i < a.n0, c"ndi_row", c": index out of range")
	return a.data[i * a.s0 : i * a.s0 + a.n1]


ndi ndi_sub(ndi* a, int i0, int i1): return ndx_sub[ndi](a, i0, i1, c"ndi_sub")
int ndi_is_contiguous(ndi* a): return ndx_is_contiguous[ndi](a)
