# wbuild: x64
import lib.testing
import lib.format
import lib.matrix

/*
lib/matrix.w (issue #27): construction, bounds-checked access through
functions, methods and the m[i, j] comma-index sugar, the operator
overloads (+, -, matrix product, both scalar orders, /), transpose,
trace, pow, determinant, inverse, multi-column solve, singular
detection, and zero-copy ndarray interop.
*/


float mt_abs(float f):
	if (f < 0.0):
		return 0.0 - f
	return f


void assert_matrix_near(matrix* want, matrix* got):
	if (matrix_near(want, got, 0.0001) == 0):
		println2(c"Assertion failed: matrices differ; wanted")
		matrix_print(want)
		println2(c"got")
		matrix_print(got)
		print_stack_trace()
		exit(1)


void test_construction():
	matrix z = matrix_new(2, 3)
	assert_equal(2, z.rows)
	assert_equal(3, z.cols)
	assert_equal(6, z.data.length)
	assert_near(0.0, matrix_sum(&z))
	matrix f = matrix_full(2, 2, 2.5)
	assert_near(10.0, f.sum())
	matrix i = matrix_identity(3)
	assert_near(1.0, i.at(0, 0))
	assert_near(0.0, i.at(0, 1))
	assert_near(3.0, i.trace())
	float[] vals = new float[4]
	vals[0] = 1.0
	vals[1] = 2.0
	vals[2] = 3.0
	vals[3] = 4.0
	matrix m = matrix_from(vals, 2, 2)
	vals[0] = 99.0   # matrix_from copies
	assert_near(1.0, m.at(0, 0))
	assert_near(4.0, m.at(1, 1))
	matrix c = matrix_column(vals)
	assert_equal(4, c.rows)
	assert_equal(1, c.cols)
	matrix_free(&z)
	matrix_free(&f)
	matrix_free(&i)
	matrix_free(&m)
	matrix_free(&c)


void test_index_sugar():
	matrix m = matrix_new(2, 3)
	m[0, 1] = 5.0
	m[1, 2] = 7.0
	m[1, 2] += 1.0
	assert_near(5.0, m[0, 1])
	assert_near(8.0, m[1, 2])
	assert_near(8.0, matrix_at(&m, 1, 2))
	matrix* p = &m
	p[1, 0] = 3.0
	assert_near(3.0, m.at(1, 0))
	m.set(0, 0, 9.0)
	assert_near(9.0, m[0, 0])
	matrix_free(&m)


void test_operators():
	matrix a = matrix_from2(1.0, 2.0, 3.0, 4.0)
	matrix b = matrix_from2(5.0, 6.0, 7.0, 8.0)
	matrix s = a + b
	matrix want_s = matrix_from2(6.0, 8.0, 10.0, 12.0)
	assert_matrix_near(&want_s, &s)
	matrix d = b - a
	matrix want_d = matrix_full(2, 2, 4.0)
	assert_matrix_near(&want_d, &d)
	matrix p = a * b
	matrix want_p = matrix_from2(19.0, 22.0, 43.0, 50.0)
	assert_matrix_near(&want_p, &p)
	matrix k = a * 2.0
	matrix k2 = 2.0 * a
	matrix want_k = matrix_from2(2.0, 4.0, 6.0, 8.0)
	assert_matrix_near(&want_k, &k)
	assert_matrix_near(&want_k, &k2)
	matrix h = k / 2.0
	assert_matrix_near(&a, &h)
	# precedence: * binds tighter than +
	matrix e = a + a * b
	matrix want_e = matrix_from2(20.0, 24.0, 46.0, 54.0)
	assert_matrix_near(&want_e, &e)
	matrix hd = matrix_hadamard(&a, &b)
	matrix want_hd = matrix_from2(5.0, 12.0, 21.0, 32.0)
	assert_matrix_near(&want_hd, &hd)


void test_rectangular_product():
	# (2x3) * (3x2) -> 2x2, and the transpose shape swap.
	float[] av = new float[6]
	int i = 0
	while (i < 6):
		av[i] = i + 1
		i = i + 1
	matrix a = matrix_from(av, 2, 3)
	matrix t = a.transpose()
	assert_equal(3, t.rows)
	assert_equal(2, t.cols)
	assert_near(4.0, t[0, 1])
	assert_near(3.0, t[2, 0])
	matrix g = a * t
	matrix want = matrix_from2(14.0, 32.0, 32.0, 77.0)
	assert_matrix_near(&want, &g)
	matrix r = a.row(1)
	assert_equal(1, r.rows)
	assert_near(6.0, r[0, 2])
	matrix c = a.col(2)
	assert_equal(2, c.rows)
	assert_near(6.0, c[1, 0])


void test_pow():
	# Fibonacci: [[1,1],[1,0]]^10 = [[F11, F10], [F10, F9]]
	matrix f = matrix_from2(1.0, 1.0, 1.0, 0.0)
	matrix f10 = f.pow(10)
	matrix want = matrix_from2(89.0, 55.0, 55.0, 34.0)
	assert_matrix_near(&want, &f10)
	matrix f0 = f.pow(0)
	matrix id = matrix_identity(2)
	assert_matrix_near(&id, &f0)


void test_det():
	matrix a = matrix_from2(4.0, 7.0, 2.0, 6.0)
	assert_near(10.0, a.det())
	matrix b = matrix_from3(2.0, 0.0, 1.0, 1.0, 3.0, 2.0, 1.0, 1.0, 2.0)
	assert_near(6.0, b.det())
	# needs a row swap: zero in the first pivot position
	matrix c = matrix_from3(0.0, 2.0, 1.0, 1.0, 1.0, 0.0, 3.0, 0.0, 1.0)
	assert_near(-5.0, c.det())
	matrix sing = matrix_from2(1.0, 2.0, 2.0, 4.0)
	assert_near(0.0, sing.det())
	matrix id = matrix_identity(4)
	assert_near(1.0, id.det())


void test_inverse():
	matrix a = matrix_from2(4.0, 7.0, 2.0, 6.0)
	matrix inv = a.inverse()
	matrix want = matrix_from2(0.6, -0.7, -0.2, 0.4)
	assert_matrix_near(&want, &inv)
	matrix prod = a * inv
	matrix id = matrix_identity(2)
	assert_matrix_near(&id, &prod)
	matrix c = matrix_from3(0.0, 2.0, 1.0, 1.0, 1.0, 0.0, 3.0, 0.0, 1.0)
	matrix ci = c.inverse()
	matrix cp = ci * c
	matrix id3 = matrix_identity(3)
	assert_matrix_near(&id3, &cp)
	# singular: the non-allocating form reports failure instead of asserting
	matrix sing = matrix_from2(1.0, 2.0, 2.0, 4.0)
	matrix out = matrix_new(2, 2)
	assert_equal(0, matrix_inverse_into(&out, &sing))
	assert_equal(1, matrix_inverse_into(&out, &a))
	assert_matrix_near(&want, &out)


void test_solve():
	# 2x + y - z = 8, -3x - y + 2z = -11, -2x + y + 2z = -3 -> (2, 3, -1)
	matrix a = matrix_from3(2.0, 1.0, -1.0, -3.0, -1.0, 2.0, -2.0, 1.0, 2.0)
	float[] bv = new float[3]
	bv[0] = 8.0
	bv[1] = -11.0
	bv[2] = -3.0
	matrix b = matrix_column(bv)
	matrix x = matrix_solve(&a, &b)
	assert_near(2.0, x[0, 0])
	assert_near(3.0, x[1, 0])
	assert_near(-1.0, x[2, 0])
	# the solution checks out: a * x == b
	matrix ax = a * x
	assert_matrix_near(&b, &ax)
	# several right-hand sides at once: solving against a itself gives I
	matrix self = matrix_solve(&a, &a)
	matrix id = matrix_identity(3)
	assert_matrix_near(&id, &self)


void test_ndf_interop():
	matrix m = matrix_from2(1.0, 2.0, 3.0, 4.0)
	ndf v = matrix_as_ndf(&m)
	assert_equal(2, v.rank)
	assert_near(3.0, ndf_at2(&v, 1, 0))
	ndf_set2(&v, 0, 1, 20.0)   # shared storage
	assert_near(20.0, m[0, 1])
	assert_near(28.0, ndf_sum(&v))
	matrix c = matrix_from_ndf(&v)
	c[0, 0] = 100.0            # an owning copy
	assert_near(1.0, m[0, 0])
	assert_equal(1, matrix_equal(&m, &m))
	assert_equal(0, matrix_equal(&m, &c))
	matrix_free(&m)
	matrix_free(&c)
	assert_equal(0, m.rows)
