# wbuild: x64
import lib.testing
import lib.thread

/*
Host atomic intrinsics (grammar/atomic_builtin.w, lock xadd / lock
cmpxchg via code_generator/x86.w): fetch-and-modify semantics single-
threaded, then exactness under real multi-core contention.

The contention tests are the load-bearing ones: 4 threads hammer one
shared word with no other synchronization, so the final count is exact
only if the read-modify-write really is atomic. A plain `x = x + 1`
compiles to separate load/add/store instructions here (single-pass
codegen), so with these iteration counts concurrent workers would
overwhelmingly likely interleave and lose updates — but a lost-update
assertion can never be made deterministic, so what this test pins down
deterministically is the positive contract: the atomic forms never
lose one.
*/

int shared_counter
int cas_counter


void add_worker(void* arg):
	int n = cast(int, arg)
	for i in range(n): atomic_add(&shared_counter, 1)


# Increment via a compare-and-swap retry loop: exercises the failure
# path (reload and retry) under contention, not just the success path.
void cas_worker(void* arg):
	int n = cast(int, arg)
	for i in range(n):
		int seen = cas_counter
		while (atomic_cas(&cas_counter, seen, seen + 1) != seen): seen = cas_counter


void test_atomic_add_fetches_old_value():
	int x = 40
	assert_equal(40, atomic_add(&x, 2))
	assert_equal(42, x)
	# negative deltas decrement
	assert_equal(42, atomic_add(&x, 0 - 50))
	assert_equal(0 - 8, x)
	# zero delta is a pure fetch
	assert_equal(0 - 8, atomic_add(&x, 0))


void test_atomic_cas_semantics():
	int x = 5
	# matching expected: swaps, returns the old value
	assert_equal(5, atomic_cas(&x, 5, 9))
	assert_equal(9, x)
	# stale expected: leaves the word alone, returns the current value
	assert_equal(9, atomic_cas(&x, 5, 100))
	assert_equal(9, x)
	# the returned current value feeds the standard retry idiom
	assert_equal(9, atomic_cas(&x, 9, 0 - 1))
	assert_equal(0 - 1, x)


void test_atomic_add_exact_under_contention():
	shared_counter = 0
	int per_thread = 100000
	wthread*[4] threads
	int i = 0
	while (i < 4):
		threads[i] = thread_spawn(add_worker, cast(void*, per_thread))
		asserts(c"thread_spawn failed", cast(int, threads[i]) != 0)
		i = i + 1
	i = 0
	while (i < 4):
		assert_equal(0, thread_join(threads[i]))
		i = i + 1
	assert_equal(4 * per_thread, shared_counter)


void test_atomic_cas_exact_under_contention():
	cas_counter = 0
	int per_thread = 20000
	wthread*[4] threads
	int i = 0
	while (i < 4):
		threads[i] = thread_spawn(cas_worker, cast(void*, per_thread))
		asserts(c"thread_spawn failed", cast(int, threads[i]) != 0)
		i = i + 1
	i = 0
	while (i < 4):
		assert_equal(0, thread_join(threads[i]))
		i = i + 1
	assert_equal(4 * per_thread, cas_counter)


int publication_ready
int publication_payload
int publication_bad


void publication_writer(void* arg):
	int count = cast(int, arg)
	for i in range(1, count + 1):
		while (atomic_load(&publication_ready) != 0): th_yield()
		publication_payload = i
		atomic_store(&publication_ready, 1)


void publication_reader(void* arg):
	int count = cast(int, arg)
	for i in range(1, count + 1):
		while (atomic_load(&publication_ready) == 0): th_yield()
		if (publication_payload != i): publication_bad = 1
		atomic_store(&publication_ready, 0)


# The release flag publishes ordinary payload writes. The acknowledgement
# releases the payload back to the writer, avoiding a data race when it is
# reused. Every iteration exercises both directions of the happens-before edge.
void test_atomic_acquire_release_publication():
	atomic_store_relaxed(&publication_ready, 0)
	publication_bad = 0
	wthread* writer = thread_spawn(publication_writer, cast(void*, 20000))
	wthread* reader = thread_spawn(publication_reader, cast(void*, 20000))
	assert1(writer != 0 && reader != 0)
	assert_equal(0, thread_join(writer))
	assert_equal(0, thread_join(reader))
	assert_equal(0, publication_bad)
	assert_equal(20000, publication_payload)
	atomic_fence()


int fence_round
int fence_left
int fence_right
int fence_left_seen
int fence_right_seen
int fence_left_done
int fence_right_done


void fence_left_worker(void* arg):
	int count = cast(int, arg)
	for i in range(1, count + 1):
		while (atomic_load(&fence_round) != i): th_yield()
		atomic_store_relaxed(&fence_left, 1)
		atomic_fence()
		fence_left_seen = atomic_load_relaxed(&fence_right)
		atomic_store(&fence_left_done, i)


void fence_right_worker(void* arg):
	int count = cast(int, arg)
	for i in range(1, count + 1):
		while (atomic_load(&fence_round) != i): th_yield()
		atomic_store_relaxed(&fence_right, 1)
		atomic_fence()
		fence_right_seen = atomic_load_relaxed(&fence_left)
		atomic_store(&fence_right_done, i)


# Store-buffer litmus: two full fences forbid both threads reading zero.
# The coordinator publishes resets before each round and reads results only
# after both release completion flags, without serializing the tested accesses.
void test_atomic_fence_orders_store_then_load():
	int count = 10000
	atomic_store_relaxed(&fence_round, 0)
	atomic_store_relaxed(&fence_left_done, 0)
	atomic_store_relaxed(&fence_right_done, 0)
	wthread* left = thread_spawn(fence_left_worker, cast(void*, count))
	wthread* right = thread_spawn(fence_right_worker, cast(void*, count))
	assert1(left != 0 && right != 0)
	for i in range(1, count + 1):
		atomic_store_relaxed(&fence_left, 0)
		atomic_store_relaxed(&fence_right, 0)
		atomic_store(&fence_round, i)
		while (atomic_load(&fence_left_done) != i): th_yield()
		while (atomic_load(&fence_right_done) != i): th_yield()
		assert1(fence_left_seen != 0 || fence_right_seen != 0)
	assert_equal(0, thread_join(left))
	assert_equal(0, thread_join(right))
