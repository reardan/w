# wbuild: x64
import lib.testing
import lib.arena
import lib.thread


void test_shared_budget_checked_limits_and_lifetime():
	mem_shared_budget b
	mem_shared_budget_stats s
	assert_equal(ARENA_ERR_INVALID, mem_shared_budget_init(&b, -1))
	assert_equal(ARENA_OK, mem_shared_budget_init(&b, 16))
	assert_equal(ARENA_OK, mem_shared_budget_retain(&b))
	assert_equal(ARENA_ERR_BUSY, mem_shared_budget_destroy(&b))
	assert_equal(ARENA_OK, mem_shared_budget_reserve(&b, 16))
	assert_equal(ARENA_ERR_BUDGET, mem_shared_budget_reserve(&b, 1))
	assert_equal(ARENA_ERR_INVALID, mem_shared_budget_reserve(&b, -1))
	assert_equal(ARENA_ERR_INVALID, mem_shared_budget_release(&b, 17))
	assert_equal(ARENA_ERR_INVALID, mem_shared_budget_release(&b, -1))
	assert_equal(ARENA_OK, mem_shared_budget_snapshot(&b, &s))
	assert_equal(16, s.used)
	assert_equal(16, s.peak)
	assert_equal(2, s.failures)
	assert_equal(2, s.release_errors)
	assert_equal(ARENA_OK, mem_shared_budget_drop(&b))
	assert_equal(ARENA_ERR_INVALID, mem_shared_budget_drop(&b))
	assert_equal(ARENA_ERR_BUSY, mem_shared_budget_destroy(&b))
	assert_equal(ARENA_OK, mem_shared_budget_release(&b, 16))
	assert_equal(ARENA_OK, mem_shared_budget_destroy(&b))
	assert_equal(ARENA_OK, mem_shared_budget_destroy(&b))
	assert_equal(ARENA_ERR_CLOSED, mem_shared_budget_retain(&b))
	assert_equal(ARENA_ERR_CLOSED, mem_shared_budget_reserve(&b, 0))
	assert_equal(ARENA_OK, mem_shared_budget_init(&b, arena_int_max()))
	assert_equal(ARENA_OK, mem_shared_budget_reserve(&b, arena_int_max()))
	assert_equal(ARENA_ERR_OVERFLOW, mem_shared_budget_reserve(&b, 1))
	assert_equal(ARENA_OK, mem_shared_budget_release(&b, arena_int_max()))
	assert_equal(ARENA_OK, mem_shared_budget_destroy(&b))
	assert_equal(ARENA_OK, mem_shared_budget_init(&b, 0))
	assert_equal(ARENA_OK, mem_shared_budget_reserve(&b, 0))
	assert_equal(ARENA_ERR_BUDGET, mem_shared_budget_reserve(&b, 1))
	assert_equal(ARENA_OK, mem_shared_budget_destroy(&b))


char* shared_budget_fail_alloc(void* context, int size):
	mem_shared_budget* b = cast(mem_shared_budget*, context)
	mem_shared_budget_stats s
	# Proves callback runs outside the lock with bytes already reserved.
	assert_equal(ARENA_OK, mem_shared_budget_snapshot(b, &s))
	assert_equal(size, s.used)
	return 0


void test_shared_budget_heap_failure_rolls_back():
	mem_shared_budget b
	mem_shared_budget_stats s
	assert_equal(ARENA_OK, mem_shared_budget_init(&b, 1024))
	char* p = cast(char*, 1)
	assert_equal(ARENA_ERR_NO_MEMORY, mem_shared_budget_alloc_with(&b, 100, &p, shared_budget_fail_alloc, &b))
	assert_equal(0, cast(int, p))
	assert_equal(ARENA_OK, mem_shared_budget_snapshot(&b, &s))
	assert_equal(0, s.used)
	assert_equal(100, s.peak)
	assert_equal(1, s.failures)
	assert_equal(ARENA_ERR_OVERFLOW, mem_shared_budget_alloc(&b, ARENA_MAX_REQUEST + 1, &p))
	assert_equal(ARENA_ERR_INVALID, mem_shared_budget_alloc(&b, -1, &p))
	assert_equal(ARENA_OK, mem_shared_budget_alloc(&b, 0, &p))
	assert1(p != 0)
	assert_equal(ARENA_OK, mem_shared_budget_snapshot(&b, &s))
	assert_equal(1, s.used)
	assert_equal(3, s.failures)
	assert_equal(ARENA_OK, mem_shared_budget_free(&b, p, 0))
	assert_equal(ARENA_OK, mem_shared_budget_destroy(&b))


void test_shared_budget_arena_attachment_and_borrows():
	mem_shared_budget b
	mem_shared_budget_stats s
	int total = 128 + arena_chunk_header_size()
	assert_equal(ARENA_OK, mem_shared_budget_init(&b, total))
	arena a
	arena_init(&a, 128, 0)
	assert_equal(ARENA_OK, arena_set_thread_budget(&a, &b))
	char* p = 0
	assert_equal(ARENA_OK, arena_alloc(&a, 100, 1, &p))
	assert_equal(ARENA_ERR_BUDGET, arena_alloc(&a, 100, 1, &p))
	assert_equal(ARENA_ERR_INVALID, arena_set_thread_budget(&a, 0))
	arena_borrow(&a)
	assert_equal(ARENA_ERR_BORROWED, arena_reset(&a))
	assert_equal(ARENA_ERR_BORROWED, arena_release(&a))
	assert_equal(ARENA_OK, arena_release_borrow(&a))
	assert_equal(ARENA_OK, arena_reset(&a))
	assert_equal(ARENA_OK, mem_shared_budget_snapshot(&b, &s))
	assert_equal(total, s.used)
	assert_equal(1, s.failures)
	assert_equal(ARENA_OK, arena_release(&a))
	assert_equal(ARENA_ERR_BUSY, mem_shared_budget_destroy(&b))
	assert_equal(ARENA_OK, arena_set_thread_budget(&a, 0))
	assert_equal(ARENA_OK, mem_shared_budget_destroy(&b))


struct shared_budget_worker_arg:
	mem_shared_budget* budget
	int* start
	int errors
	int refused


char* shared_budget_always_fail(void* context, int size):
	return 0


void shared_budget_stress_worker(void* context):
	shared_budget_worker_arg* arg = cast(shared_budget_worker_arg*, context)
	mem_shared_budget* b = arg.budget
	while (atomic_load(arg.start) == 0): th_yield()
	arena a
	arena_init(&a, 64, 0)
	if (arena_set_thread_budget(&a, b) != ARENA_OK): arg.errors = arg.errors + 1
	for i in range(6000):
		int size = 1 + (i % 31)
		int status = mem_shared_budget_reserve(b, size)
		if (status == ARENA_OK):
			mem_shared_budget_stats s
			if (mem_shared_budget_snapshot(b, &s) != ARENA_OK): arg.errors = arg.errors + 1
			if (s.used < size || s.used > s.limit || s.peak > s.limit): arg.errors = arg.errors + 1
			if (mem_shared_budget_release(b, size) != ARENA_OK): arg.errors = arg.errors + 1
		else if (status == ARENA_ERR_BUDGET): arg.refused = arg.refused + 1
		else: arg.errors = arg.errors + 1
		# Every worker also exercises its own arena against the same budget.
		char* p = 0
		status = arena_alloc(&a, 48, 1, &p)
		if (status == ARENA_OK):
			p[0] = 42
			if (arena_release(&a) != ARENA_OK): arg.errors = arg.errors + 1
		else if (status == ARENA_ERR_BUDGET): arg.refused = arg.refused + 1
		else: arg.errors = arg.errors + 1
		status = mem_shared_budget_alloc_with(b, 1, &p, shared_budget_always_fail, 0)
		if (status != ARENA_ERR_NO_MEMORY && status != ARENA_ERR_BUDGET): arg.errors = arg.errors + 1
		arg.refused = arg.refused + 1
		# Deterministic failure accounting while other workers hold bytes.
		if (mem_shared_budget_reserve(b, 257) != ARENA_ERR_BUDGET): arg.errors = arg.errors + 1
		arg.refused = arg.refused + 1
	if (arena_set_thread_budget(&a, 0) != ARENA_OK): arg.errors = arg.errors + 1
	if (mem_shared_budget_drop(b) != ARENA_OK): arg.errors = arg.errors + 1


void test_shared_budget_contention_coherent_accounting():
	mem_shared_budget b
	assert_equal(ARENA_OK, mem_shared_budget_init(&b, 256))
	int start = 0
	shared_budget_worker_arg[6] args
	wthread*[6] workers
	for i in range(6):
		args[i].budget = &b
		args[i].start = &start
		args[i].errors = 0
		args[i].refused = 0
		assert_equal(ARENA_OK, mem_shared_budget_retain(&b))
		workers[i] = thread_spawn(shared_budget_stress_worker, &args[i])
		assert1(workers[i] != 0)
	atomic_store(&start, 1)
	int refused = 0
	for i in range(6):
		assert_equal(0, thread_join(workers[i]))
		assert_equal(0, args[i].errors)
		refused = refused + args[i].refused
	mem_shared_budget_stats s
	assert_equal(ARENA_OK, mem_shared_budget_snapshot(&b, &s))
	assert_equal(0, s.used)
	assert_equal(0, s.users)
	assert1(s.peak > 0 && s.peak <= s.limit)
	assert_equal(refused, s.failures)
	assert_equal(0, s.release_errors)
	assert_equal(ARENA_OK, mem_shared_budget_destroy(&b))
