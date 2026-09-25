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


struct matrix:
	float[] data   # row-major, length rows * cols
	int rows
	int cols


# Relative singularity threshold for det/inverse/solve pivots, scaled by
# the largest-magnitude entry of the matrix being factored.
float matrix_singular_eps():
	return 0.000001


float matrix_fabs(float f):
	if (f < 0.0):
		return 0.0 - f
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
	int i = 0
	while (i < n):
		m.data[i * n + i] = 1.0
		i = i + 1
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
	int i = 0
	while (i < m.data.length):
		r.data[i] = m.data[i]
		i = i + 1
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
	int j = 0
	while (j < m.cols):
		r.data[j] = m.data[i * m.cols + j]
		j = j + 1
	return r


matrix matrix_col(matrix* m, int j):
	asserts(c"matrix_col: index out of range", j >= 0 && j < m.cols)
	matrix r = matrix_new(m.rows, 1)
	int i = 0
	while (i < m.rows):
		r.data[i] = m.data[i * m.cols + j]
		i = i + 1
	return r


##### in-place (non-allocating) arithmetic #####
#
# out may alias a or b for the elementwise forms (each output element
# depends only on the same-position inputs); matmul_into may not.


void matrix_add_into(matrix* out, matrix* a, matrix* b):
	asserts(c"matrix_add: shape mismatch", matrix_same_shape(a, b) && matrix_same_shape(out, a))
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] + b.data[i]
		i = i + 1


void matrix_sub_into(matrix* out, matrix* a, matrix* b):
	asserts(c"matrix_sub: shape mismatch", matrix_same_shape(a, b) && matrix_same_shape(out, a))
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] - b.data[i]
		i = i + 1


void matrix_scale_into(matrix* out, matrix* a, float s):
	asserts(c"matrix_scale: shape mismatch", matrix_same_shape(out, a))
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] * s
		i = i + 1


# Elementwise (Hadamard) product.
void matrix_hadamard_into(matrix* out, matrix* a, matrix* b):
	asserts(c"matrix_hadamard: shape mismatch", matrix_same_shape(a, b) && matrix_same_shape(out, a))
	int i = 0
	while (i < a.data.length):
		out.data[i] = a.data[i] * b.data[i]
		i = i + 1


# out = a * b (matrix product), a is m x k, b is k x n, out is m x n.
void matrix_matmul_into(matrix* out, matrix* a, matrix* b):
	asserts(c"matrix_mul: inner dimensions must match", a.cols == b.rows)
	asserts(c"matrix_mul: output shape mismatch", out.rows == a.rows && out.cols == b.cols)
	asserts(c"matrix_mul: output must not alias an input", out.data.data != a.data.data && out.data.data != b.data.data)
	int i = 0
	while (i < a.rows):
		int j = 0
		while (j < b.cols):
			float sum = 0.0
			int k = 0
			while (k < a.cols):
				sum = sum + a.data[i * a.cols + k] * b.data[k * b.cols + j]
				k = k + 1
			out.data[i * out.cols + j] = sum
			j = j + 1
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
		int j = 0
		while (j < m.cols):
			r.data[j * r.cols + i] = m.data[i * m.cols + j]
			j = j + 1
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
	int i = 0
	while (i < m.rows):
		sum = sum + m.data[i * m.cols + i]
		i = i + 1
	return sum


float matrix_sum(matrix* m):
	float sum = 0.0
	int i = 0
	while (i < m.data.length):
		sum = sum + m.data[i]
		i = i + 1
	return sum


float matrix_max_abs(matrix* m):
	float best = 0.0
	int i = 0
	while (i < m.data.length):
		float v = matrix_fabs(m.data[i])
		if (v > best):
			best = v
		i = i + 1
	return best


# 1 when every element of a and b differs by at most tol (and the
# shapes match), else 0.
int matrix_near(matrix* a, matrix* b, float tol):
	if (matrix_same_shape(a, b) == 0):
		return 0
	int i = 0
	while (i < a.data.length):
		if (matrix_fabs(a.data[i] - b.data[i]) > tol):
			return 0
		i = i + 1
	return 1


# 1 when the shapes match and every element is exactly equal.
int matrix_equal(matrix* a, matrix* b):
	if (matrix_same_shape(a, b) == 0):
		return 0
	int i = 0
	while (i < a.data.length):
		if (a.data[i] != b.data[i]):
			return 0
		i = i + 1
	return 1


##### elimination: det / inverse / solve #####


# Swap rows r1 and r2 of m in place.
void matrix_swap_rows(matrix* m, int r1, int r2):
	if (r1 == r2):
		return
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
			int j = col
			while (j < n):
				a.data[r * n + j] = a.data[r * n + j] - f * a.data[col * n + j]
				j = j + 1
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
	int i = 0
	while (i < b.data.length):
		out.data[i] = b.data[i]
		i = i + 1
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


##### output #####


# One row per line, elements space-separated: "[1 2]\n[3 4]\n".
void matrix_print(matrix* m):
	int i = 0
	while (i < m.rows):
		print(c"[")
		int j = 0
		while (j < m.cols):
			if (j > 0):
				print(c" ")
			char* s = ftoa(m.data[i * m.cols + j])
			print(s)
			free(s)
			j = j + 1
		println(c"]")
		i = i + 1
