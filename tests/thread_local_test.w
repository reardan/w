# wbuild: x64
import lib.testing
import lib.thread

/*
thread_local globals (docs/projects/thread_local.md): every thread,
the main thread included, sees its own zero-initialized copy, reached
through gs (x64) / fs (x86). Plain globals stay shared, so the tests
contrast the two: each worker hammers its own thread_local copy with
no lock and records what it saw in a caller-owned slot, and the main
thread's copy must come through untouched.
*/

thread_local int tl_counter
thread_local int* tl_addr
thread_local char* tl_name

struct tl_pair:
	int a
	int b

thread_local tl_pair tl_rec

int shared_counter


void tl_worker(void* arg):
	int* slot = cast(int*, arg)
	# a fresh thread starts from zero, whatever main stored
	slot[0] = tl_counter
	slot[1] = tl_rec.a + tl_rec.b
	for i in range(100000):
		tl_counter = tl_counter + 1
		tl_rec.a = tl_rec.a + 2
		tl_rec.b = tl_counter
	tl_addr = &tl_counter
	slot[2] = tl_counter
	slot[3] = tl_rec.a
	slot[4] = tl_rec.b
	slot[5] = cast(int, tl_addr)
	atomic_add(&shared_counter, 1)


void test_main_thread_copy():
	tl_counter = 7
	tl_name = c"main"
	tl_rec.a = 3
	tl_rec.b = 4
	assert_equal(7, tl_counter)
	assert_equal(0, strcmp(c"main", tl_name))
	int* p = &tl_counter
	p[0] = 11
	assert_equal(11, tl_counter)
	assert_equal(7, tl_rec.a + tl_rec.b)


void test_workers_get_private_zeroed_copies():
	tl_counter = 1234
	tl_rec.a = 1
	tl_rec.b = 1
	int* main_addr = &tl_counter
	shared_counter = 0
	int n = 4
	int* slots = cast(int*, malloc(n * 6 * __word_size__))
	wthread** threads = cast(wthread**, malloc(n * __word_size__))
	int i = 0
	while (i < n):
		threads[i] = thread_spawn(tl_worker, cast(void*, &slots[i * 6]))
		asserts(c"thread_spawn failed", cast(int, threads[i]) != 0)
		i = i + 1
	i = 0
	while (i < n):
		assert_equal(0, thread_join(threads[i]))
		i = i + 1
	assert_equal(n, shared_counter)
	i = 0
	while (i < n):
		int* s = &slots[i * 6]
		assert_equal(0, s[0])
		assert_equal(0, s[1])
		assert_equal(100000, s[2])
		assert_equal(200000, s[3])
		assert_equal(100000, s[4])
		asserts(c"worker saw the main thread's address", s[5] != cast(int, main_addr))
		for j in range(i):
			asserts(c"two workers shared a thread_local", s[5] != slots[j * 6 + 5])
		i = i + 1
	# the main thread's copy is untouched by all of that
	assert_equal(1234, tl_counter)
	assert_equal(2, tl_rec.a + tl_rec.b)
	assert_equal(cast(int, main_addr), cast(int, &tl_counter))


# Pool workers keep their TLS across jobs: a per-thread running total
# survives from one parallel_for call to the next on the same worker.
void tl_pool_chunk(int start, int end, void* arg):
	int* out = cast(int*, arg)
	for i in range(start, end):
		tl_counter = tl_counter + 1
	out[start] = tl_counter


void test_pool_workers_keep_tls_across_jobs():
	thread_pool_init(3)
	tl_counter = 0
	int* out = cast(int*, malloc(4 * __word_size__))
	parallel_for(0, 4, 4, tl_pool_chunk, cast(void*, out))
	parallel_for(0, 4, 4, tl_pool_chunk, cast(void*, out))
	# chunk 0 runs on main; each pooled chunk ran on a worker that has
	# now counted one element per call
	assert_equal(2, out[0])
	assert_equal(2, out[1])
	assert_equal(2, out[2])
	assert_equal(2, out[3])
	assert_equal(2, tl_counter)
	thread_pool_shutdown()
