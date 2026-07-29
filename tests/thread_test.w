# wbuild: x64
import lib.testing
import lib.thread
import lib.time

/*
thread_spawn/thread_join (lib/thread.w): the argument reaches the
worker through the handoff protocol, join blocks on the done-word futex
instead of spinning, and CLONE_VM makes worker stores visible to the
joiner. The slow worker sleeps before publishing so the joiner really
parks in FUTEX_WAIT (a broken join would return early and read 0).

test_join_reclaims_stacks covers join-time reclamation: joined worker
stacks are munmapped (addresses get reused, address space stays flat)
and every spawn keeps succeeding where leaked 4MB stacks would exhaust
a 32-bit address space. The CLEARTID exit-wait is asserted by
construction: join munmaps only after the kernel clears t.exited, and
a premature munmap would segfault an exiting worker somewhere in the
1100 iterations rather than pass silently.
*/

int slow_result

int[8] worker_cells


void slow_worker(void* arg):
	sleep_ms(50)
	slow_result = cast(int, arg)


void cell_worker(void* arg):
	int i = cast(int, arg)
	worker_cells[i] = i * 10 + 7


void test_spawn_join_blocks():
	slow_result = 0
	wthread* t = thread_spawn(slow_worker, cast(void*, 1337))
	asserts(c"thread_spawn failed", cast(int, t) != 0)
	assert_equal(0, thread_join(t))
	# join returned only after the worker stored its argument
	assert_equal(1337, slow_result)


void test_spawn_many_join_reverse():
	int n = 4
	int i = 0
	while (i < 8):
		worker_cells[i] = 0 - 1
		i = i + 1
	wthread*[4] threads
	i = 0
	while (i < n):
		threads[i] = thread_spawn(cell_worker, cast(void*, i))
		asserts(c"thread_spawn failed", cast(int, threads[i]) != 0)
		i = i + 1
	# join in reverse spawn order: order must not matter
	i = n - 1
	while (i >= 0):
		assert_equal(0, thread_join(threads[i]))
		i = i - 1
	i = 0
	while (i < n):
		assert_equal(i * 10 + 7, worker_cells[i])
		i = i + 1


void test_join_null_handle():
	assert_equal(0 - 1, thread_join(cast(wthread*, 0)))


int reclaim_last


void reclaim_worker(void* arg):
	reclaim_last = cast(int, arg)


# Join-time reclamation (lib/thread.w): two independent assertions.
# - Every spawn succeeds: without the join-time munmap, 1100 4MB
#   stacks are 4.4GB of address space, more than any 32-bit process
#   has, so spawns would start failing partway through on the 32-bit
#   twin of this test.
# - The address space stays stable: freed stacks are reused, so the
#   distinct stack bases seen across 1100 workers stay a handful; a
#   leak would hand every worker a fresh base and overflow the table.
#   This is the load-bearing assertion on x64, where address space is
#   too plentiful for exhaustion to bite.
void test_join_reclaims_stacks():
	int[16] bases
	int distinct = 0
	int overflow = 0
	reclaim_last = 0
	int i = 0
	while (i < 1100):
		wthread* t = thread_spawn(reclaim_worker, cast(void*, i + 1))
		asserts(c"thread_spawn failed (stack leak?)", cast(int, t) != 0)
		int base = t.stack_base
		asserts(c"worker did not record its stack base", base != 0)
		int seen = 0
		int j = 0
		while (j < distinct):
			if (bases[j] == base):
				seen = 1
			j = j + 1
		if (seen == 0):
			if (distinct < 16):
				bases[distinct] = base
				distinct = distinct + 1
			else:
				overflow = 1
		assert_equal(0, thread_join(t))
		i = i + 1
	asserts(c"joined stacks were not reused", overflow == 0)
	# the last worker really ran with its argument
	assert_equal(1100, reclaim_last)
