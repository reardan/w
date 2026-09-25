/*
lib.matrix: a dedicated 2-D float matrix type (issue #27).

lib/ndarray.w is the numeric substrate -- rank 1-4 arrays with explicit,
non-allocating in-place ops, deliberately without operator arithmetic.
This module is the linear-algebra layer on top of that storage model:

	import lib.matrix

	matrix a = matrix_from2(2, 2, 4.0, 7.0, 2.0, 6.0)
	matrix i = a * matrix_inverse(&a)    # operator overloads
	float d = a.det()                    # struct-method sugar
	a[0, 1] = 3.0                        # comma-index sugar

Layout: dense row-major float storage in a flat float[] slice, element
(i, j) at data[i * cols + j] -- the same layout as a rank-2 ndf, so
matrix_as_ndf wraps a matrix as an ndf with no copy and every lib.ndarray
elementwise op / reduction applies to it directly.

Operators (docs/projects/operator_overloading.md): + and - are
elementwise, matrix * matrix is the matrix product, matrix * float and
float * matrix scale, matrix / float divides. Every operator ALLOCATES
its result (a fresh owning matrix) -- that is the point of the type,
readable formula code. Hot loops that must control allocation keep
using the *_into forms here or the lib.ndarray in-place ops. Shape
mismatches are fatal asserts, like the ndarray accessors.

Freeing: matrix_free releases the backing buffer. There is no garbage
collection, so a chained expression like `a * b + c` leaks its
intermediate (a * b); free the named results you own and bind
intermediates to names when the leak matters.

MATLAB parity: beyond the core above, the module covers MATLAB's
everyday matrix surface under matrix_ names --
	construction  rand randn linspace diag diag_of reshape block
	              set_block hcat vcat repmat triu tril kron
	elementwise   ediv (./) epow (.^) abs sqrt exp log neg map, and
	              matrix +/- float operators in both orders
	reductions    sum_dim mean_dim mean min max argmin argmax dot
	              cross norm_fro norm1 norm_inf norm2
	factorize     lu chol qr eig_sym svd singular_values rank pinv cond
Differences from MATLAB: indices are 0-based and block ranges
half-open; reshape walks row-major; eig handles symmetric matrices
only; svd is the economy size; decompositions write their factors
through out-pointers ([L, U, P] = lu(A) is matrix_lu(&a, &l, &u, &p)).

Methods: every matrix_X(matrix* m, ...) function is callable as
m.X(...) (docs/projects/struct_methods.md): m.at(i, j), m.set(i, j, v),
m.transpose(), m.det(), m.trace(), m.inverse(), m.print(), ...

Numerics: float is float32 on the 32-bit target, so det/inverse/solve
use partial pivoting and treat a pivot within MATRIX_SINGULAR_EPS of
the largest entry's magnitude as singular. matrix_near compares within
an absolute tolerance -- exact float equality is the wrong test for
anything that went through a division.

Naming: imports merge into one flat global namespace, so every symbol
is prefixed matrix_.
*/
import lib.lib
import lib.assert
import lib.array
import lib.format
import lib.ndarray
import lib.fmath
import lib.rand


struct matrix:
	float[] data   # row-major, length rows * cols
	int rows
	int cols


# Relative singularity threshold for det/inverse/solve pivots, scaled by
# the largest-magnitude entry of the matrix being factored.
float matrix_singular_eps():
	return 0.000001


float matrix_fabs(float f):
	if (f < 0.0): return 0.0 - f
	return f


##### construction #####


# A rows x cols matrix of zeros (new T[n] zero-fills its payload).
matrix matrix_new(int rows, int cols):
	asserts(c"matrix_new: dimensions must be positive", rows > 0 && cols > 0)
	matrix m
	m.rows = rows
	m.cols = cols
	m.data = new float[ndarray_mul_checked(rows, cols)]
	return m


void matrix_fill(matrix* m, float v):
	int i = 0
	while (i < m.data.length):
		m.data[i] = v
		i = i + 1


matrix matrix_zeros(int rows, int cols):
	return matrix_new(rows, cols)


matrix matrix_full(int rows, int cols, float v):
	matrix m = matrix_new(rows, cols)
	matrix_fill(&m, v)
	return m


# The n x n identity.
matrix matrix_identity(int n):
	matrix m = matrix_new(n, n)
	for i in range(n): m.data[i * n + i] = 1.0
	return m


# Copy row-major values out of a float slice; data.length must equal
# rows * cols. The matrix owns a fresh buffer (the slice is not kept).
matrix matrix_from(float[] data, int rows, int cols):
	asserts(c"matrix_from: data length must equal rows * cols", data.length == ndarray_mul_checked(rows, cols))
	matrix m = matrix_new(rows, cols)
	int i = 0
	while (i < data.length):
		m.data[i] = data[i]
		i = i + 1
	return m


# Literal 2x2 and 3x3 constructors, row-major argument order.
matrix matrix_from2(float a, float b, float c, float d):
	matrix m = matrix_new(2, 2)
	m.data[0] = a
	m.data[1] = b
	m.data[2] = c
	m.data[3] = d
	return m


matrix matrix_from3(float a, float b, float c, float d, float e, float f, float g, float h, float i):
	matrix m = matrix_new(3, 3)
	m.data[0] = a
	m.data[1] = b
	m.data[2] = c
	m.data[3] = d
	m.data[4] = e
	m.data[5] = f
	m.data[6] = g
	m.data[7] = h
	m.data[8] = i
	return m


# An n x 1 column vector from a float slice (copied).
matrix matrix_column(float[] data):
	return matrix_from(data, data.length, 1)


matrix matrix_copy(matrix* m):
	matrix r = matrix_new(m.rows, m.cols)
	for i in range(m.data.length): r.data[i] = m.data[i]
	return r


# Release the backing buffer and zero the shape, so a later accessor
# on the freed matrix trips its bounds assert instead of reading freed
# memory through a stale shape.
void matrix_free(matrix* m):
	array_free[float](m.data)
	m.rows = 0
	m.cols = 0


##### ndarray interop #####


# Zero-copy rank-2 ndf view over the matrix's buffer: the two share
# storage, so writes through either are visible in both. Free only one
# of them.
ndf matrix_as_ndf(matrix* m):
	return ndf_wrap2(m.data, m.rows, m.cols)


# Copy a rank-2 ndf into a new matrix (the ndf keeps its buffer).
matrix matrix_from_ndf(ndf* a):
	asserts(c"matrix_from_ndf: rank must be 2", a.rank == 2)
	matrix m = matrix_new(a.n0, a.n1)
	int i = 0
	while (i < a.n0):
		int j = 0
		while (j < a.n1):
			m.data[i * m.cols + j] = ndf_at2(a, i, j)
			j = j + 1
		i = i + 1
	return m


##### element access #####
#
# at/set are per-axis bounds-checked (a flat slice trap cannot catch a
# wrapped column index). at2/set2 are the same accessors under the
# names the comma-index sugar lowers to: m[i, j] -> matrix_at2(m, i, j).


float matrix_at(matrix* m, int i, int j):
	asserts(c"matrix_at: index out of range", i >= 0 && i < m.rows && j >= 0 && j < m.cols)
	return m.data[i * m.cols + j]


void matrix_set(matrix* m, int i, int j, float v):
	asserts(c"matrix_set: index out of range", i >= 0 && i < m.rows && j >= 0 && j < m.cols)
	m.data[i * m.cols + j] = v


float matrix_at2(matrix* m, int i, int j):
	return matrix_at(m, i, j)


void matrix_set2(matrix* m, int i, int j, float v):
	matrix_set(m, i, j, v)


int matrix_is_square(matrix* m):
	return m.rows == m.cols


int matrix_same_shape(matrix* a, matrix* b):
	return a.rows == b.rows && a.cols == b.cols


# Row i / column j as new owning 1 x cols / rows x 1 matrices.
matrix matrix_row(matrix* m, int i):
	asserts(c"matrix_row: index out of range", i >= 0 && i < m.rows)
	matrix r = matrix_new(1, m.cols)
	for j in range(m.cols): r.data[j] = m.data[i * m.cols + j]
	return r


matrix matrix_col(matrix* m, int j):
	asserts(c"matrix_col: index out of range", j >= 0 && j < m.cols)
	matrix r = matrix_new(m.rows, 1)
	for i in range(m.rows): r.data[i] = m.data[i * m.cols + j]
	return r


##### in-place (non-allocating) arithmetic #####
#
# out may alias a or b for the elementwise forms (each output element
# depends only on the same-position inputs); matmul_into may not.


void matrix_add_into(matrix* out, matrix* a, matrix* b):
	asserts(c"matrix_add: shape mismatch", matrix_same_shape(a, b) && matrix_same_shape(out, a))
	for i in range(a.data.length): out.data[i] = a.data[i] + b.data[i]


void matrix_sub_into(matrix* out, matrix* a, matrix* b):
	asserts(c"matrix_sub: shape mismatch", matrix_same_shape(a, b) && matrix_same_shape(out, a))
	for i in range(a.data.length): out.data[i] = a.data[i] - b.data[i]


void matrix_scale_into(matrix* out, matrix* a, float s):
	asserts(c"matrix_scale: shape mismatch", matrix_same_shape(out, a))
	for i in range(a.data.length): out.data[i] = a.data[i] * s


# Elementwise (Hadamard) product.
void matrix_hadamard_into(matrix* out, matrix* a, matrix* b):
	asserts(c"matrix_hadamard: shape mismatch", matrix_same_shape(a, b) && matrix_same_shape(out, a))
	for i in range(a.data.length): out.data[i] = a.data[i] * b.data[i]


# out = a * b (matrix product), a is m x k, b is k x n, out is m x n.
void matrix_matmul_into(matrix* out, matrix* a, matrix* b):
	asserts(c"matrix_mul: inner dimensions must match", a.cols == b.rows)
	asserts(c"matrix_mul: output shape mismatch", out.rows == a.rows && out.cols == b.cols)
	asserts(c"matrix_mul: output must not alias an input", out.data.data != a.data.data && out.data.data != b.data.data)
	int i = 0
	while (i < a.rows):
		for j in range(b.cols):
			float sum = 0.0
			for k in range(a.cols): sum = sum + a.data[i * a.cols + k] * b.data[k * b.cols + j]
			out.data[i * out.cols + j] = sum
		i = i + 1


##### allocating arithmetic #####


matrix matrix_add(matrix* a, matrix* b):
	matrix r = matrix_new(a.rows, a.cols)
	matrix_add_into(&r, a, b)
	return r


matrix matrix_sub(matrix* a, matrix* b):
	matrix r = matrix_new(a.rows, a.cols)
	matrix_sub_into(&r, a, b)
	return r


matrix matrix_scale(matrix* a, float s):
	matrix r = matrix_new(a.rows, a.cols)
	matrix_scale_into(&r, a, s)
	return r


matrix matrix_hadamard(matrix* a, matrix* b):
	matrix r = matrix_new(a.rows, a.cols)
	matrix_hadamard_into(&r, a, b)
	return r


matrix matrix_mul(matrix* a, matrix* b):
	asserts(c"matrix_mul: inner dimensions must match", a.cols == b.rows)
	matrix r = matrix_new(a.rows, b.cols)
	matrix_matmul_into(&r, a, b)
	return r


matrix matrix_transpose(matrix* m):
	matrix r = matrix_new(m.cols, m.rows)
	int i = 0
	while (i < m.rows):
		for j in range(m.cols): r.data[j * r.cols + i] = m.data[i * m.cols + j]
		i = i + 1
	return r


# Integer power of a square matrix by repeated squaring; p == 0 is the
# identity.
matrix matrix_pow(matrix* m, int p):
	asserts(c"matrix_pow: matrix must be square", matrix_is_square(m))
	asserts(c"matrix_pow: exponent must be non-negative", p >= 0)
	matrix result = matrix_identity(m.rows)
	matrix base = matrix_copy(m)
	while (p > 0):
		if (p % 2 == 1):
			matrix t = matrix_mul(&result, &base)
			matrix_free(&result)
			result = t
		p = p / 2
		if (p > 0):
			matrix sq = matrix_mul(&base, &base)
			matrix_free(&base)
			base = sq
	matrix_free(&base)
	return result


##### operators #####


matrix operator+(matrix a, matrix b):
	return matrix_add(&a, &b)


matrix operator-(matrix a, matrix b):
	return matrix_sub(&a, &b)


matrix operator*(matrix a, matrix b):
	return matrix_mul(&a, &b)


matrix operator*(matrix a, float s):
	return matrix_scale(&a, s)


matrix operator*(float s, matrix a):
	return matrix_scale(&a, s)


matrix operator/(matrix a, float s):
	return matrix_scale(&a, 1.0 / s)


##### reductions #####


float matrix_trace(matrix* m):
	asserts(c"matrix_trace: matrix must be square", matrix_is_square(m))
	float sum = 0.0
	for i in range(m.rows): sum = sum + m.data[i * m.cols + i]
	return sum


float matrix_sum(matrix* m):
	float sum = 0.0
	for i in range(m.data.length): sum = sum + m.data[i]
	return sum


float matrix_max_abs(matrix* m):
	float best = 0.0
	int i = 0
	while (i < m.data.length):
		float v = matrix_fabs(m.data[i])
		if (v > best): best = v
		i = i + 1
	return best


# 1 when every element of a and b differs by at most tol (and the
# shapes match), else 0.
int matrix_near(matrix* a, matrix* b, float tol):
	if (matrix_same_shape(a, b) == 0): return 0
	int i = 0
	while (i < a.data.length):
		if (matrix_fabs(a.data[i] - b.data[i]) > tol): return 0
		i = i + 1
	return 1


# 1 when the shapes match and every element is exactly equal.
int matrix_equal(matrix* a, matrix* b):
	if (matrix_same_shape(a, b) == 0): return 0
	int i = 0
	while (i < a.data.length):
		if (a.data[i] != b.data[i]): return 0
		i = i + 1
	return 1


##### elimination: det / inverse / solve #####


# Swap rows r1 and r2 of m in place.
void matrix_swap_rows(matrix* m, int r1, int r2):
	if (r1 == r2): return
	int j = 0
	while (j < m.cols):
		float t = m.data[r1 * m.cols + j]
		m.data[r1 * m.cols + j] = m.data[r2 * m.cols + j]
		m.data[r2 * m.cols + j] = t
		j = j + 1


# Index of the row at or below 'from' with the largest |m[row, col]|.
int matrix_pivot_row(matrix* m, int col, int from):
	int best = from
	float best_v = matrix_fabs(m.data[from * m.cols + col])
	int r = from + 1
	while (r < m.rows):
		float v = matrix_fabs(m.data[r * m.cols + col])
		if (v > best_v):
			best = r
			best_v = v
		r = r + 1
	return best


# Determinant by Gaussian elimination with partial pivoting on a copy.
# A pivot below the singularity threshold gives exactly 0.0.
float matrix_det(matrix* m):
	asserts(c"matrix_det: matrix must be square", matrix_is_square(m))
	int n = m.rows
	matrix a = matrix_copy(m)
	float eps = matrix_singular_eps() * matrix_max_abs(m)
	float det = 1.0
	int col = 0
	while (col < n):
		int p = matrix_pivot_row(&a, col, col)
		float pivot = a.data[p * n + col]
		if (matrix_fabs(pivot) <= eps):
			matrix_free(&a)
			return 0.0
		if (p != col):
			matrix_swap_rows(&a, p, col)
			det = 0.0 - det
		det = det * pivot
		int r = col + 1
		while (r < n):
			float f = a.data[r * n + col] / pivot
			for j in range(col, n): a.data[r * n + j] = a.data[r * n + j] - f * a.data[col * n + j]
			r = r + 1
		col = col + 1
	matrix_free(&a)
	return det


# Solve a * x = b by Gauss-Jordan elimination with partial pivoting,
# writing x into out (a.rows x b.cols; b may have several right-hand
# side columns). Returns 1 on success, 0 when a is singular (out is
# then left unspecified). a and b are not modified.
int matrix_solve_into(matrix* out, matrix* a, matrix* b):
	asserts(c"matrix_solve: matrix must be square", matrix_is_square(a))
	asserts(c"matrix_solve: right-hand side row count must match", b.rows == a.rows)
	asserts(c"matrix_solve: output shape mismatch", out.rows == b.rows && out.cols == b.cols)
	int n = a.rows
	int k = b.cols
	matrix l = matrix_copy(a)
	for i in range(b.data.length): out.data[i] = b.data[i]
	float eps = matrix_singular_eps() * matrix_max_abs(a)
	int col = 0
	while (col < n):
		int p = matrix_pivot_row(&l, col, col)
		float pivot = l.data[p * n + col]
		if (matrix_fabs(pivot) <= eps):
			matrix_free(&l)
			return 0
		matrix_swap_rows(&l, p, col)
		matrix_swap_rows(out, p, col)
		# normalize the pivot row
		int j = 0
		while (j < n):
			l.data[col * n + j] = l.data[col * n + j] / pivot
			j = j + 1
		j = 0
		while (j < k):
			out.data[col * k + j] = out.data[col * k + j] / pivot
			j = j + 1
		# eliminate the column from every other row
		int r = 0
		while (r < n):
			if (r != col):
				float f = l.data[r * n + col]
				if (f != 0.0):
					j = 0
					while (j < n):
						l.data[r * n + j] = l.data[r * n + j] - f * l.data[col * n + j]
						j = j + 1
					j = 0
					while (j < k):
						out.data[r * k + j] = out.data[r * k + j] - f * out.data[col * k + j]
						j = j + 1
			r = r + 1
		col = col + 1
	matrix_free(&l)
	return 1


# Allocating solve: fatal assert when a is singular.
matrix matrix_solve(matrix* a, matrix* b):
	matrix x = matrix_new(b.rows, b.cols)
	asserts(c"matrix_solve: matrix is singular", matrix_solve_into(&x, a, b))
	return x


# Returns 1 and writes a's inverse into out, or 0 when a is singular.
int matrix_inverse_into(matrix* out, matrix* a):
	matrix id = matrix_identity(a.rows)
	int ok = matrix_solve_into(out, a, &id)
	matrix_free(&id)
	return ok


# Allocating inverse: fatal assert when m is singular.
matrix matrix_inverse(matrix* m):
	asserts(c"matrix_inverse: matrix must be square", matrix_is_square(m))
	matrix r = matrix_new(m.rows, m.cols)
	asserts(c"matrix_inverse: matrix is singular", matrix_inverse_into(&r, m))
	return r


##### more construction (MATLAB: rand, randn, linspace, diag, reshape, [A B], [A; B], A(r, c), repmat, triu, tril, kron) #####


# Uniform [0, 1) entries drawn from r (lib/rand.w: deterministic for a
# given seed on every target).
matrix matrix_rand(int rows, int cols, rand_state* r):
	matrix m = matrix_new(rows, cols)
	int i = 0
	while (i < m.data.length):
		m.data[i] = rand_float(r)
		i = i + 1
	return m


# Standard normal entries drawn from r.
matrix matrix_randn(int rows, int cols, rand_state* r):
	matrix m = matrix_new(rows, cols)
	int i = 0
	while (i < m.data.length):
		m.data[i] = rand_gaussian(r)
		i = i + 1
	return m


# 1 x n row vector of n evenly spaced points from a to b inclusive.
matrix matrix_linspace(float a, float b, int n):
	asserts(c"matrix_linspace: need at least 2 points", n >= 2)
	matrix m = matrix_new(1, n)
	float step = (b - a) / (n - 1)
	for i in range(n): m.data[i] = a + step * i
	m.data[n - 1] = b
	return m


# Square matrix with the vector v (either orientation) on its diagonal.
matrix matrix_diag(matrix* v):
	asserts(c"matrix_diag: argument must be a vector", v.rows == 1 || v.cols == 1)
	int n = v.data.length
	matrix m = matrix_new(n, n)
	for i in range(n): m.data[i * n + i] = v.data[i]
	return m


# The main diagonal of m as a column vector.
matrix matrix_diag_of(matrix* m):
	int n = m.rows
	if (m.cols < n): n = m.cols
	matrix d = matrix_new(n, 1)
	for i in range(n): d.data[i] = m.data[i * m.cols + i]
	return d


# Same elements, new shape, in ROW-MAJOR order (MATLAB's reshape walks
# column-major; reshape(A', c, r)' is the MATLAB-order equivalent).
matrix matrix_reshape(matrix* m, int rows, int cols):
	asserts(c"matrix_reshape: element count must not change", ndarray_mul_checked(rows, cols) == m.data.length)
	matrix r = matrix_copy(m)
	r.rows = rows
	r.cols = cols
	return r


# Copy src into m with its top-left corner at (r0, c0).
void matrix_set_block(matrix* m, int r0, int c0, matrix* src):
	asserts(c"matrix_set_block: block out of range", r0 >= 0 && c0 >= 0 && r0 + src.rows <= m.rows && c0 + src.cols <= m.cols)
	int i = 0
	while (i < src.rows):
		for j in range(src.cols): m.data[(r0 + i) * m.cols + c0 + j] = src.data[i * src.cols + j]
		i = i + 1


# Rows [r0, r1) and columns [c0, c1) as a new matrix: MATLAB's
# A(r0+1:r1, c0+1:c1) with 0-based half-open ranges.
matrix matrix_block(matrix* m, int r0, int r1, int c0, int c1):
	asserts(c"matrix_block: range out of bounds", r0 >= 0 && r0 < r1 && r1 <= m.rows && c0 >= 0 && c0 < c1 && c1 <= m.cols)
	matrix r = matrix_new(r1 - r0, c1 - c0)
	int i = 0
	while (i < r.rows):
		int j = 0
		while (j < r.cols):
			r.data[i * r.cols + j] = m.data[(r0 + i) * m.cols + c0 + j]
			j = j + 1
		i = i + 1
	return r


# [a b]: side by side (row counts must match).
matrix matrix_hcat(matrix* a, matrix* b):
	asserts(c"matrix_hcat: row counts must match", a.rows == b.rows)
	matrix r = matrix_new(a.rows, a.cols + b.cols)
	matrix_set_block(&r, 0, 0, a)
	matrix_set_block(&r, 0, a.cols, b)
	return r


# [a; b]: stacked (column counts must match).
matrix matrix_vcat(matrix* a, matrix* b):
	asserts(c"matrix_vcat: column counts must match", a.cols == b.cols)
	matrix r = matrix_new(a.rows + b.rows, a.cols)
	matrix_set_block(&r, 0, 0, a)
	matrix_set_block(&r, a.rows, 0, b)
	return r


# m tiled rn times down and cn times across.
matrix matrix_repmat(matrix* m, int rn, int cn):
	asserts(c"matrix_repmat: counts must be positive", rn > 0 && cn > 0)
	matrix r = matrix_new(m.rows * rn, m.cols * cn)
	for i in range(rn):
		for j in range(cn): matrix_set_block(&r, i * m.rows, j * m.cols, m)
	return r


# Upper triangle on and above diagonal k (0 main, 1 above, -1 below).
matrix matrix_triu(matrix* m, int k):
	matrix r = matrix_copy(m)
	int i = 0
	while (i < m.rows):
		for j in range(m.cols):
			if (j - i < k): r.data[i * m.cols + j] = 0.0
		i = i + 1
	return r


# Lower triangle on and below diagonal k.
matrix matrix_tril(matrix* m, int k):
	matrix r = matrix_copy(m)
	int i = 0
	while (i < m.rows):
		for j in range(m.cols):
			if (j - i > k): r.data[i * m.cols + j] = 0.0
		i = i + 1
	return r


# Kronecker product: every a[i, j] scales a copy of b.
matrix matrix_kron(matrix* a, matrix* b):
	matrix r = matrix_new(a.rows * b.rows, a.cols * b.cols)
	int i = 0
	while (i < r.rows):
		int j = 0
		while (j < r.cols):
			float x = a.data[(i / b.rows) * a.cols + j / b.cols]
			r.data[i * r.cols + j] = x * b.data[(i % b.rows) * b.cols + j % b.cols]
			j = j + 1
		i = i + 1
	return r


##### elementwise (MATLAB: ./ .^ abs sqrt exp log, arrayfun) #####


type matrix_map_fn = fn(float) -> float


# fn applied to every element.
matrix matrix_map(matrix* m, matrix_map_fn* fn):
	matrix r = matrix_new(m.rows, m.cols)
	int i = 0
	while (i < m.data.length):
		r.data[i] = fn(m.data[i])
		i = i + 1
	return r


# a ./ b
matrix matrix_ediv(matrix* a, matrix* b):
	asserts(c"matrix_ediv: shape mismatch", matrix_same_shape(a, b))
	matrix r = matrix_new(a.rows, a.cols)
	for i in range(a.data.length): r.data[i] = a.data[i] / b.data[i]
	return r


# m .^ p (lib/fmath.w fpow: IEEE pow semantics).
matrix matrix_epow(matrix* m, float p):
	matrix r = matrix_new(m.rows, m.cols)
	int i = 0
	while (i < m.data.length):
		r.data[i] = fpow(m.data[i], p)
		i = i + 1
	return r


matrix matrix_abs(matrix* m):
	return matrix_map(m, fabs)


matrix matrix_sqrt(matrix* m):
	return matrix_map(m, fsqrt)


matrix matrix_exp(matrix* m):
	return matrix_map(m, fexp)


matrix matrix_log(matrix* m):
	return matrix_map(m, flog)


# -m (W has no unary operator overloads).
matrix matrix_neg(matrix* m):
	return matrix_scale(m, -1.0)


matrix matrix_add_scalar(matrix* m, float s):
	matrix r = matrix_new(m.rows, m.cols)
	for i in range(m.data.length): r.data[i] = m.data[i] + s
	return r


matrix operator+(matrix a, float s):
	return matrix_add_scalar(&a, s)


matrix operator+(float s, matrix a):
	return matrix_add_scalar(&a, s)


matrix operator-(matrix a, float s):
	return matrix_add_scalar(&a, 0.0 - s)


# s - a, elementwise.
matrix operator-(float s, matrix a):
	matrix r = matrix_neg(&a)
	int i = 0
	while (i < r.data.length):
		r.data[i] = r.data[i] + s
		i = i + 1
	return r


##### reductions (MATLAB: sum, mean, min, max, norm, dot, cross) #####


# MATLAB's sum(A, dim): dim 1 sums down each column (1 x cols), dim 2
# sums across each row (rows x 1).
matrix matrix_sum_dim(matrix* m, int dim):
	asserts(c"matrix_sum_dim: dim must be 1 or 2", dim == 1 || dim == 2)
	matrix r
	if (dim == 1): r = matrix_new(1, m.cols)
	else: r = matrix_new(m.rows, 1)
	int i = 0
	while (i < m.rows):
		for j in range(m.cols):
			if (dim == 1): r.data[j] = r.data[j] + m.data[i * m.cols + j]
			else: r.data[i] = r.data[i] + m.data[i * m.cols + j]
		i = i + 1
	return r


# MATLAB's mean(A, dim), same shape rules as matrix_sum_dim.
matrix matrix_mean_dim(matrix* m, int dim):
	matrix r = matrix_sum_dim(m, dim)
	int n = m.cols
	if (dim == 1): n = m.rows
	matrix_scale_into(&r, &r, 1.0 / n)
	return r


# Mean of every element.
float matrix_mean(matrix* m):
	return matrix_sum(m) / m.data.length


# Index of the smallest (want_max == 0) or largest element, flat
# row-major; ties keep the first.
int matrix_arg_extreme(matrix* m, int want_max):
	int best = 0
	int i = 1
	while (i < m.data.length):
		if (want_max && m.data[i] > m.data[best]): best = i
		if ((want_max == 0) && m.data[i] < m.data[best]): best = i
		i = i + 1
	return best


# Flat row-major index of the smallest / largest element: row is
# index / cols, column is index % cols.
int matrix_argmin(matrix* m):
	return matrix_arg_extreme(m, 0)


int matrix_argmax(matrix* m):
	return matrix_arg_extreme(m, 1)


float matrix_min(matrix* m):
	return m.data[matrix_argmin(m)]


float matrix_max(matrix* m):
	return m.data[matrix_argmax(m)]


# Dot product of two vectors of equal length, either orientation.
float matrix_dot(matrix* a, matrix* b):
	asserts(c"matrix_dot: arguments must be vectors", (a.rows == 1 || a.cols == 1) && (b.rows == 1 || b.cols == 1))
	asserts(c"matrix_dot: lengths must match", a.data.length == b.data.length)
	float sum = 0.0
	for i in range(a.data.length): sum = sum + a.data[i] * b.data[i]
	return sum


# Cross product of two 3-vectors; the result has a's orientation.
matrix matrix_cross(matrix* a, matrix* b):
	asserts(c"matrix_cross: arguments must be 3-vectors", a.data.length == 3 && b.data.length == 3 && (a.rows == 1 || a.cols == 1))
	matrix r = matrix_new(a.rows, a.cols)
	r.data[0] = a.data[1] * b.data[2] - a.data[2] * b.data[1]
	r.data[1] = a.data[2] * b.data[0] - a.data[0] * b.data[2]
	r.data[2] = a.data[0] * b.data[1] - a.data[1] * b.data[0]
	return r


# Frobenius norm: sqrt of the sum of squares (norm(A, 'fro'); the
# 2-norm of a vector).
float matrix_norm_fro(matrix* m):
	float sum = 0.0
	for i in range(m.data.length): sum = sum + m.data[i] * m.data[i]
	return fsqrt(sum)


# norm(A, 1): largest absolute column sum.
float matrix_norm1(matrix* m):
	float best = 0.0
	int j = 0
	while (j < m.cols):
		float sum = 0.0
		int i = 0
		while (i < m.rows):
			sum = sum + fabs(m.data[i * m.cols + j])
			i = i + 1
		if (sum > best): best = sum
		j = j + 1
	return best


# norm(A, Inf): largest absolute row sum.
float matrix_norm_inf(matrix* m):
	float best = 0.0
	int i = 0
	while (i < m.rows):
		float sum = 0.0
		int j = 0
		while (j < m.cols):
			sum = sum + fabs(m.data[i * m.cols + j])
			j = j + 1
		if (sum > best): best = sum
		i = i + 1
	return best


##### decompositions (MATLAB: lu, chol, qr, eig, svd, rank, pinv, cond, norm) #####
#
# Output matrices are written through out-pointers, MATLAB's
# [L, U, P] = lu(A) shape: each is freshly allocated (overwriting the
# pointee without freeing it) and owned by the caller.


# Sign with sign(0) == 1, for Householder / Jacobi rotations.
float matrix_sign1(float x):
	if (x < 0.0): return -1.0
	return 1.0


# P * A = L * U with partial pivoting: L unit lower triangular, U upper
# triangular, P a permutation matrix. Returns 1, or 0 when A is
# singular (the factors are still produced; U has a zero pivot).
int matrix_lu(matrix* a, matrix* l, matrix* u, matrix* p):
	asserts(c"matrix_lu: matrix must be square", matrix_is_square(a))
	int n = a.rows
	matrix w = matrix_copy(a)
	matrix lm = matrix_identity(n)
	matrix pm = matrix_identity(n)
	float eps = matrix_singular_eps() * matrix_max_abs(a)
	int ok = 1
	int k = 0
	while (k < n):
		int piv = matrix_pivot_row(&w, k, k)
		if (piv != k):
			matrix_swap_rows(&w, piv, k)
			matrix_swap_rows(&pm, piv, k)
			# swap the already-computed multipliers (columns < k)
			for j in range(k):
				float t = lm.data[k * n + j]
				lm.data[k * n + j] = lm.data[piv * n + j]
				lm.data[piv * n + j] = t
		float pivot = w.data[k * n + k]
		if (fabs(pivot) <= eps): ok = 0
		else:
			int i = k + 1
			while (i < n):
				float f = w.data[i * n + k] / pivot
				lm.data[i * n + k] = f
				for j in range(k, n): w.data[i * n + j] = w.data[i * n + j] - f * w.data[k * n + j]
				w.data[i * n + k] = 0.0
				i = i + 1
		k = k + 1
	*l = lm
	*u = w
	*p = pm
	return ok


# Cholesky: A = R' * R with R upper triangular (MATLAB's chol). Uses
# A's upper triangle. Returns 1, or 0 when A is not positive definite
# (r is then left untouched).
int matrix_chol(matrix* a, matrix* r):
	asserts(c"matrix_chol: matrix must be square", matrix_is_square(a))
	int n = a.rows
	matrix rm = matrix_new(n, n)
	int j = 0
	while (j < n):
		float s = a.data[j * n + j]
		int k = 0
		while (k < j):
			s = s - rm.data[k * n + j] * rm.data[k * n + j]
			k = k + 1
		if (s <= 0.0):
			matrix_free(&rm)
			return 0
		float d = fsqrt(s)
		rm.data[j * n + j] = d
		for i in range(j + 1, n):
			float t = a.data[j * n + i]
			k = 0
			while (k < j):
				t = t - rm.data[k * n + j] * rm.data[k * n + i]
				k = k + 1
			rm.data[j * n + i] = t / d
		j = j + 1
	*r = rm
	return 1


# A = Q * R by Householder reflections: Q is m x m orthogonal, R is
# m x n upper triangular (MATLAB's full qr(A)).
void matrix_qr(matrix* a, matrix* q, matrix* r):
	int m = a.rows
	int n = a.cols
	matrix rm = matrix_copy(a)
	matrix qm = matrix_identity(m)
	float[] v = new float[m]
	int steps = n
	if (m - 1 < steps): steps = m - 1
	for k in range(steps):
		float norm = 0.0
		int i = k
		while (i < m):
			norm = norm + rm.data[i * n + k] * rm.data[i * n + k]
			i = i + 1
		norm = fsqrt(norm)
		if (norm > 0.0):
			float alpha = 0.0 - matrix_sign1(rm.data[k * n + k]) * norm
			float vv = 0.0
			i = k
			while (i < m):
				v[i] = rm.data[i * n + k]
				if (i == k): v[i] = v[i] - alpha
				vv = vv + v[i] * v[i]
				i = i + 1
			if (vv > 0.0):
				# R = H * R, columns k.. (earlier columns are already zero below k)
				for j in range(k, n):
					float s = 0.0
					i = k
					while (i < m):
						s = s + v[i] * rm.data[i * n + j]
						i = i + 1
					float f = 2.0 * s / vv
					i = k
					while (i < m):
						rm.data[i * n + j] = rm.data[i * n + j] - f * v[i]
						i = i + 1
				# Q = Q * H
				int row = 0
				while (row < m):
					float s = 0.0
					i = k
					while (i < m):
						s = s + qm.data[row * m + i] * v[i]
						i = i + 1
					float f = 2.0 * s / vv
					i = k
					while (i < m):
						qm.data[row * m + i] = qm.data[row * m + i] - f * v[i]
						i = i + 1
					row = row + 1
				i = k + 1
				while (i < m):
					rm.data[i * n + k] = 0.0
					i = i + 1
	array_free[float](v)
	*q = qm
	*r = rm


# Swap columns c1 and c2 of m in place.
void matrix_swap_cols(matrix* m, int c1, int c2):
	if (c1 == c2): return
	int i = 0
	while (i < m.rows):
		float t = m.data[i * m.cols + c1]
		m.data[i * m.cols + c1] = m.data[i * m.cols + c2]
		m.data[i * m.cols + c2] = t
		i = i + 1


# Selection-sort the vector vals (and the matching columns of cols)
# ascending, or descending when descending != 0.
void matrix_sort_pairs(matrix* vals, matrix* cols, int descending):
	int n = vals.data.length
	int i = 0
	while (i < n):
		int best = i
		for j in range(i + 1, n):
			if (descending && vals.data[j] > vals.data[best]): best = j
			if ((descending == 0) && vals.data[j] < vals.data[best]): best = j
		if (best != i):
			float t = vals.data[i]
			vals.data[i] = vals.data[best]
			vals.data[best] = t
			matrix_swap_cols(cols, i, best)
		i = i + 1


# One Jacobi rotation parameter t = tan(angle) for zeta = cot(2 angle),
# the smaller-angle root; guards zeta^2 overflow.
float matrix_jacobi_t(float zeta):
	float az = fabs(zeta)
	if (az > 1000000000.0): return 0.5 / zeta
	return matrix_sign1(zeta) / (az + fsqrt(1.0 + zeta * zeta))


# Eigen-decomposition of a SYMMETRIC matrix by cyclic Jacobi rotations:
# A * V = V * diag(values). values is an n x 1 column in ascending order
# (MATLAB's eig order for symmetric input); column i of vectors is the
# unit eigenvector for values[i]. Only the symmetric case is supported
# (asserted within a relative tolerance).
void matrix_eig_sym(matrix* a, matrix* values, matrix* vectors):
	asserts(c"matrix_eig_sym: matrix must be square", matrix_is_square(a))
	int n = a.rows
	matrix t = matrix_transpose(a)
	asserts(c"matrix_eig_sym: matrix must be symmetric", matrix_near(a, &t, 0.00001 * (1.0 + matrix_max_abs(a))))
	matrix_free(&t)
	matrix w = matrix_copy(a)
	matrix v = matrix_identity(n)
	for sweep in range(60):
		float off = 0.0
		int p = 0
		while (p < n):
			for q in range(p + 1, n): off = off + w.data[p * n + q] * w.data[p * n + q]
			p = p + 1
		if (off == 0.0): break
		p = 0
		while (p < n):
			int q = p + 1
			while (q < n):
				float apq = w.data[p * n + q]
				float app = w.data[p * n + p]
				float aqq = w.data[q * n + q]
				float g = 100.0 * fabs(apq)
				if (sweep > 3 && fabs(app) + g == fabs(app) && fabs(aqq) + g == fabs(aqq)):
					w.data[p * n + q] = 0.0
					w.data[q * n + p] = 0.0
				else if (apq != 0.0):
					float tt = matrix_jacobi_t((aqq - app) / (2.0 * apq))
					float c = 1.0 / fsqrt(1.0 + tt * tt)
					float s = tt * c
					int k = 0
					while (k < n):
						float akp = w.data[k * n + p]
						float akq = w.data[k * n + q]
						w.data[k * n + p] = c * akp - s * akq
						w.data[k * n + q] = s * akp + c * akq
						k = k + 1
					k = 0
					while (k < n):
						float apk = w.data[p * n + k]
						float aqk = w.data[q * n + k]
						w.data[p * n + k] = c * apk - s * aqk
						w.data[q * n + k] = s * apk + c * aqk
						k = k + 1
					k = 0
					while (k < n):
						float vkp = v.data[k * n + p]
						float vkq = v.data[k * n + q]
						v.data[k * n + p] = c * vkp - s * vkq
						v.data[k * n + q] = s * vkp + c * vkq
						k = k + 1
				q = q + 1
			p = p + 1
	matrix vals = matrix_diag_of(&w)
	matrix_free(&w)
	matrix_sort_pairs(&vals, &v, 0)
	*values = vals
	*vectors = v


# Singular value decomposition by one-sided (Hestenes) Jacobi, economy
# size: A = U * diag(s) * V' with k = min(rows, cols), U rows x k and V
# cols x k with orthonormal columns, and s a k x 1 column of singular
# values in descending order. Columns of U for zero singular values are
# left zero.
void matrix_svd(matrix* a, matrix* u, matrix* s, matrix* v):
	if (a.rows < a.cols):
		# A' = U1 S V1'  =>  A = V1 S U1'
		matrix at = matrix_transpose(a)
		matrix_svd(&at, v, s, u)
		matrix_free(&at)
		return
	int m = a.rows
	int n = a.cols
	matrix um = matrix_copy(a)
	matrix vm = matrix_identity(n)
	for sweep in range(60):
		int rotated = 0
		int p = 0
		while (p < n):
			int q = p + 1
			while (q < n):
				float alpha = 0.0
				float beta = 0.0
				float gamma = 0.0
				int i = 0
				while (i < m):
					float up = um.data[i * n + p]
					float uq = um.data[i * n + q]
					alpha = alpha + up * up
					beta = beta + uq * uq
					gamma = gamma + up * uq
					i = i + 1
				if (fabs(gamma) > 0.000001 * fsqrt(alpha * beta)):
					rotated = 1
					float t = matrix_jacobi_t((beta - alpha) / (2.0 * gamma))
					float c = 1.0 / fsqrt(1.0 + t * t)
					float sn = t * c
					i = 0
					while (i < m):
						float up = um.data[i * n + p]
						float uq = um.data[i * n + q]
						um.data[i * n + p] = c * up - sn * uq
						um.data[i * n + q] = sn * up + c * uq
						i = i + 1
					i = 0
					while (i < n):
						float vp = vm.data[i * n + p]
						float vq = vm.data[i * n + q]
						vm.data[i * n + p] = c * vp - sn * vq
						vm.data[i * n + q] = sn * vp + c * vq
						i = i + 1
				q = q + 1
			p = p + 1
		if (rotated == 0): break
	matrix sv = matrix_new(n, 1)
	int j = 0
	while (j < n):
		float norm = 0.0
		int i = 0
		while (i < m):
			norm = norm + um.data[i * n + j] * um.data[i * n + j]
			i = i + 1
		norm = fsqrt(norm)
		sv.data[j] = norm
		i = 0
		while (i < m):
			if (norm > 0.0): um.data[i * n + j] = um.data[i * n + j] / norm
			else: um.data[i * n + j] = 0.0
			i = i + 1
		j = j + 1
	# sort descending, permuting U's and V's columns together
	int i = 0
	while (i < n):
		int best = i
		j = i + 1
		while (j < n):
			if (sv.data[j] > sv.data[best]): best = j
			j = j + 1
		if (best != i):
			float t = sv.data[i]
			sv.data[i] = sv.data[best]
			sv.data[best] = t
			matrix_swap_cols(&um, i, best)
			matrix_swap_cols(&vm, i, best)
		i = i + 1
	*u = um
	*s = sv
	*v = vm


# Singular values only, descending, as a column (MATLAB's svd(A)).
matrix matrix_singular_values(matrix* a):
	matrix u
	matrix s
	matrix v
	matrix_svd(a, &u, &s, &v)
	matrix_free(&u)
	matrix_free(&v)
	return s


# Singular values at or below this count as zero for rank/pinv:
# max(rows, cols) * s_max * the float32-scaled singularity threshold.
float matrix_svd_tol(matrix* a, matrix* s):
	int big = a.rows
	if (a.cols > big): big = a.cols
	return big * s.data[0] * matrix_singular_eps() * 10.0


int matrix_rank(matrix* a):
	matrix s = matrix_singular_values(a)
	float tol = matrix_svd_tol(a, &s)
	int r = 0
	int i = 0
	while (i < s.data.length):
		if (s.data[i] > tol): r = r + 1
		i = i + 1
	matrix_free(&s)
	return r


# Largest singular value: norm(A) / norm(A, 2).
float matrix_norm2(matrix* a):
	matrix s = matrix_singular_values(a)
	float r = s.data[0]
	matrix_free(&s)
	return r


# 2-norm condition number s_max / s_min; +inf when A is rank deficient.
float matrix_cond(matrix* a):
	matrix s = matrix_singular_values(a)
	float smin = s.data[s.data.length - 1]
	float r = float_from_bits(0x7f800000)    # +inf
	if (smin > 0.0): r = s.data[0] / smin
	matrix_free(&s)
	return r


# Moore-Penrose pseudoinverse V * diag(1/s) * U', dropping singular
# values below matrix_svd_tol (MATLAB's pinv). cols x rows.
matrix matrix_pinv(matrix* a):
	matrix u
	matrix s
	matrix v
	matrix_svd(a, &u, &s, &v)
	float tol = matrix_svd_tol(a, &s)
	int k = s.data.length
	matrix r = matrix_new(a.cols, a.rows)
	for c in range(k):
		if (s.data[c] > tol):
			float inv = 1.0 / s.data[c]
			int i = 0
			while (i < a.cols):
				float vi = v.data[i * v.cols + c] * inv
				for j in range(a.rows):
					r.data[i * r.cols + j] = r.data[i * r.cols + j] + vi * u.data[j * u.cols + c]
				i = i + 1
	matrix_free(&u)
	matrix_free(&s)
	matrix_free(&v)
	return r


##### output #####


# One row per line, elements space-separated: "[1 2]\n[3 4]\n".
void matrix_print(matrix* m):
	int i = 0
	while (i < m.rows):
		print(c"[")
		int j = 0
		while (j < m.cols):
			if (j > 0): print(c" ")
			char* s = ftoa(m.data[i * m.cols + j])
			print(s)
			free(s)
			j = j + 1
		println(c"]")
		i = i + 1
