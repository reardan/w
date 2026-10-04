# wbuild: x64
import lib.testing
import lib.arena


void test_arena_alloc_alignment_and_counters():
	arena a
	arena_init(&a, 256, 0)
	char* p = 0
	assert_equal(ARENA_OK, arena_alloc(&a, 3, 1, &p))
	asserts(c"first allocation", p != 0)
	char* q = 0
	assert_equal(ARENA_OK, arena_alloc(&a, 16, 16, &q))
	assert_equal(0, cast(int, q) & 15)
	assert1(cast(int, q) >= cast(int, p) + 3)
	char* z = 0
	assert_equal(ARENA_OK, arena_alloc(&a, 0, 1, &z))
	assert1(z != q)
	assert_equal(3, a.allocs)
	assert_equal(1, a.chunks)
	assert1(a.bytes_used >= 20)
	assert_equal(a.bytes_used, a.peak_used)
	assert_equal(ARENA_OK, arena_release(&a))
	assert_equal(0, a.chunks)
	assert_equal(0, a.reserved)


void test_arena_rejects_bad_arguments_without_allocating():
	arena a
	arena_init(&a, 256, 0)
	char* p = cast(char*, 1)
	assert_equal(ARENA_ERR_INVALID, arena_alloc(&a, -1, 8, &p))
	assert_equal(0, cast(int, p))
	assert_equal(ARENA_ERR_ALIGN, arena_alloc(&a, 8, 3, &p))
	assert_equal(ARENA_ERR_ALIGN, arena_alloc(&a, 8, 0, &p))
	assert_equal(ARENA_ERR_ALIGN, arena_alloc(&a, 8, 8192, &p))
	# Larger than any single request may be, and the word-limit edge
	# where size + alignment padding would wrap.
	assert_equal(ARENA_ERR_OVERFLOW, arena_alloc(&a, ARENA_MAX_REQUEST + 1, 8, &p))
	assert_equal(ARENA_ERR_OVERFLOW, arena_alloc(&a, arena_int_max(), 4096, &p))
	assert_equal(0, cast(int, p))
	assert_equal(6, a.alloc_failures)
	assert_equal(0, a.chunks)
	assert_equal(0, a.reserved)


void test_arena_checked_add():
	assert_equal(-1, arena_checked_add(arena_int_max(), 1))
	assert_equal(arena_int_max(), arena_checked_add(arena_int_max() - 1, 1))
	assert_equal(-1, arena_checked_add(-1, 1))


void test_arena_budget_exhaustion_is_a_status():
	arena a
	# Room for exactly two 128-byte chunks (headers included).
	int chunk_total = 128 + arena_chunk_header_size()
	arena_init(&a, 128, 2 * chunk_total)
	char* p = 0
	int ok = 0
	int status = ARENA_OK
	while (status == ARENA_OK):
		status = arena_alloc(&a, 100, 8, &p)
		if (status == ARENA_OK): ok = ok + 1
	assert_equal(ARENA_ERR_BUDGET, status)
	assert_equal(2, ok)
	assert_equal(2, a.chunks)
	assert_equal(1, a.alloc_failures)
	assert1(a.reserved <= a.budget)
	# A request bigger than the whole budget fails the same way.
	assert_equal(ARENA_ERR_BUDGET, arena_alloc(&a, 10000, 8, &p))
	arena_release(&a)


void test_arena_reset_refused_while_borrowed():
	arena* a = arena_new(256, 0)
	char* p = 0
	assert_equal(ARENA_OK, arena_alloc(a, 32, 8, &p))
	p[0] = 'x'
	arena_borrow(a)
	assert_equal(ARENA_ERR_BORROWED, arena_reset(a))
	assert_equal(ARENA_ERR_BORROWED, arena_release(a))
	assert_equal(ARENA_ERR_BORROWED, arena_free(a))
	# Nothing moved or was freed: the view is still intact.
	assert_equal('x', p[0])
	assert_equal(1, a.chunks)
	# Allocation while borrowed is fine (it never moves old objects).
	char* q = 0
	assert_equal(ARENA_OK, arena_alloc(a, 32, 8, &q))
	assert_equal(ARENA_OK, arena_release_borrow(a))
	assert_equal(ARENA_ERR_INVALID, arena_release_borrow(a))
	assert_equal(ARENA_OK, arena_reset(a))
	assert_equal(0, a.bytes_used)
	assert_equal(ARENA_OK, arena_free(a))


void test_arena_reset_drops_oversized_chunks():
	arena a
	arena_init(&a, 128, 0)
	arena_set_poison(&a, 1)
	char* p = 0
	assert_equal(ARENA_OK, arena_alloc(&a, 64, 8, &p))
	assert_equal(ARENA_OK, arena_alloc(&a, 5000, 8, &p))
	assert_equal(ARENA_OK, arena_alloc(&a, 100, 8, &p))
	assert_equal(3, a.chunks)
	assert_equal(ARENA_OK, arena_reset(&a))
	assert_equal(1, a.chunks)
	assert_equal(128 + arena_chunk_header_size(), a.reserved)
	assert_equal(1, a.resets)
	# Poisoned on reset: stale reads see the pattern, not old data.
	assert_equal(0xa5, arena_chunk_data(a.head)[0] & 255)
	arena_release(&a)


void test_mem_budget_shared_by_arenas():
	mem_budget b
	int chunk_total = 256 + arena_chunk_header_size()
	mem_budget_init(&b, 3 * chunk_total)
	arena x
	arena y
	arena_init(&x, 256, 0)
	arena_init(&y, 256, 0)
	assert_equal(ARENA_OK, arena_set_shared_budget(&x, &b))
	assert_equal(ARENA_OK, arena_set_shared_budget(&y, &b))
	char* p = 0
	assert_equal(ARENA_OK, arena_alloc(&x, 200, 8, &p))
	assert_equal(ARENA_OK, arena_alloc(&y, 200, 8, &p))
	assert_equal(ARENA_OK, arena_alloc(&x, 200, 8, &p))
	assert_equal(3 * chunk_total, b.used)
	assert_equal(ARENA_ERR_BUDGET, arena_alloc(&y, 200, 8, &p))
	assert_equal(1, b.failures)
	assert_equal(1, y.alloc_failures)
	assert_equal(ARENA_ERR_INVALID, arena_set_shared_budget(&x, 0))
	assert_equal(ARENA_OK, arena_release(&x))
	assert_equal(chunk_total, b.used)
	assert_equal(ARENA_OK, arena_alloc(&y, 200, 8, &p))
	arena_release(&y)
	assert_equal(0, b.used)
	assert_equal(3 * chunk_total, b.peak)
	# Plain allocations can be charged to the same budget.
	char* m = mem_budget_alloc(&b, 100)
	asserts(c"budgeted malloc", m != 0)
	assert_equal(0, cast(int, mem_budget_alloc(&b, 10 * chunk_total)))
	assert_equal(0, cast(int, mem_budget_alloc(&b, -5)))
	mem_budget_free(&b, m, 100)
	assert_equal(0, b.used)
	assert_equal(ARENA_ERR_INVALID, mem_budget_release(&b, 1))


# Resident set size in pages from /proc/self/statm (second field), or -1.
int arena_test_rss_pages():
	int fd = open(c"/proc/self/statm", 0, 0)
	if (fd < 0): return -1
	char* buf = malloc(128)
	int n = read(fd, buf, 127)
	close(fd)
	if (n <= 0):
		free(buf)
		return -1
	buf[n] = 0
	int i = 0
	while ((i < n) && (buf[i] != ' ')): i = i + 1
	int pages = atoi(buf + i + 1)
	free(buf)
	return pages


# Overload: every round allocates until the budget refuses, then resets.
# Memory held must not creep across rounds.
void test_arena_repeated_overload_keeps_memory_stable():
	arena a
	int budget = 64 * 1024
	arena_init(&a, 4096, budget)
	char* p = 0
	int baseline_rss = -1
	int round = 0
	while (round < 400):
		int status = ARENA_OK
		int size = 24
		while (status == ARENA_OK):
			status = arena_alloc(&a, size, 8, &p)
			if (status == ARENA_OK): p[0] = 1
			# Mix in oversized requests so dedicated chunks come and go.
			size = size + 97
			if (size > 6000): size = 24
		assert_equal(ARENA_ERR_BUDGET, status)
		assert1(a.reserved <= budget)
		assert_equal(ARENA_OK, arena_reset(&a))
		assert1(a.reserved <= 4096 + arena_chunk_header_size())
		if (round == 20): baseline_rss = arena_test_rss_pages()
		round = round + 1
	assert1(a.peak_reserved <= budget)
	assert_equal(400, a.alloc_failures)
	if (baseline_rss > 0):
		# Allow a little slack for unrelated heap noise (assert output etc.).
		assert1(arena_test_rss_pages() <= baseline_rss + 8)
	arena_release(&a)
