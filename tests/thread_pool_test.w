# wbuild: x64
import lib.testing
import lib.thread

/*
Persistent worker pool behind parallel_for (lib/thread.w, threads.md
staging item 2). The pool must be observably identical to the old
spawn-per-chunk parallel_for: same deterministic chunk boundaries,
every cell written exactly once, all chunks complete before the call
returns. On top of tests/parallel_for_test.w these tests pin the
pool-specific properties: worker reuse across many calls (the
spawn-cost case - thread_pool_size stays at the first call's
nthreads - 1), explicit init pinning with chunk spans wider than the
pool, shutdown + lazy re-creation, repeated init/shutdown cycles
reclaiming the workers, nested parallel_for from a pool worker
(serialized in place) and from the main thread's chunk-0 callback
(spawn fallback), and pool workers contending on a wmutex.

Callbacks run on pool workers: they only store into caller-owned
cells and never allocate or assert (lib/thread.w constraints); the
main thread asserts after parallel_for returns.
*/

int[128] pool_buffer

wmutex* pool_mutex
int pool_locked_count

int[40] nested_buffer


void pool_fill_cb(int chunk_start, int chunk_end, void* arg):
	int base = cast(int, arg)
	int i = chunk_start
	while (i < chunk_end):
		pool_buffer[i] = i * 7 + base
		i = i + 1


void pool_check_range(int start, int end, int base):
	int i = start
	while (i < end):
		assert_equal(i * 7 + base, pool_buffer[i])
		i = i + 1


# The spawn-cost case: 1000 parallel_for calls in a loop reuse the
# same three pool workers where the spawn path would have paid 3000
# clones. Every call's cells are verified (a lost wake or a stale job
# would leave a cell at the previous iteration's value), and the pool
# provably never grew past the first call's nthreads - 1.
void test_pool_reused_across_calls():
	thread_pool_shutdown()
	int it = 0
	while (it < 1000):
		parallel_for(0, 48, 4, pool_fill_cb, cast(void*, it))
		pool_check_range(0, 48, it)
		it = it + 1
	assert_equal(3, thread_pool_size)
	thread_pool_shutdown()
	assert_equal(0, thread_pool_size)


# Explicit init pins the pool: 9 chunks over a 2-worker pool hand
# each worker a span of 4 chunks (the caller runs chunk 0); the
# boundaries and results are unchanged and the pool must not grow.
void test_pool_pinned_smaller_than_chunks():
	assert_equal(2, thread_pool_init(2))
	parallel_for(0, 90, 9, pool_fill_cb, cast(void*, 5))
	pool_check_range(0, 90, 5)
	assert_equal(2, thread_pool_size)
	thread_pool_shutdown()


# After a shutdown the next parallel_for lazily builds a fresh
# unpinned pool sized to its own nthreads - 1, and a later wider call
# grows it on demand.
void test_pool_lazy_recreate_after_shutdown():
	thread_pool_shutdown()
	assert_equal(0, thread_pool_size)
	parallel_for(0, 60, 3, pool_fill_cb, cast(void*, 9))
	pool_check_range(0, 60, 9)
	assert_equal(2, thread_pool_size)
	parallel_for(0, 60, 5, pool_fill_cb, cast(void*, 4))
	pool_check_range(0, 60, 4)
	assert_equal(4, thread_pool_size)
	thread_pool_shutdown()


# Repeated init/shutdown cycles: every cycle's spawns must succeed
# (shutdown really reclaims the workers' stacks through thread_join;
# leaks would exhaust a 32-bit address space over enough cycles) and
# the pool restarts cleanly each time.
void test_pool_init_shutdown_cycles():
	int cycle = 0
	while (cycle < 40):
		assert_equal(2, thread_pool_init(2))
		parallel_for(0, 8, 3, pool_fill_cb, cast(void*, cycle))
		pool_check_range(0, 8, cycle)
		thread_pool_shutdown()
		assert_equal(0, thread_pool_size)
		cycle = cycle + 1


void nested_inner_cb(int chunk_start, int chunk_end, void* arg):
	int i = chunk_start
	while (i < chunk_end):
		nested_buffer[i] = i * 3 + 1
		i = i + 1


# Runs on the main thread for outer chunk 0 (its nested call takes
# the spawn fallback while the pool is busy) and on pool workers for
# outer chunks 1..3 (their nested calls run serially in place).
void nested_outer_cb(int chunk_start, int chunk_end, void* arg):
	int c = chunk_start
	while (c < chunk_end):
		parallel_for(c * 10, c * 10 + 10, 2, nested_inner_cb, arg)
		c = c + 1


void test_pool_nested_parallel_for():
	thread_pool_shutdown()
	int i = 0
	while (i < 40):
		nested_buffer[i] = 0 - 1
		i = i + 1
	parallel_for(0, 4, 4, nested_outer_cb, cast(void*, 0))
	i = 0
	while (i < 40):
		assert_equal(i * 3 + 1, nested_buffer[i])
		i = i + 1
	thread_pool_shutdown()


void pool_mutex_cb(int chunk_start, int chunk_end, void* arg):
	int i = chunk_start
	while (i < chunk_end):
		mutex_lock(pool_mutex)
		# non-atomic read-modify-write, safe only under the lock
		pool_locked_count = pool_locked_count + 1
		mutex_unlock(pool_mutex)
		i = i + 1


# Pool workers and the calling thread contend on one wmutex inside
# their chunks, across repeated jobs on the same workers; the exact
# final count pins mutual exclusion and cross-job visibility.
void test_pool_mutex_interplay():
	thread_pool_shutdown()
	pool_mutex = new wmutex()
	mutex_init(pool_mutex)
	pool_locked_count = 0
	int it = 0
	while (it < 25):
		parallel_for(0, 4000, 4, pool_mutex_cb, cast(void*, 0))
		it = it + 1
	assert_equal(25 * 4000, pool_locked_count)
	free(cast(void*, pool_mutex))
	thread_pool_shutdown()
