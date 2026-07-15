# wbuild: x64
import lib.testing
import lib.thread

/*
parallel_for (lib/thread.w): each worker fills its slice of a shared
buffer, the main thread reduces and compares against the serial answer.
Covers an uneven split (len % nthreads != 0), nthreads clamped to the
range length, the inline nthreads <= 1 path, and the empty range.
Callbacks run on worker threads, so they only store into caller-owned
cells (no allocation, no asserts off the main thread).
*/

int[240] pf_buffer

int pf_calls


void fill_cb(int chunk_start, int chunk_end, void* arg):
	int base = cast(int, arg)
	int i = chunk_start
	while (i < chunk_end):
		pf_buffer[i] = i * i + base
		i = i + 1


void count_cb(int chunk_start, int chunk_end, void* arg):
	pf_calls = pf_calls + 1
	fill_cb(chunk_start, chunk_end, arg)


void pf_reset(int len):
	int i = 0
	while (i < len):
		pf_buffer[i] = 0 - 1
		i = i + 1


# Serial answer: sum of i*i + base over [start, end).
int pf_serial_sum(int start, int end, int base):
	int total = 0
	int i = start
	while (i < end):
		total = total + i * i + base
		i = i + 1
	return total


int pf_buffer_sum(int start, int end):
	int total = 0
	int i = start
	while (i < end):
		total = total + pf_buffer[i]
		i = i + 1
	return total


void test_parallel_fill_even_split():
	pf_reset(240)
	parallel_for(0, 240, 4, fill_cb, cast(void*, 5))
	int i = 0
	while (i < 240):
		assert_equal(i * i + 5, pf_buffer[i])
		i = i + 1
	assert_equal(pf_serial_sum(0, 240, 5), pf_buffer_sum(0, 240))


void test_parallel_fill_uneven_split():
	# 233 elements across 7 workers: the first 233 % 7 = 2 chunks get
	# one extra element; every cell must be written exactly once.
	pf_reset(240)
	parallel_for(7, 233, 7, fill_cb, cast(void*, 11))
	assert_equal(0 - 1, pf_buffer[6])
	assert_equal(0 - 1, pf_buffer[233])
	int i = 7
	while (i < 233):
		assert_equal(i * i + 11, pf_buffer[i])
		i = i + 1
	assert_equal(pf_serial_sum(7, 233, 11), pf_buffer_sum(7, 233))


void test_nthreads_clamped_to_range():
	pf_reset(240)
	parallel_for(10, 15, 64, fill_cb, cast(void*, 3))
	int i = 10
	while (i < 15):
		assert_equal(i * i + 3, pf_buffer[i])
		i = i + 1
	assert_equal(0 - 1, pf_buffer[9])
	assert_equal(0 - 1, pf_buffer[15])


void test_single_thread_runs_inline():
	pf_reset(64)
	pf_calls = 0
	parallel_for(0, 64, 1, count_cb, cast(void*, 2))
	# one inline call covering the whole range, no clone
	assert_equal(1, pf_calls)
	int i = 0
	while (i < 64):
		assert_equal(i * i + 2, pf_buffer[i])
		i = i + 1


void test_empty_range_never_calls():
	pf_calls = 0
	parallel_for(9, 9, 4, count_cb, cast(void*, 0))
	parallel_for(9, 5, 4, count_cb, cast(void*, 0))
	assert_equal(0, pf_calls)
