# wbuild: x64
import lib.testing
import lib.format
import lib.rand
import lib.array
import lib.ndarray
import lib.ndarray_par
import lib.thread

/*
Stage 3 of docs/projects/ndarray.md: parallel_for integration
(lib/ndarray_par.w). Every parallel result must be BIT-IDENTICAL to the
serial reference:

- elementwise ops (add, and the axpy shape s*x + y) chunk the leading
  axis; each element is computed by the same float expression as the
  serial twin, so any difference means a chunking bug (a row computed
  twice, skipped, or raced);
- a Jacobi-style 5-point stencil shares one row kernel between the
  serial loop and the parallel_for chunks: workers read shared rows
  (including neighbors OUTSIDE their own chunk) and write only their
  own rows, the doc's aliasing contract;
- the two-phase sum reduction is deterministic for a fixed nthreads
  (parallel_for's chunk split is a pure function of (n0, nthreads), and
  partials are combined in chunk order), so it is asserted bit-equal
  against the same two-phase computation done serially, and bit-equal
  to the plain serial ndf_sum in the single-chunk degenerate cases.

Data comes from lib/rand.w's deterministic xorshift with fixed seeds,
so every run and both word sizes see the same float32 inputs.
Comparisons are on the raw float32 bit patterns (load_int32), not
float ==, so the "bit-identical" claim is literal.

Threading is Linux x86/x64 (lib/thread.w), same coverage as
tests/parallel_for_test.w; parallel entry points run on the main
thread only, and the stencil worker only reads/writes caller-owned
buffers (no allocation off the main thread).
*/


void assert_feq_bits(float want, float got):
	char* pw = &want
	char* pg = &got
	if (load_int32(pw) != load_int32(pg)):
		print2(c"Assertion failed: float bits differ: wanted ")
		print2(hex(load_int32(pw)))
		print2(c" got ")
		println2(hex(load_int32(pg)))
		print_stack_trace()
		exit(1)


void nd3_fill_random(ndf* a, int seed):
	rand_state r
	rand_init(&r, seed)
	int i = 0
	while (i < a.data.length):
		a.data[i] = rand_float(&r)
		i = i + 1


void nd3_assert_bit_identical(ndf* want, ndf* got):
	ndf_assert_same_shape(want, got, c"nd3_assert_bit_identical: shape mismatch")
	int i = 0
	while (i < want.data.length):
		assert_feq_bits(want.data[i], got.data[i])
		i = i + 1


########################### elementwise: add ###########################


# 13 rows across 4 workers: an uneven split (13 % 4 = 1), so chunk
# boundary arithmetic is exercised, not just the even case.
void test_add_into_par_bit_identical():
	ndf a = ndf_new2(13, 7)
	ndf b = ndf_new2(13, 7)
	nd3_fill_random(&a, 101)
	nd3_fill_random(&b, 202)
	ndf serial = ndf_new2(13, 7)
	ndf par = ndf_new2(13, 7)
	ndf_add_into(&serial, &a, &b)
	ndf_add_into_par(&par, &a, &b, 4)
	nd3_assert_bit_identical(&serial, &par)
	ndf_free(&a)
	ndf_free(&b)
	ndf_free(&serial)
	ndf_free(&par)


########################### elementwise: axpy ###########################


void test_axpy_into_par_bit_identical():
	ndf x = ndf_new1(101)
	ndf y = ndf_new1(101)
	nd3_fill_random(&x, 7)
	nd3_fill_random(&y, 9)
	ndf serial = ndf_new1(101)
	ndf par = ndf_new1(101)
	ndf_axpy_into(&serial, 0.5, &x, &y)
	ndf_axpy_into_par(&par, 0.5, &x, &y, 3)
	nd3_assert_bit_identical(&serial, &par)
	# in-place axpy (out aliases y), serial vs parallel on equal copies
	ndf y2 = ndf_new1(101)
	nd3_fill_random(&y2, 9)
	ndf_axpy_into(&y, 0.5, &x, &y)
	ndf_axpy_into_par(&y2, 0.5, &x, &y2, 3)
	nd3_assert_bit_identical(&y, &y2)
	ndf_free(&x)
	ndf_free(&y)
	ndf_free(&y2)
	ndf_free(&serial)
	ndf_free(&par)


######################## Jacobi-style stencil ##########################


# One shared row kernel for both the serial reference and the parallel
# chunks: dst interior row i gets the 5-point average of src's
# neighbors. Reads cross chunk boundaries (rows i-1 and i+1); writes
# stay inside [r0, r1) -- the doc's "no concurrent writers to the same
# element" contract.
void nd3_jacobi_rows(ndf* dst, ndf* src, int r0, int r1):
	int i = r0
	while (i < r1):
		int j = 1
		while (j < src.n1 - 1):
			float v = 0.25 * (ndf_at2(src, i - 1, j) + ndf_at2(src, i + 1, j) + ndf_at2(src, i, j - 1) + ndf_at2(src, i, j + 1))
			ndf_set2(dst, i, j, v)
			j = j + 1
		i = i + 1


struct nd3_jacobi_ctx:
	ndf* dst
	ndf* src


void nd3_jacobi_chunk(int r0, int r1, void* p):
	nd3_jacobi_ctx* ctx = cast(nd3_jacobi_ctx*, p)
	nd3_jacobi_rows(ctx.dst, ctx.src, r0, r1)


void test_jacobi_par_bit_identical():
	ndf grid = ndf_new2(17, 9)
	nd3_fill_random(&grid, 42)
	ndf serial = ndf_new2(17, 9)
	ndf par = ndf_new2(17, 9)
	nd3_jacobi_rows(&serial, &grid, 1, 16)
	nd3_jacobi_ctx ctx
	ctx.dst = &par
	ctx.src = &grid
	parallel_for(1, 16, 4, nd3_jacobi_chunk, cast(void*, &ctx))
	nd3_assert_bit_identical(&serial, &par)
	# boundary rows/columns stay untouched by both paths
	assert_feq_bits(0.0, ndf_at2(&par, 0, 0))
	assert_feq_bits(0.0, ndf_at2(&par, 16, 8))
	assert_feq_bits(0.0, ndf_at2(&par, 5, 0))
	ndf_free(&grid)
	ndf_free(&serial)
	ndf_free(&par)


###################### two-phase sum reduction #########################


void test_sum_par_two_phase_matches_serial_chunks():
	ndf a = ndf_new2(11, 5)
	nd3_fill_random(&a, 77)
	# Reference: the SAME two-phase computation done serially -- the
	# same deterministic chunk split (thread_chunk_offset), each
	# chunk's rows accumulated left-to-right, partials combined in
	# chunk order.
	int nthreads = 3
	float total = 0.0
	int k = 0
	while (k < nthreads):
		int r0 = thread_chunk_offset(11, nthreads, k)
		int r1 = thread_chunk_offset(11, nthreads, k + 1)
		float acc = 0.0
		int i = r0 * a.s0
		while (i < r1 * a.s0):
			acc = acc + a.data[i]
			i = i + 1
		total = total + acc
		k = k + 1
	assert_feq_bits(total, ndf_sum_par(&a, nthreads))
	ndf_free(&a)


void test_sum_par_single_thread_matches_serial():
	ndf a = ndf_new1(37)
	nd3_fill_random(&a, 5)
	# nthreads <= 1: exactly the serial left-to-right sum
	assert_feq_bits(ndf_sum(&a), ndf_sum_par(&a, 1))
	ndf_free(&a)
	# nthreads clamped to n0: a 1-row array degenerates to one chunk
	ndf b = ndf_new2(1, 6)
	nd3_fill_random(&b, 6)
	assert_feq_bits(ndf_sum(&b), ndf_sum_par(&b, 100))
	ndf_free(&b)


#################### degenerate chunking, elementwise ####################


void test_elementwise_par_degenerate_chunking():
	ndf a = ndf_new2(3, 4)
	ndf b = ndf_new2(3, 4)
	nd3_fill_random(&a, 11)
	nd3_fill_random(&b, 12)
	ndf serial = ndf_new2(3, 4)
	ndf_add_into(&serial, &a, &b)
	# nthreads == 1: the inline no-clone path
	ndf par1 = ndf_new2(3, 4)
	ndf_add_into_par(&par1, &a, &b, 1)
	nd3_assert_bit_identical(&serial, &par1)
	# nthreads far above n0: clamped to one row per worker
	ndf par2 = ndf_new2(3, 4)
	ndf_add_into_par(&par2, &a, &b, 64)
	nd3_assert_bit_identical(&serial, &par2)
	ndf_free(&a)
	ndf_free(&b)
	ndf_free(&serial)
	ndf_free(&par1)
	ndf_free(&par2)
