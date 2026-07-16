# float64 twin of lib/ndarray_test.w's coverage, following
# tests/x64_fmath64_test.w's house style: a plain main() with manual
# assertions instead of lib.testing's test-registry discovery, which
# doesn't work on the x64 backend yet. x64-only (docs/projects/ndarray.md
# stage 2: lib/ndarray64.w has no wbuildgen directive of its own, so this
# target is hand-written in build.base.json, modeled on x64_fmath64_test).
import lib.lib
import lib.assert
import lib.ndarray64


void assert_f64eq(float64 want, float64 got):
	if (want != got):
		char* p_want = &want
		char* p_got = &got
		print2(c"Assertion failed: wanted float64 bits ")
		print2(hex(load_int32(p_want + 4)))
		print2(hex(load_int32(p_want)))
		print2(c" got ")
		print2(hex(load_int32(p_got + 4)))
		println2(hex(load_int32(p_got)))
		print_stack_trace()
		exit(1)


void test_shape():
	ndf64 a = ndf64_new2(2, 3)
	assert_equal(2, a.rank)
	assert_equal(2, a.n0)
	assert_equal(3, a.n1)
	assert_equal(1, a.n2)
	assert_equal(1, a.n3)
	assert_equal(3, a.s0)
	assert_equal(1, a.s1)
	assert_equal(1, a.s2)
	assert_equal(1, a.s3)
	assert_equal(6, a.data.length)
	assert_equal(1, ndf64_is_contiguous(&a))

	ndf64 b = ndf64_new4(2, 3, 4, 5)
	assert_equal(60, b.s0)
	assert_equal(20, b.s1)
	assert_equal(5, b.s2)
	assert_equal(1, b.s3)
	assert_equal(120, b.data.length)


void test_construction_variants():
	ndf64 zero = ndf64_new2(2, 2)
	assert_f64eq(0.0, zero.data[0])

	ndf64 ones = ndf64_ones2(2, 2)
	assert_f64eq(1.0, ndf64_at2(&ones, 1, 1))

	ndf64 full = ndf64_full2(2, 2, 3.5)
	assert_f64eq(3.5, ndf64_at2(&full, 0, 1))

	float64[] buf = new float64[4]
	buf[2] = 9.5
	ndf64 wrapped = ndf64_wrap2(buf, 2, 2)
	assert_f64eq(9.5, ndf64_at2(&wrapped, 1, 0))
	ndf64_set2(&wrapped, 0, 0, 1.25)
	assert_f64eq(1.25, buf[0])


void test_get_set_and_fill():
	ndf64 a = ndf64_new3(2, 2, 2)
	ndf64_set3(&a, 1, 0, 1, 7.25)
	assert_f64eq(7.25, ndf64_at3(&a, 1, 0, 1))
	ndf64_fill(&a, 2.0)
	int i = 0
	while (i < a.data.length):
		assert_f64eq(2.0, a.data[i])
		i = i + 1


void test_views():
	ndf64 a = ndf64_new2(3, 2)
	ndf64_set2(&a, 1, 0, 4.0)
	ndf64_set2(&a, 1, 1, 5.0)
	float64[] row = ndf64_row(&a, 1)
	assert_f64eq(4.0, row[0])
	row[1] = 55.0
	assert_f64eq(55.0, ndf64_at2(&a, 1, 1))

	ndf64 sub = ndf64_sub(&a, 1, 3)
	assert_equal(2, sub.n0)
	assert_equal(1, ndf64_is_contiguous(&sub))
	ndf64_set2(&sub, 0, 0, 100.0)
	assert_f64eq(100.0, ndf64_at2(&a, 1, 0))


void test_elementwise_and_map():
	ndf64 a = ndf64_full2(2, 2, 2.0)
	ndf64 b = ndf64_full2(2, 2, 3.0)
	ndf64 out = ndf64_new2(2, 2)
	ndf64_add_into(&out, &a, &b)
	assert_f64eq(5.0, ndf64_at2(&out, 0, 0))
	ndf64_mul_into(&out, &a, &b)
	assert_f64eq(6.0, ndf64_at2(&out, 0, 0))
	ndf64_add_scalar_into(&out, &a, 1.5)
	assert_f64eq(3.5, ndf64_at2(&out, 0, 0))
	ndf64_mul_scalar_into(&out, &a, 4.0)
	assert_f64eq(8.0, ndf64_at2(&out, 0, 0))


float64 double_f64(float64 x):
	return x * 2.0


void test_map():
	ndf64 a = ndf64_new1(3)
	a.data[0] = 1.0
	a.data[1] = 2.0
	a.data[2] = 3.0
	ndf64 out = ndf64_new1(3)
	ndf64_map(&out, &a, double_f64)
	assert_f64eq(2.0, ndf64_at1(&out, 0))
	assert_f64eq(6.0, ndf64_at1(&out, 2))


# Same 2x3 . 3x2 fixture as lib/ndarray_test.w's test_matmul2_2x3_3x2.
void test_matmul2():
	ndf64 a = ndf64_new2(2, 3)
	ndf64 b = ndf64_new2(3, 2)
	ndf64 out = ndf64_new2(2, 2)
	ndf64_set2(&a, 0, 0, 1.0)
	ndf64_set2(&a, 0, 1, 2.0)
	ndf64_set2(&a, 0, 2, 3.0)
	ndf64_set2(&a, 1, 0, 4.0)
	ndf64_set2(&a, 1, 1, 5.0)
	ndf64_set2(&a, 1, 2, 6.0)
	ndf64_set2(&b, 0, 0, 7.0)
	ndf64_set2(&b, 0, 1, 8.0)
	ndf64_set2(&b, 1, 0, 9.0)
	ndf64_set2(&b, 1, 1, 10.0)
	ndf64_set2(&b, 2, 0, 11.0)
	ndf64_set2(&b, 2, 1, 12.0)
	ndf64_matmul2(&out, &a, &b)
	assert_f64eq(58.0, ndf64_at2(&out, 0, 0))
	assert_f64eq(64.0, ndf64_at2(&out, 0, 1))
	assert_f64eq(139.0, ndf64_at2(&out, 1, 0))
	assert_f64eq(154.0, ndf64_at2(&out, 1, 1))


int main(int argc, int argv):
	test_shape()
	test_construction_variants()
	test_get_set_and_fill()
	test_views()
	test_elementwise_and_map()
	test_map()
	test_matmul2()
	println(c"x64 ndarray64 OK")
	return 0
