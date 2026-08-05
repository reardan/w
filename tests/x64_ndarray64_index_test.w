# wbuild: arch_only=x64 expect_stdout="x64 ndarray64 index OK"
# float64 twin of tests/ndarray_index_test.w's sugar coverage: the
# comma-index sugar m[i, j] on ndf64 (lib/ndarray64.w) lowers to the
# ndf64_atN/ndf64_setN accessors, x64-only like every float64 consumer.
# House style follows tests/x64_ndarray64_test.w: plain main() with
# manual assertions, arch_only=x64 directive.
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


void test_round_trip():
	ndf64 a = ndf64_new2(3, 4)
	ndf64* m = &a
	m[1, 2] = 5.5
	assert_f64eq(5.5, ndf64_at2(m, 1, 2))
	ndf64_set2(m, 2, 3, 7.25)
	assert_f64eq(7.25, m[2, 3])
	a[0, 1] = 1.5
	assert_f64eq(1.5, ndf64_at2(&a, 0, 1))


void test_rank3_rank4():
	ndf64 b = ndf64_new3(2, 3, 4)
	b[1, 2, 3] = 9.0
	assert_f64eq(9.0, ndf64_at3(&b, 1, 2, 3))
	ndf64_set3(&b, 0, 1, 2, 3.5)
	assert_f64eq(3.5, b[0, 1, 2])

	ndf64 c = ndf64_new4(2, 2, 2, 2)
	c[1, 0, 1, 0] = 4.0
	assert_f64eq(4.0, ndf64_at4(&c, 1, 0, 1, 0))
	assert_f64eq(4.0, c[1, 0, 1, 0])


void test_compound_assign():
	ndf64 a = ndf64_new2(2, 2)
	a[1, 1] = 5.5
	a[1, 1] += 0.25
	assert_f64eq(5.75, ndf64_at2(&a, 1, 1))
	a[1, 1] *= 2.0
	assert_f64eq(11.5, a[1, 1])


int main(int argc, int argv):
	test_round_trip()
	test_rank3_rank4()
	test_compound_assign()
	println(c"x64 ndarray64 index OK")
	return 0
