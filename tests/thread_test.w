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
