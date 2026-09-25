# wbuild: x64
import lib.testing
import lib.format
import lib.matrix

/*
lib/matrix.w's MATLAB-parity surface: construction helpers (rand,
randn, linspace, diag, reshape, block/hcat/vcat, repmat, triu/tril,
kron), elementwise ops (./, .^, abs/sqrt/exp/log, map, scalar
operators), reductions along a dimension and norms, and the
decompositions (lu, chol, qr, symmetric eig, svd) checked by
reconstruction, plus rank, pinv, cond and norm2.
*/


float ml_abs(float f):
	if (f < 0.0):
		return 0.0 - f
	return f


void assert_near_tol(float want, float got, float tol):
	if (ml_abs(want - got) > tol):
		print2(c"Assertion failed. wanted float(")
		print2(ftoa(want))
		print2(c") got float(")
		print2(ftoa(got))
		println2(c")")
		print_stack_trace()
		exit(1)


void assert_matrix_near_tol(matrix* want, matrix* got, float tol):
	if (matrix_near(want, got, tol) == 0):
		println2(c"Assertion failed: matrices differ; wanted")
		matrix_print(want)
		println2(c"got")
		matrix_print(got)
		print_stack_trace()
		exit(1)


void assert_matrix_near(matrix* want, matrix* got):
	assert_matrix_near_tol(want, got, 0.0001)


# q' * q == I
void assert_orthonormal_cols(matrix* q):
	matrix qt = q.transpose()
	matrix g = qt * *q
	matrix id = matrix_identity(q.cols)
	assert_matrix_near_tol(&id, &g, 0.001)


float twice(float x):
	return x * 2.0


matrix sym3():
	return matrix_from3(4.0, 1.0, 2.0, 1.0, 3.0, 0.0, 2.0, 0.0, 5.0)


############################## construction ##############################


void test_rand():
	rand_state r
	rand_init(&r, 42)
	matrix u = matrix_rand(20, 10, &r)
	assert_equal(1, matrix_min(&u) >= 0.0)
	assert_equal(1, matrix_max(&u) < 1.0)
	rand_state r2
	rand_init(&r2, 42)
	matrix u2 = matrix_rand(20, 10, &r2)
	assert_equal(1, matrix_equal(&u, &u2))   # same seed, same draw
	matrix g = matrix_randn(50, 40, &r)
	assert_near_tol(0.0, matrix_mean(&g), 0.1)


void test_linspace_diag_reshape():
	matrix l = matrix_linspace(0.0, 1.0, 5)
	assert_equal(1, l.rows)
	assert_equal(5, l.cols)
	assert_near(0.25, l[0, 1])
	assert_near(1.0, l[0, 4])
	matrix d = matrix_diag(&l)
	assert_equal(5, d.rows)
	assert_near(0.75, d[3, 3])
	assert_near(0.0, d[3, 2])
	matrix back = matrix_diag_of(&d)
	assert_equal(5, back.rows)
	assert_equal(1, back.cols)
	assert_near(0.5, back[2, 0])
	matrix a = matrix_from3(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0)
	matrix r = matrix_block(&a, 0, 2, 0, 3)
	matrix r2 = matrix_reshape(&r, 3, 2)
	assert_near(3.0, r2[1, 0])
	assert_near(6.0, r2[2, 1])


void test_blocks():
	matrix a = matrix_from3(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0)
	matrix b = matrix_block(&a, 1, 3, 1, 3)
	matrix want_b = matrix_from2(5.0, 6.0, 8.0, 9.0)
	assert_matrix_near(&want_b, &b)
	matrix id = matrix_identity(2)
	matrix h = matrix_hcat(&b, &id)
	assert_equal(2, h.rows)
	assert_equal(4, h.cols)
	assert_near(1.0, h[1, 3])
	assert_near(9.0, h[1, 1])
	matrix v = matrix_vcat(&b, &id)
	assert_equal(4, v.rows)
	assert_near(8.0, v[1, 0])
	assert_near(1.0, v[2, 0])
	matrix rp = matrix_repmat(&id, 2, 3)
	assert_equal(4, rp.rows)
	assert_equal(6, rp.cols)
	assert_near(1.0, rp[3, 5])
	assert_near(0.0, rp[3, 4])
	matrix up = matrix_triu(&a, 0)
	matrix want_up = matrix_from3(1.0, 2.0, 3.0, 0.0, 5.0, 6.0, 0.0, 0.0, 9.0)
	assert_matrix_near(&want_up, &up)
	matrix lo = matrix_tril(&a, -1)
	matrix want_lo = matrix_from3(0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 7.0, 8.0, 0.0)
	assert_matrix_near(&want_lo, &lo)
	matrix k = matrix_kron(&id, &b)
	assert_equal(4, k.rows)
	assert_near(9.0, k[3, 3])
	assert_near(0.0, k[0, 3])
	assert_near(6.0, k[0, 1])
	matrix_set_block(&a, 1, 1, &id)
	assert_near(1.0, a[1, 1])
	assert_near(0.0, a[1, 2])


############################## elementwise ##############################


void test_elementwise():
	matrix a = matrix_from2(1.0, 4.0, 9.0, 16.0)
	matrix s = matrix_sqrt(&a)
	matrix want_s = matrix_from2(1.0, 2.0, 3.0, 4.0)
	assert_matrix_near(&want_s, &s)
	matrix q = matrix_ediv(&a, &s)
	assert_matrix_near(&want_s, &q)
	matrix p = matrix_epow(&s, 2.0)
	assert_matrix_near(&a, &p)
	matrix n = matrix_neg(&s)
	matrix ab = matrix_abs(&n)
	assert_matrix_near(&s, &ab)
	matrix t = matrix_map(&s, twice)
	assert_near(8.0, t[1, 1])
	matrix e = matrix_exp(&s)
	matrix lg = matrix_log(&e)
	assert_matrix_near_tol(&s, &lg, 0.001)
	matrix plus = s + 1.0
	matrix plus2 = 1.0 + s
	matrix want_plus = matrix_from2(2.0, 3.0, 4.0, 5.0)
	assert_matrix_near(&want_plus, &plus)
	assert_matrix_near(&want_plus, &plus2)
	matrix minus = plus - 1.0
	assert_matrix_near(&s, &minus)
	matrix rminus = 5.0 - s
	matrix want_rminus = matrix_from2(4.0, 3.0, 2.0, 1.0)
	assert_matrix_near(&want_rminus, &rminus)


############################## reductions ##############################


void test_reductions():
	matrix a = matrix_from3(1.0, -2.0, 3.0, 4.0, 5.0, -6.0, 7.0, 8.0, 9.0)
	matrix cs = matrix_sum_dim(&a, 1)
	assert_equal(1, cs.rows)
	assert_near(12.0, cs[0, 0])
	assert_near(11.0, cs[0, 1])
	matrix rs = matrix_sum_dim(&a, 2)
	assert_equal(3, rs.rows)
	assert_near(3.0, rs[1, 0])
	matrix cm = matrix_mean_dim(&a, 1)
	assert_near(4.0, cm[0, 0])
	assert_near(29.0 / 9.0, matrix_mean(&a))
	assert_near(-6.0, matrix_min(&a))
	assert_near(9.0, matrix_max(&a))
	assert_equal(5, matrix_argmin(&a))
	assert_equal(8, matrix_argmax(&a))
	assert_near(18.0, matrix_norm1(&a))
	assert_near(24.0, matrix_norm_inf(&a))
	matrix v = matrix_from(matrix_linspace(3.0, 4.0, 2).data, 2, 1)
	assert_near(5.0, matrix_norm_fro(&v))
	matrix x = matrix_block(&a, 0, 1, 0, 3)
	matrix y = matrix_block(&a, 1, 2, 0, 3)
	assert_near(-24.0, matrix_dot(&x, &y))
	matrix c = matrix_cross(&x, &y)
	matrix want_c = matrix_from(matrix_linspace(-3.0, -3.0, 3).data, 1, 3)
	want_c[0, 1] = 18.0
	want_c[0, 2] = 13.0
	assert_matrix_near(&want_c, &c)
	assert_near(0.0, matrix_dot(&c, &x))


############################## decompositions ##############################


void test_lu():
	matrix a = matrix_from3(0.0, 2.0, 1.0, 1.0, 1.0, 0.0, 3.0, 0.0, 1.0)
	matrix l
	matrix u
	matrix p
	assert_equal(1, matrix_lu(&a, &l, &u, &p))
	matrix pa = p * a
	matrix lu = l * u
	assert_matrix_near(&pa, &lu)
	matrix lower = matrix_tril(&l, 0)
	assert_matrix_near(&lower, &l)
	matrix upper = matrix_triu(&u, 0)
	assert_matrix_near(&upper, &u)
	assert_near(1.0, l[1, 1])
	matrix sing = matrix_from2(1.0, 2.0, 2.0, 4.0)
	matrix l2
	matrix u2
	matrix p2
	assert_equal(0, matrix_lu(&sing, &l2, &u2, &p2))


void test_chol():
	matrix a = sym3()
	matrix r
	assert_equal(1, matrix_chol(&a, &r))
	matrix rt = r.transpose()
	matrix back = rt * r
	assert_matrix_near(&a, &back)
	assert_near(0.0, r[1, 0])
	matrix indef = matrix_from2(1.0, 2.0, 2.0, 1.0)
	matrix r2
	assert_equal(0, matrix_chol(&indef, &r2))


void test_qr():
	float[] vals = new float[12]
	int i = 0
	while (i < 12):
		vals[i] = (i * 7) % 5 + i / 3
		i = i + 1
	matrix a = matrix_from(vals, 4, 3)
	matrix q
	matrix r
	matrix_qr(&a, &q, &r)
	assert_equal(4, q.rows)
	assert_equal(4, q.cols)
	assert_equal(4, r.rows)
	assert_equal(3, r.cols)
	assert_orthonormal_cols(&q)
	matrix upper = matrix_triu(&r, 0)
	assert_matrix_near(&upper, &r)
	matrix back = q * r
	assert_matrix_near_tol(&a, &back, 0.001)


void test_eig_sym():
	matrix a = sym3()
	matrix vals
	matrix vecs
	matrix_eig_sym(&a, &vals, &vecs)
	assert_equal(3, vals.rows)
	assert_equal(1, vals.cols)
	# ascending, trace preserved
	assert_equal(1, vals[0, 0] <= vals[1, 0] && vals[1, 0] <= vals[2, 0])
	assert_near_tol(12.0, matrix_sum(&vals), 0.001)
	assert_orthonormal_cols(&vecs)
	# A * V == V * diag(vals)
	matrix av = a * vecs
	matrix d = matrix_diag(&vals)
	matrix vd = vecs * d
	assert_matrix_near_tol(&av, &vd, 0.001)
	# a diagonal matrix's eigenvalues are its diagonal, sorted
	matrix dm = matrix_from3(3.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 2.0)
	matrix dv
	matrix dvec
	matrix_eig_sym(&dm, &dv, &dvec)
	assert_near(-1.0, dv[0, 0])
	assert_near(2.0, dv[1, 0])
	assert_near(3.0, dv[2, 0])


void test_svd():
	matrix a = matrix_from(matrix_linspace(1.0, 6.0, 6).data, 3, 2)
	matrix u
	matrix s
	matrix v
	matrix_svd(&a, &u, &s, &v)
	assert_equal(3, u.rows)
	assert_equal(2, u.cols)
	assert_equal(2, s.rows)
	assert_equal(2, v.rows)
	assert_equal(1, s[0, 0] >= s[1, 0])
	assert_orthonormal_cols(&u)
	assert_orthonormal_cols(&v)
	matrix sd = matrix_diag(&s)
	matrix us = u * sd
	matrix vt = v.transpose()
	matrix back = us * vt
	assert_matrix_near_tol(&a, &back, 0.001)
	# known values for [[1 2]; [3 4]; [5 6]]
	assert_near_tol(9.5255, s[0, 0], 0.001)
	assert_near_tol(0.5143, s[1, 0], 0.001)
	# wide input goes through the transpose path
	matrix w = a.transpose()
	matrix ws = matrix_singular_values(&w)
	assert_matrix_near_tol(&s, &ws, 0.001)
	matrix wu
	matrix wsv
	matrix wv
	matrix_svd(&w, &wu, &wsv, &wv)
	assert_equal(2, wu.rows)
	assert_equal(3, wv.rows)
	matrix wsd = matrix_diag(&wsv)
	matrix wus = wu * wsd
	matrix wvt = wv.transpose()
	matrix wback = wus * wvt
	assert_matrix_near_tol(&w, &wback, 0.001)


void test_rank_pinv_cond():
	matrix full = sym3()
	assert_equal(3, matrix_rank(&full))
	matrix r2 = matrix_from3(1.0, 2.0, 3.0, 2.0, 4.0, 6.0, 1.0, 0.0, 1.0)
	assert_equal(2, matrix_rank(&r2))
	matrix r1 = matrix_from2(1.0, 2.0, 2.0, 4.0)
	assert_equal(1, matrix_rank(&r1))
	# pinv of an invertible matrix is its inverse
	matrix a = matrix_from2(4.0, 7.0, 2.0, 6.0)
	matrix pa = matrix_pinv(&a)
	matrix ia = matrix_inverse(&a)
	assert_matrix_near_tol(&ia, &pa, 0.001)
	# tall full-column-rank: pinv(A) * A == I
	matrix t = matrix_from(matrix_linspace(1.0, 6.0, 6).data, 3, 2)
	matrix pt = matrix_pinv(&t)
	assert_equal(2, pt.rows)
	assert_equal(3, pt.cols)
	matrix g = pt * t
	matrix id = matrix_identity(2)
	assert_matrix_near_tol(&id, &g, 0.001)
	# rank-deficient: A * pinv(A) * A == A
	matrix p1 = matrix_pinv(&r1)
	matrix ap = r1 * p1
	matrix apa = ap * r1
	assert_matrix_near_tol(&r1, &apa, 0.001)
	matrix id3 = matrix_identity(3)
	assert_near(1.0, matrix_cond(&id3))
	assert_near_tol(9.5255 / 0.5143, matrix_cond(&t), 0.01)
	assert_near_tol(9.5255, matrix_norm2(&t), 0.001)
	assert_equal(1, matrix_cond(&r1) > 1000000.0)
