# wbuild: x64
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


############################## shape/stride math ##############################


void test_shape_rank1():
	ndf a = ndf_new1(5)
	assert_equal(1, a.rank)
	assert_equal(5, a.n0)
	assert_equal(1, a.n1)
	assert_equal(1, a.n2)
	assert_equal(1, a.n3)
	assert_equal(1, a.s0)
	assert_equal(1, a.s1)
	assert_equal(1, a.s2)
	assert_equal(1, a.s3)
	assert_equal(5, a.data.length)


void test_shape_rank2():
	ndf a = ndf_new2(2, 3)
	assert_equal(2, a.rank)
	assert_equal(2, a.n0)
	assert_equal(3, a.n1)
	assert_equal(1, a.n2)
	assert_equal(1, a.n3)
	assert_equal(3, a.s0)     # s0 = n1*n2*n3 = 3*1*1
	assert_equal(1, a.s1)     # unused trailing axis: stride 1
	assert_equal(1, a.s2)
	assert_equal(1, a.s3)
	assert_equal(6, a.data.length)


void test_shape_rank3():
	ndf a = ndf_new3(2, 3, 4)
	assert_equal(3, a.rank)
	assert_equal(2, a.n0)
	assert_equal(3, a.n1)
	assert_equal(4, a.n2)
	assert_equal(1, a.n3)
	assert_equal(12, a.s0)    # n1*n2*n3 = 3*4*1
	assert_equal(4, a.s1)     # n2*n3 = 4*1
	assert_equal(1, a.s2)
	assert_equal(1, a.s3)
	assert_equal(24, a.data.length)


void test_shape_rank4():
	ndf a = ndf_new4(2, 3, 4, 5)
	assert_equal(4, a.rank)
	assert_equal(2, a.n0)
	assert_equal(3, a.n1)
	assert_equal(4, a.n2)
	assert_equal(5, a.n3)
	assert_equal(60, a.s0)    # n1*n2*n3 = 3*4*5
	assert_equal(20, a.s1)    # n2*n3 = 4*5
	assert_equal(5, a.s2)     # n3
	assert_equal(1, a.s3)
	assert_equal(120, a.data.length)


# A 1xN and Nx1 array are the doc's own "unused trailing axis" edge
# cases at the opposite ends of rank 2.
void test_shape_edge_singleton_axes():
	ndf row = ndf_new2(1, 7)
	assert_equal(7, row.s0)
	assert_equal(7, row.data.length)

	ndf col = ndf_new2(7, 1)
	assert_equal(1, col.s0)
	assert_equal(7, col.data.length)


################################## constructors #################################


void test_new_is_zero_filled():
	ndf a = ndf_new2(2, 2)
	int i = 0
	while (i < a.data.length):
		assert_feq(0.0, a.data[i])
		i = i + 1


void test_ones_and_full():
	ndf ones = ndf_ones2(2, 2)
	assert_feq(1.0, ndf_at2(&ones, 0, 0))
	assert_feq(1.0, ndf_at2(&ones, 1, 1))

	ndf full = ndf_full3(2, 2, 2, 7.5)
	assert_feq(7.5, ndf_at3(&full, 1, 1, 1))


void test_wrap_shares_buffer():
	float[] buf = new float[6]
	buf[3] = 9.0
	ndf a = ndf_wrap2(buf, 2, 3)
	assert_feq(9.0, ndf_at2(&a, 1, 0))
	# writes through the wrapped ndarray are visible in the source buffer
	ndf_set2(&a, 0, 0, 3.0)
	assert_feq(3.0, buf[0])


################################## get/set round trips ############################


void test_get_set_rank1():
	ndf a = ndf_new1(4)
	ndf_set1(&a, 0, 1.0)
	ndf_set1(&a, 3, 4.0)
	assert_feq(1.0, ndf_at1(&a, 0))
	assert_feq(4.0, ndf_at1(&a, 3))


void test_get_set_rank2():
	ndf a = ndf_new2(2, 3)
	ndf_set2(&a, 0, 2, 6.0)
	ndf_set2(&a, 1, 0, 4.0)
	assert_feq(6.0, ndf_at2(&a, 0, 2))
	assert_feq(4.0, ndf_at2(&a, 1, 0))
	# matches the flat row-major offset directly
	assert_feq(6.0, a.data[2])
	assert_feq(4.0, a.data[3])


void test_get_set_rank3():
	ndf a = ndf_new3(2, 2, 2)
	ndf_set3(&a, 1, 1, 1, 8.0)
	ndf_set3(&a, 0, 1, 0, 3.0)
	assert_feq(8.0, ndf_at3(&a, 1, 1, 1))
	assert_feq(3.0, ndf_at3(&a, 0, 1, 0))


void test_get_set_rank4():
	ndf a = ndf_new4(2, 2, 2, 2)
	ndf_set4(&a, 1, 0, 1, 0, 5.0)
	assert_feq(5.0, ndf_at4(&a, 1, 0, 1, 0))
	assert_feq(0.0, ndf_at4(&a, 0, 0, 0, 0))


void test_get_set_int():
	ndi a = ndi_new2(2, 3)
	ndi_set2(&a, 0, 1, 42)
	assert_equal(42, ndi_at2(&a, 0, 1))
	ndi b = ndi_new1(3)
	ndi_set1(&b, 2, 99)
	assert_equal(99, ndi_at1(&b, 2))


####################################### fill ####################################


void test_fill_overwrites_all_elements():
	ndf a = ndf_ones2(3, 3)
	ndf_fill(&a, 2.0)
	int i = 0
	while (i < a.data.length):
		assert_feq(2.0, a.data[i])
		i = i + 1


####################################### views ####################################


void test_row_aliases_source():
	ndf a = ndf_new2(3, 2)
	ndf_set2(&a, 1, 0, 1.0)
	ndf_set2(&a, 1, 1, 2.0)
	float[] row = ndf_row(&a, 1)
	assert_equal(2, row.length)
	assert_feq(1.0, row[0])
	assert_feq(2.0, row[1])
	row[0] = 42.0
	assert_feq(42.0, ndf_at2(&a, 1, 0))


void test_sub_aliases_source_and_preserves_trailing_shape():
	ndf a = ndf_new3(4, 2, 2)
	ndf_set3(&a, 2, 0, 0, 11.0)
	ndf sub = ndf_sub(&a, 2, 4)
	assert_equal(2, sub.n0)
	assert_equal(2, sub.n1)
	assert_equal(2, sub.n2)
	assert_feq(11.0, ndf_at3(&sub, 0, 0, 0))
	ndf_set3(&sub, 0, 0, 0, 55.0)
	assert_feq(55.0, ndf_at3(&a, 2, 0, 0))


void test_is_contiguous():
	ndf a = ndf_new3(2, 3, 4)
	assert_equal(1, ndf_is_contiguous(&a))
	ndf sub = ndf_sub(&a, 1, 2)
	assert_equal(1, ndf_is_contiguous(&sub))
	# hand-break the invariant to exercise the false branch: v1's public
	# constructors never produce a non-contiguous ndf (general strided
	# views are deferred), so this pokes the fields directly.
	a.s0 = a.s0 + 1
	assert_equal(0, ndf_is_contiguous(&a))


################################## elementwise ops ################################


void test_add_and_mul_into():
	ndf a = ndf_full2(2, 2, 2.0)
	ndf b = ndf_full2(2, 2, 3.0)
	ndf out = ndf_new2(2, 2)
	ndf_add_into(&out, &a, &b)
	assert_feq(5.0, ndf_at2(&out, 0, 0))
	assert_feq(5.0, ndf_at2(&out, 1, 1))

	ndf_mul_into(&out, &a, &b)
	assert_feq(6.0, ndf_at2(&out, 0, 0))


void test_scalar_ops():
	ndf a = ndf_full2(2, 2, 4.0)
	ndf out = ndf_new2(2, 2)
	ndf_add_scalar_into(&out, &a, 1.5)
	assert_feq(5.5, ndf_at2(&out, 0, 0))
	ndf_mul_scalar_into(&out, &a, 2.0)
	assert_feq(8.0, ndf_at2(&out, 1, 1))


# out aliasing a (in-place) must not corrupt already-written elements:
# every op reads a.data[i]/b.data[i] before writing out.data[i] at the
# same flat index, so self-aliasing is safe by construction.
void test_in_place_alias():
	ndf a = ndf_full2(2, 2, 3.0)
	ndf_add_scalar_into(&a, &a, 1.0)
	assert_feq(4.0, ndf_at2(&a, 0, 0))
	assert_feq(4.0, ndf_at2(&a, 1, 1))


float double_float(float x):
	return x * 2.0


void test_map():
	ndf a = ndf_new1(3)
	a.data[0] = 1.0
	a.data[1] = 2.0
	a.data[2] = 3.0
	ndf out = ndf_new1(3)
	ndf_map(&out, &a, double_float)
	assert_feq(2.0, ndf_at1(&out, 0))
	assert_feq(4.0, ndf_at1(&out, 1))
	assert_feq(6.0, ndf_at1(&out, 2))
	# in-place map: a is still the untouched original [1, 2, 3]
	ndf_map(&a, &a, double_float)
	assert_feq(2.0, ndf_at1(&a, 0))
	assert_feq(4.0, ndf_at1(&a, 1))
	assert_feq(6.0, ndf_at1(&a, 2))


###################################### matmul ####################################


# Hand-computed 2x3 . 3x2 fixture:
#   a = [[1, 2, 3],      b = [[ 7,  8],
#        [4, 5, 6]]           [ 9, 10],
#                              [11, 12]]
#   a @ b = [[1*7+2*9+3*11,  1*8+2*10+3*12],   = [[ 58,  64],
#            [4*7+5*9+6*11,  4*8+5*10+6*12]]      [139, 154]]
void test_matmul2_2x3_3x2():
	ndf a = ndf_new2(2, 3)
	ndf b = ndf_new2(3, 2)
	ndf out = ndf_new2(2, 2)
	ndf_set2(&a, 0, 0, 1.0)
	ndf_set2(&a, 0, 1, 2.0)
	ndf_set2(&a, 0, 2, 3.0)
	ndf_set2(&a, 1, 0, 4.0)
	ndf_set2(&a, 1, 1, 5.0)
	ndf_set2(&a, 1, 2, 6.0)
	ndf_set2(&b, 0, 0, 7.0)
	ndf_set2(&b, 0, 1, 8.0)
	ndf_set2(&b, 1, 0, 9.0)
	ndf_set2(&b, 1, 1, 10.0)
	ndf_set2(&b, 2, 0, 11.0)
	ndf_set2(&b, 2, 1, 12.0)
	ndf_matmul2(&out, &a, &b)
	assert_feq(58.0, ndf_at2(&out, 0, 0))
	assert_feq(64.0, ndf_at2(&out, 0, 1))
	assert_feq(139.0, ndf_at2(&out, 1, 0))
	assert_feq(154.0, ndf_at2(&out, 1, 1))


##################################### ndi views ###################################


void test_ndi_row_and_sub():
	ndi a = ndi_new2(3, 2)
	ndi_set2(&a, 1, 0, 5)
	ndi_set2(&a, 1, 1, 6)
	int[] row = ndi_row(&a, 1)
	assert_equal(5, row[0])
	assert_equal(6, row[1])
	row[0] = 50
	assert_equal(50, ndi_at2(&a, 1, 0))

	ndi sub = ndi_sub(&a, 1, 3)
	assert_equal(2, sub.n0)
	assert_equal(1, ndi_is_contiguous(&sub))


void test_ndi_ones_full_wrap():
	ndi ones = ndi_ones1(3)
	assert_equal(1, ndi_at1(&ones, 2))
	ndi full = ndi_full2(2, 2, 9)
	assert_equal(9, ndi_at2(&full, 1, 1))
	int[] buf = new int[3]
	buf[1] = 7
	ndi wrapped = ndi_wrap1(buf, 3)
	assert_equal(7, ndi_at1(&wrapped, 1))
