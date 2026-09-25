# wbuild: x64
import lib.testing
import lib.thread

/*
Per-thread heaps (lib/thread_heap.w, issue #498): workers allocate
freely, from their own heap, with no lock. The tests hammer the
paths that corrupt a shared free list first: concurrent mixed-size
malloc/free churn, container growth (list push, map insert, string
building), blocks crossing threads in both directions, and heaps being
abandoned and adopted across spawn/join cycles.

Every block is stamped with its owner and size and checked before it
is freed, so a block handed to two threads at once, or a free that
landed in the wrong heap, shows up as a stamp mismatch rather than a
silent crash later.
*/

int churn_ok


void stamp(int* p, int words, int tag):
	int i = 0
	while (i < words):
		p[i] = tag + i
		i = i + 1


int stamped(int* p, int words, int tag):
	int i = 0
	while (i < words):
		if (p[i] != tag + i):
			return 0
		i = i + 1
	return 1


void churn_worker(void* arg):
	int id = cast(int, arg)
	int slots = 64
	int** live = cast(int**, malloc(slots * __word_size__))
	int* sizes = cast(int*, malloc(slots * __word_size__))
	int i = 0
	while (i < slots):
		live[i] = cast(int*, 0)
		i = i + 1
	int seed = id * 7919 + 1
	int round = 0
	int ok = 1
	while (round < 20000):
		seed = (seed * 1103515245 + 12345) & 0x7fffffff
		int k = seed % slots
		if (live[k] != 0):
			if (stamped(live[k], sizes[k], id * 100000 + k) == 0):
				ok = 0
			free(cast(void*, live[k]))
			live[k] = cast(int*, 0)
		else:
			int words = 1 + (seed >> 8) % 300
			if ((seed & 1023) == 0):
				words = 20000   # past the small bins
			live[k] = cast(int*, malloc(words * __word_size__))
			sizes[k] = words
			stamp(live[k], words, id * 100000 + k)
		round = round + 1
	i = 0
	while (i < slots):
		if (live[i] != 0):
			if (stamped(live[i], sizes[i], id * 100000 + i) == 0):
				ok = 0
			free(cast(void*, live[i]))
		i = i + 1
	free(cast(void*, live))
	free(cast(void*, sizes))
	if (ok):
		atomic_add(&churn_ok, 1)


void test_concurrent_malloc_free_churn():
	churn_ok = 0
	int n = 4
	wthread** threads = cast(wthread**, malloc(n * __word_size__))
	int i = 0
	while (i < n):
		threads[i] = thread_spawn(churn_worker, cast(void*, i + 1))
		asserts(c"thread_spawn failed", cast(int, threads[i]) != 0)
		i = i + 1
	# the main thread churns its own heap at the same time
	int* scratch = cast(int*, 0)
	int j = 0
	while (j < 5000):
		scratch = cast(int*, malloc((j % 40 + 1) * __word_size__))
		stamp(scratch, j % 40 + 1, j)
		assert_equal(1, stamped(scratch, j % 40 + 1, j))
		free(cast(void*, scratch))
		j = j + 1
	i = 0
	while (i < n):
		assert_equal(0, thread_join(threads[i]))
		i = i + 1
	assert_equal(n, churn_ok)


# Containers and strings on workers: list/map growth reallocs, string
# formatting allocates, and the results are handed back to main, which
# reads them after join and frees them (worker blocks freed on main).
struct build_job:
	int id
	list[int] values
	map[int, int] squares
	char* label


void build_worker(void* arg):
	build_job* job = cast(build_job*, arg)
	list[int] values = new list[int]
	map[int, int] squares = new map[int, int]
	int i = 0
	while (i < 5000):
		values.push(i * job.id)
		squares[i] = i * i
		i = i + 1
	job.values = values
	job.squares = squares
	job.label = strjoin(strjoin(c"worker ", itoa(job.id)), strjoin(c" built ", itoa(values.length)))


void test_worker_containers_and_strings_come_back_to_main():
	int n = 3
	build_job** jobs = cast(build_job**, malloc(n * __word_size__))
	wthread** threads = cast(wthread**, malloc(n * __word_size__))
	int i = 0
	while (i < n):
		jobs[i] = new build_job()
		jobs[i].id = i + 1
		threads[i] = thread_spawn(build_worker, cast(void*, jobs[i]))
		asserts(c"thread_spawn failed", cast(int, threads[i]) != 0)
		i = i + 1
	i = 0
	while (i < n):
		assert_equal(0, thread_join(threads[i]))
		build_job* job = jobs[i]
		assert_equal(5000, job.values.length)
		assert_equal(4999 * job.id, job.values[4999])
		assert_equal(4999 * 4999, job.squares[4999])
		assert_strings_equal(strjoin(strjoin(c"worker ", itoa(job.id)), c" built 5000"), job.label)
		free(cast(void*, job.label))
		i = i + 1


# Blocks flowing main -> worker (the worker frees main-heap blocks,
# which queue on the main heap's remote list) and worker -> worker
# (a producer's blocks freed by a consumer).
int* handoff_ring
int handoff_count
int handoff_done


void consume_worker(void* arg):
	int n = cast(int, arg)
	int i = 0
	int ok = 1
	while (i < n):
		# wait for slot i to be filled
		while (atomic_add(&handoff_ring[i % 64 + 64], 0) == 0) {}
		int* p = cast(int*, handoff_ring[i % 64])
		if (stamped(p, 8, i) == 0):
			ok = 0
		free(cast(void*, p))
		handoff_ring[i % 64 + 64] = 0
		i = i + 1
	handoff_done = ok


void produce_worker(void* arg):
	int n = cast(int, arg)
	int i = 0
	while (i < n):
		while (atomic_add(&handoff_ring[i % 64 + 64], 0) != 0) {}
		int* p = cast(int*, malloc(8 * __word_size__))
		stamp(p, 8, i)
		handoff_ring[i % 64] = cast(int, p)
		atomic_add(&handoff_ring[i % 64 + 64], 1)
		i = i + 1


void test_blocks_cross_threads():
	handoff_ring = cast(int*, malloc(128 * __word_size__))
	int i = 0
	while (i < 128):
		handoff_ring[i] = 0
		i = i + 1
	handoff_done = 0
	int n = 20000
	wthread* c = thread_spawn(consume_worker, cast(void*, n))
	wthread* p = thread_spawn(produce_worker, cast(void*, n))
	assert_equal(0, thread_join(p))
	assert_equal(0, thread_join(c))
	assert_equal(1, handoff_done)
	# main-heap blocks freed by a worker come back to main's allocator
	int* a = cast(int*, malloc(16 * __word_size__))
	# slot 0 carries tag 0 for consume_worker's check
	stamp(a, 8, 0)
	handoff_ring[0] = cast(int, a)
	handoff_ring[64] = 1
	handoff_done = 0
	c = thread_spawn(consume_worker, cast(void*, 1))
	assert_equal(0, thread_join(c))
	assert_equal(1, handoff_done)
	# main keeps allocating: the drained block is reusable
	int k = 0
	while (k < 100):
		free(malloc(16 * __word_size__))
		k = k + 1


# Heaps are abandoned at exit and adopted by later threads, so a long
# spawn/join loop does not grow memory without bound.
void small_alloc_worker(void* arg):
	int i = 0
	while (i < 200):
		free(malloc(64))
		i = i + 1
	# leave one block behind: the adopter inherits it
	malloc(32)


void test_spawn_join_cycles_reuse_heaps():
	int i = 0
	while (i < 300):
		wthread* t = thread_spawn(small_alloc_worker, cast(void*, 0))
		asserts(c"thread_spawn failed", cast(int, t) != 0)
		assert_equal(0, thread_join(t))
		i = i + 1


# parallel_for callbacks allocate on pool workers.
void pf_alloc_chunk(int start, int end, void* arg):
	int* out = cast(int*, arg)
	int i = start
	while (i < end):
		list[int] tmp = new list[int]
		int j = 0
		while (j < 100):
			tmp.push(j)
			j = j + 1
		out[i] = tmp.length + tmp[99]
		i = i + 1


void test_parallel_for_callbacks_allocate():
	int n = 64
	int* out = cast(int*, malloc(n * __word_size__))
	parallel_for(0, n, 4, pf_alloc_chunk, cast(void*, out))
	parallel_for(0, n, 4, pf_alloc_chunk, cast(void*, out))
	int i = 0
	while (i < n):
		assert_equal(199, out[i])
		i = i + 1
	thread_pool_shutdown()
