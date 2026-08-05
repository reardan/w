# wbuild: x64
# ndarray comma-index sugar m[i, j] (grammar/ndarray_index.w,
# docs/projects/ndarray.md Stage 5): every access is asserted against
# the explicit lib/ndarray.w accessor it lowers to, so the sugar and
# the spelled-out ndX_atN/ndX_setN calls stay interchangeable.
import lib.testing
import lib.format
import lib.ndarray


void assert_feq(float want, float got):
	if (want != got):
		print2(c"Assertion failed: wanted float ")
		print2(ftoa(want))
		print2(c" got ")
		println2(ftoa(got))
		print_stack_trace()
		exit(1)


########################### ndf: read/write round-trips ###########################


void test_ndf_rank2_round_trip():
	ndf a = ndf_new2(3, 4)
	ndf* m = &a
	m[1, 2] = 5.5
	assert_feq(5.5, ndf_at2(m, 1, 2))
	ndf_set2(m, 2, 3, 7.25)
	assert_feq(7.25, m[2, 3])
	# struct lvalue receiver, no explicit pointer
	a[0, 1] = 1.5
	assert_feq(1.5, a[0, 1])
	assert_feq(1.5, ndf_at2(&a, 0, 1))


void test_ndf_rank3_rank4():
	ndf b = ndf_new3(2, 3, 4)
	b[1, 2, 3] = 9.0
	assert_feq(9.0, ndf_at3(&b, 1, 2, 3))
	ndf_set3(&b, 0, 1, 2, 3.5)
	assert_feq(3.5, b[0, 1, 2])

	ndf c = ndf_new4(2, 2, 2, 2)
	c[1, 0, 1, 0] = 4.0
	assert_feq(4.0, ndf_at4(&c, 1, 0, 1, 0))
	ndf_set4(&c, 0, 1, 0, 1, 6.5)
	assert_feq(6.5, c[0, 1, 0, 1])


void test_ndf_compound_assign():
	ndf a = ndf_new2(2, 2)
	ndf* m = &a
	m[1, 1] = 5.5
	m[1, 1] += 0.5
	assert_feq(6.0, ndf_at2(m, 1, 1))
	m[1, 1] -= 2.0
	assert_feq(4.0, m[1, 1])
	m[1, 1] *= 2.0
	assert_feq(8.0, m[1, 1])
	m[1, 1] /= 4.0
	assert_feq(2.0, m[1, 1])


############################### ndi round-trips ###############################


void test_ndi_round_trip():
	ndi a = ndi_new2(2, 2)
	a[0, 1] = 42
	assert_equal(42, ndi_at2(&a, 0, 1))
	ndi_set2(&a, 1, 0, 7)
	assert_equal(7, a[1, 0])

	ndi b = ndi_new3(2, 2, 2)
	b[1, 0, 1] = 11
	assert_equal(11, ndi_at3(&b, 1, 0, 1))

	ndi c = ndi_new4(2, 2, 2, 2)
	c[0, 1, 1, 0] = 13
	assert_equal(13, ndi_at4(&c, 0, 1, 1, 0))


void test_ndi_compound_assign():
	ndi a = ndi_new2(2, 2)
	a[0, 1] = 40
	a[0, 1] += 5
	assert_equal(45, ndi_at2(&a, 0, 1))
	a[0, 1] -= 3
	assert_equal(42, a[0, 1])


########################## expression positions ##########################


float half(float x):
	return x / 2.0


void test_read_positions():
	ndf a = ndf_new2(3, 4)
	ndf* m = &a
	m[2, 3] = 7.25
	m[1, 2] = 6.0
	# condition, call argument, arithmetic operand
	if (m[2, 3] > 7.0):
		assert_feq(3.625, half(m[2, 3]))
	else:
		assert1(0)
	float sum = m[1, 2] + m[2, 3] * 2.0
	assert_feq(20.5, sum)
	# chained assignment yields the stored value, like plain '='
	float y = 0.0
	y = m[0, 0] = 2.5
	assert_feq(2.5, y)
	assert_feq(2.5, ndf_at2(m, 0, 0))


void test_nested_indices():
	ndf a = ndf_new2(3, 4)
	ndi idx = ndi_new2(2, 2)
	idx[0, 0] = 1
	idx[1, 1] = 2
	# an ndarray index nested inside another ndarray index list
	a[idx[0, 0], idx[1, 1]] = 8.5
	assert_feq(8.5, ndf_at2(&a, 1, 2))
	assert_feq(8.5, a[idx[0, 0], idx[1, 1]])


void test_view_receivers():
	ndf a = ndf_new2(3, 4)
	# an ndf value returned by a call is a valid receiver (a view over
	# a's buffer), read and write
	ndf sub = ndf_sub(&a, 1, 3)
	sub[0, 2] = 11.0
	assert_feq(11.0, ndf_at2(&a, 1, 2))
	assert_feq(11.0, ndf_sub(&a, 1, 3)[0, 2])


void test_single_index_unchanged():
	# a single index on an ndX* keeps its raw pointer-indexing meaning
	# (the struct at that offset), exactly as before the sugar
	ndi a = ndi_new2(5, 2)
	ndi* q = &a
	assert_equal(5, q[0].n0)
	# and plain slice/element indexing is untouched
	int[] buf = new int[3]
	buf[1] = 21
	assert_equal(21, buf[1])
