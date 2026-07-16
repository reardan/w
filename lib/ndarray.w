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

Freeing: heap slices have no landed free helper yet
(docs/projects/arrays_slices_strings.md Milestone 5), so v1 ndarrays are
allocate-and-keep. An ndf_free/ndi_free lands together with that helper.

Naming: imports merge into one flat global namespace, so every symbol is
prefixed ndf_/ndi_ (ndarray_ for the handful of shape-math helpers the
two types share). Elementwise ops and matmul exist only for ndf --
CFD-shaped arithmetic is the float use case; ndi is index maps, not a
math type. No operator arithmetic (`u + v`) by design: every op is an
explicit, non-allocating in-place form (`ndf_add_into` etc.), matching
the doc's Explicit non-goals -- solvers want to control allocation.
*/
import lib.lib
import lib.assert


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


# Shared by every ndf_newN/onesN/fullN/wrapN: fills in rank/extents and
# row-major strides on *a, returns the total element count. Does not
# touch a.data -- callers allocate or attach a buffer afterward.
int ndf_init_shape(ndf* a, int rank, int n0, int n1, int n2, int n3):
	a.rank = rank
	a.n0 = n0
	a.n1 = n1
	a.n2 = n2
	a.n3 = n3
	return ndarray_shape_init(n0, n1, n2, n3, &a.s0, &a.s1, &a.s2, &a.s3)


##### construction #####
#
# ndf_newN allocates a fresh zero-filled buffer (new T[n] zeroes its
# payload, docs/projects/arrays_slices_strings.md Milestone 5, so v1
# inherits zero-init rather than reimplementing it). ndf_onesN/fullN are
# ndf_newN plus an explicit refill. ndf_wrapN attaches an
# already-allocated buffer without copying or allocating, for
# zero-copy interop; the buffer's length must exactly match the extent
# product.


ndf ndf_new1(int n0):
	ndf a
	int n = ndf_init_shape(&a, 1, n0, 1, 1, 1)
	a.data = new float[n]
	return a


ndf ndf_new2(int n0, int n1):
	ndf a
	int n = ndf_init_shape(&a, 2, n0, n1, 1, 1)
	a.data = new float[n]
	return a


ndf ndf_new3(int n0, int n1, int n2):
	ndf a
	int n = ndf_init_shape(&a, 3, n0, n1, n2, 1)
	a.data = new float[n]
	return a


ndf ndf_new4(int n0, int n1, int n2, int n3):
	ndf a
	int n = ndf_init_shape(&a, 4, n0, n1, n2, n3)
	a.data = new float[n]
	return a


# Explicit refill: overwrite every element (constructors already start
# zero-filled, so this is for reuse / non-zero/non-constant refills).
void ndf_fill(ndf* a, float v):
	int i = 0
	while (i < a.data.length):
		a.data[i] = v
		i = i + 1


ndf ndf_ones1(int n0):
	ndf a = ndf_new1(n0)
	ndf_fill(&a, 1.0)
	return a


ndf ndf_ones2(int n0, int n1):
	ndf a = ndf_new2(n0, n1)
	ndf_fill(&a, 1.0)
	return a


ndf ndf_ones3(int n0, int n1, int n2):
	ndf a = ndf_new3(n0, n1, n2)
	ndf_fill(&a, 1.0)
	return a


ndf ndf_ones4(int n0, int n1, int n2, int n3):
	ndf a = ndf_new4(n0, n1, n2, n3)
	ndf_fill(&a, 1.0)
	return a


ndf ndf_full1(int n0, float v):
	ndf a = ndf_new1(n0)
	ndf_fill(&a, v)
	return a


ndf ndf_full2(int n0, int n1, float v):
	ndf a = ndf_new2(n0, n1)
	ndf_fill(&a, v)
	return a


ndf ndf_full3(int n0, int n1, int n2, float v):
	ndf a = ndf_new3(n0, n1, n2)
	ndf_fill(&a, v)
	return a


ndf ndf_full4(int n0, int n1, int n2, int n3, float v):
	ndf a = ndf_new4(n0, n1, n2, n3)
	ndf_fill(&a, v)
	return a


ndf ndf_wrap1(float[] data, int n0):
	ndf a
	int n = ndf_init_shape(&a, 1, n0, 1, 1, 1)
	asserts(c"ndf_wrap1: buffer length does not match extents", data.length == n)
	a.data = data
	return a


ndf ndf_wrap2(float[] data, int n0, int n1):
	ndf a
	int n = ndf_init_shape(&a, 2, n0, n1, 1, 1)
	asserts(c"ndf_wrap2: buffer length does not match extents", data.length == n)
	a.data = data
	return a


ndf ndf_wrap3(float[] data, int n0, int n1, int n2):
	ndf a
	int n = ndf_init_shape(&a, 3, n0, n1, n2, 1)
	asserts(c"ndf_wrap3: buffer length does not match extents", data.length == n)
	a.data = data
	return a


ndf ndf_wrap4(float[] data, int n0, int n1, int n2, int n3):
	ndf a
	int n = ndf_init_shape(&a, 4, n0, n1, n2, n3)
	asserts(c"ndf_wrap4: buffer length does not match extents", data.length == n)
	a.data = data
	return a


##### accessors: per-axis bounds-checked, one pair per rank #####


float ndf_at1(ndf* a, int i):
	asserts(c"ndf_at1: index out of range", i >= 0 && i < a.n0)
	return a.data[i]


void ndf_set1(ndf* a, int i, float v):
	asserts(c"ndf_set1: index out of range", i >= 0 && i < a.n0)
	a.data[i] = v


float ndf_at2(ndf* a, int i, int j):
	asserts(c"ndf_at2: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1)
	return a.data[i * a.s0 + j]


void ndf_set2(ndf* a, int i, int j, float v):
	asserts(c"ndf_set2: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1)
	a.data[i * a.s0 + j] = v


float ndf_at3(ndf* a, int i, int j, int k):
	asserts(c"ndf_at3: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2)
	return a.data[i * a.s0 + j * a.s1 + k]


void ndf_set3(ndf* a, int i, int j, int k, float v):
	asserts(c"ndf_set3: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2)
	a.data[i * a.s0 + j * a.s1 + k] = v


float ndf_at4(ndf* a, int i, int j, int k, int l):
	asserts(c"ndf_at4: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2 && l >= 0 && l < a.n3)
	return a.data[i * a.s0 + j * a.s1 + k * a.s2 + l]


void ndf_set4(ndf* a, int i, int j, int k, int l, float v):
	asserts(c"ndf_set4: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2 && l >= 0 && l < a.n3)
	a.data[i * a.s0 + j * a.s1 + k * a.s2 + l] = v


##### views: contiguous only, per the doc (general strided views deferred) #####


# The float[] row slice of a rank-2 array -- the inner-loop workhorse.
# Aliases a's buffer (slice semantics): writes through the returned
# slice are visible in a.
float[] ndf_row(ndf* a, int i):
	asserts(c"ndf_row: rank must be 2", a.rank == 2)
	asserts(c"ndf_row: index out of range", i >= 0 && i < a.n0)
	return a.data[i * a.s0 : i * a.s0 + a.n1]


# Leading-axis subrange [i0, i1): an ndf sharing a's buffer, n0 = i1 -
# i0, trailing extents/strides unchanged. Domain decomposition without
# copies -- the parallel_for contract's per-worker block.
ndf ndf_sub(ndf* a, int i0, int i1):
	asserts(c"ndf_sub: index range out of bounds", i0 >= 0 && i1 <= a.n0 && i0 <= i1)
	ndf out
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
# always contiguous; ndf_sub preserves it, since it only shrinks n0).
int ndf_is_contiguous(ndf* a):
	int expected_s2 = a.n3
	int expected_s1 = a.n2 * a.n3
	int expected_s0 = a.n1 * a.n2 * a.n3
	return a.s3 == 1 && a.s2 == expected_s2 && a.s1 == expected_s1 && a.s0 == expected_s0


##### elementwise ops: explicit, non-allocating, in-place forms #####
#
# No `u + v` operator sugar (docs/projects/operator_overloading.md v1
# excludes struct []; each such use would also silently allocate a
# result array, which solvers don't want). out may alias a and/or b --
# every op reads a.data[i]/b.data[i] before writing out.data[i], so
# aliasing the same index is safe; the shapes must match exactly (rank
# and every extent), fatal assert otherwise.


void ndf_assert_same_shape(ndf* a, ndf* b, char* who):
	asserts(who, a.rank == b.rank && a.n0 == b.n0 && a.n1 == b.n1 && a.n2 == b.n2 && a.n3 == b.n3)


void ndf_add_into(ndf* out, ndf* a, ndf* b):
	ndf_assert_same_shape(a, b, c"ndf_add_into: shape mismatch")
	ndf_assert_same_shape(a, out, c"ndf_add_into: output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] + b.data[i]
		i = i + 1


void ndf_mul_into(ndf* out, ndf* a, ndf* b):
	ndf_assert_same_shape(a, b, c"ndf_mul_into: shape mismatch")
	ndf_assert_same_shape(a, out, c"ndf_mul_into: output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] * b.data[i]
		i = i + 1


void ndf_add_scalar_into(ndf* out, ndf* a, float s):
	ndf_assert_same_shape(a, out, c"ndf_add_scalar_into: output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] + s
		i = i + 1


void ndf_mul_scalar_into(ndf* out, ndf* a, float s):
	ndf_assert_same_shape(a, out, c"ndf_mul_scalar_into: output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] * s
		i = i + 1


type ndf_map_fn = fn(float) -> float


# out[i] = fn(a[i]) for every flat element; out may alias a for an
# in-place map.
void ndf_map(ndf* out, ndf* a, ndf_map_fn* fn):
	ndf_assert_same_shape(a, out, c"ndf_map: output shape mismatch")
	int i = 0
	while (i < a.data.length):
		out.data[i] = fn(a.data[i])
		i = i + 1


##### matmul: 2-D only #####


# out = a @ b for rank-2 a (m x k), b (k x n), out (m x n). Naive
# O(m*n*k) triple loop through the checked at2/set2 accessors -- v1
# has no SIMD/blocking. out must not be the same descriptor as a or b
# (asserted); aliasing the same underlying buffer through separately
# constructed descriptors is undefined, per the doc's aliasing rule.
void ndf_matmul2(ndf* out, ndf* a, ndf* b):
	asserts(c"ndf_matmul2: rank must be 2", a.rank == 2 && b.rank == 2 && out.rank == 2)
	asserts(c"ndf_matmul2: inner dimensions must match", a.n1 == b.n0)
	asserts(c"ndf_matmul2: output shape mismatch", out.n0 == a.n0 && out.n1 == b.n1)
	asserts(c"ndf_matmul2: output must not alias an input", out != a && out != b)
	int i = 0
	while (i < a.n0):
		int j = 0
		while (j < b.n1):
			float sum = 0.0
			int k = 0
			while (k < a.n1):
				sum = sum + ndf_at2(a, i, k) * ndf_at2(b, k, j)
				k = k + 1
			ndf_set2(out, i, j, sum)
			j = j + 1
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


int ndi_init_shape(ndi* a, int rank, int n0, int n1, int n2, int n3):
	a.rank = rank
	a.n0 = n0
	a.n1 = n1
	a.n2 = n2
	a.n3 = n3
	return ndarray_shape_init(n0, n1, n2, n3, &a.s0, &a.s1, &a.s2, &a.s3)


ndi ndi_new1(int n0):
	ndi a
	int n = ndi_init_shape(&a, 1, n0, 1, 1, 1)
	a.data = new int[n]
	return a


ndi ndi_new2(int n0, int n1):
	ndi a
	int n = ndi_init_shape(&a, 2, n0, n1, 1, 1)
	a.data = new int[n]
	return a


ndi ndi_new3(int n0, int n1, int n2):
	ndi a
	int n = ndi_init_shape(&a, 3, n0, n1, n2, 1)
	a.data = new int[n]
	return a


ndi ndi_new4(int n0, int n1, int n2, int n3):
	ndi a
	int n = ndi_init_shape(&a, 4, n0, n1, n2, n3)
	a.data = new int[n]
	return a


void ndi_fill(ndi* a, int v):
	int i = 0
	while (i < a.data.length):
		a.data[i] = v
		i = i + 1


ndi ndi_ones1(int n0):
	ndi a = ndi_new1(n0)
	ndi_fill(&a, 1)
	return a


ndi ndi_ones2(int n0, int n1):
	ndi a = ndi_new2(n0, n1)
	ndi_fill(&a, 1)
	return a


ndi ndi_ones3(int n0, int n1, int n2):
	ndi a = ndi_new3(n0, n1, n2)
	ndi_fill(&a, 1)
	return a


ndi ndi_ones4(int n0, int n1, int n2, int n3):
	ndi a = ndi_new4(n0, n1, n2, n3)
	ndi_fill(&a, 1)
	return a


ndi ndi_full1(int n0, int v):
	ndi a = ndi_new1(n0)
	ndi_fill(&a, v)
	return a


ndi ndi_full2(int n0, int n1, int v):
	ndi a = ndi_new2(n0, n1)
	ndi_fill(&a, v)
	return a


ndi ndi_full3(int n0, int n1, int n2, int v):
	ndi a = ndi_new3(n0, n1, n2)
	ndi_fill(&a, v)
	return a


ndi ndi_full4(int n0, int n1, int n2, int n3, int v):
	ndi a = ndi_new4(n0, n1, n2, n3)
	ndi_fill(&a, v)
	return a


ndi ndi_wrap1(int[] data, int n0):
	ndi a
	int n = ndi_init_shape(&a, 1, n0, 1, 1, 1)
	asserts(c"ndi_wrap1: buffer length does not match extents", data.length == n)
	a.data = data
	return a


ndi ndi_wrap2(int[] data, int n0, int n1):
	ndi a
	int n = ndi_init_shape(&a, 2, n0, n1, 1, 1)
	asserts(c"ndi_wrap2: buffer length does not match extents", data.length == n)
	a.data = data
	return a


ndi ndi_wrap3(int[] data, int n0, int n1, int n2):
	ndi a
	int n = ndi_init_shape(&a, 3, n0, n1, n2, 1)
	asserts(c"ndi_wrap3: buffer length does not match extents", data.length == n)
	a.data = data
	return a


ndi ndi_wrap4(int[] data, int n0, int n1, int n2, int n3):
	ndi a
	int n = ndi_init_shape(&a, 4, n0, n1, n2, n3)
	asserts(c"ndi_wrap4: buffer length does not match extents", data.length == n)
	a.data = data
	return a


int ndi_at1(ndi* a, int i):
	asserts(c"ndi_at1: index out of range", i >= 0 && i < a.n0)
	return a.data[i]


void ndi_set1(ndi* a, int i, int v):
	asserts(c"ndi_set1: index out of range", i >= 0 && i < a.n0)
	a.data[i] = v


int ndi_at2(ndi* a, int i, int j):
	asserts(c"ndi_at2: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1)
	return a.data[i * a.s0 + j]


void ndi_set2(ndi* a, int i, int j, int v):
	asserts(c"ndi_set2: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1)
	a.data[i * a.s0 + j] = v


int ndi_at3(ndi* a, int i, int j, int k):
	asserts(c"ndi_at3: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2)
	return a.data[i * a.s0 + j * a.s1 + k]


void ndi_set3(ndi* a, int i, int j, int k, int v):
	asserts(c"ndi_set3: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2)
	a.data[i * a.s0 + j * a.s1 + k] = v


int ndi_at4(ndi* a, int i, int j, int k, int l):
	asserts(c"ndi_at4: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2 && l >= 0 && l < a.n3)
	return a.data[i * a.s0 + j * a.s1 + k * a.s2 + l]


void ndi_set4(ndi* a, int i, int j, int k, int l, int v):
	asserts(c"ndi_set4: index out of range", i >= 0 && i < a.n0 && j >= 0 && j < a.n1 && k >= 0 && k < a.n2 && l >= 0 && l < a.n3)
	a.data[i * a.s0 + j * a.s1 + k * a.s2 + l] = v


int[] ndi_row(ndi* a, int i):
	asserts(c"ndi_row: rank must be 2", a.rank == 2)
	asserts(c"ndi_row: index out of range", i >= 0 && i < a.n0)
	return a.data[i * a.s0 : i * a.s0 + a.n1]


ndi ndi_sub(ndi* a, int i0, int i1):
	asserts(c"ndi_sub: index range out of bounds", i0 >= 0 && i1 <= a.n0 && i0 <= i1)
	ndi out
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


int ndi_is_contiguous(ndi* a):
	int expected_s2 = a.n3
	int expected_s1 = a.n2 * a.n3
	int expected_s0 = a.n1 * a.n2 * a.n3
	return a.s3 == 1 && a.s2 == expected_s2 && a.s1 == expected_s1 && a.s0 == expected_s0
