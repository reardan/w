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
	int i = 0
	while (i < n):
		atomic_add(&shared_counter, 1)
		i = i + 1


# Increment via a compare-and-swap retry loop: exercises the failure
# path (reload and retry) under contention, not just the success path.
void cas_worker(void* arg):
	int n = cast(int, arg)
	int i = 0
	while (i < n):
		int seen = cas_counter
		while (atomic_cas(&cas_counter, seen, seen + 1) != seen):
			seen = cas_counter
		i = i + 1


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
