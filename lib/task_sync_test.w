# wbuild: x64
# Tests for task mutexes, semaphores and events (lib/task_sync.w).
import lib.testing
import lib.task
import lib.task_sync
import lib.container


/* A mutex held across awaits serializes critical sections. */

struct shared_counter:
	int value
	int inside
	int max_inside


shared_counter* shared_counter_new():
	shared_counter* c = new shared_counter()
	c.value = 0
	c.inside = 0
	c.max_inside = 0
	return c


generator int locked_increments(task_mutex* m, shared_counter* c, int rounds):
	int i = 0
	while (i < rounds):
		assert_equal(0, task_mutex_lock(m))
		c.inside = c.inside + 1
		if (c.inside > c.max_inside):
			c.max_inside = c.inside
		int v = c.value
		task_yield_now()
		c.value = v + 1
		c.inside = c.inside - 1
		task_mutex_unlock(m)
		i = i + 1


void test_mutex_serializes_across_awaits():
	task_scheduler* s = task_scheduler_new()
	task_mutex* m = task_mutex_new()
	shared_counter* c = shared_counter_new()
	int i = 0
	while (i < 5):
		task_spawn(s, locked_increments(m, c, 20))
		i = i + 1
	assert_equal(0, task_run(s))
	assert_equal(100, c.value)
	assert_equal(1, c.max_inside)
	assert_equal(0, m.locked)
	free(cast(void*, c))
	task_mutex_free(m)
	task_scheduler_free(s)


generator int lock_with_timeout(task_mutex* m, int ms):
	task_finish(task_mutex_lock_timeout(m, ms))


void test_mutex_lock_timeout():
	task_scheduler* s = task_scheduler_new()
	task_mutex* m = task_mutex_new()
	assert_equal(1, task_mutex_try_lock(m))
	task* t = task_spawn(s, lock_with_timeout(m, 5))
	assert_equal(0, task_run(s))
	assert_equal(task_err_timed_out(), task_result(t))
	task_mutex_unlock(m)
	assert_equal(0, m.locked)
	task_mutex_free(m)
	task_scheduler_free(s)


/* A semaphore bounds concurrency. */

generator int limited_work(task_semaphore* sem, shared_counter* c):
	assert_equal(0, task_semaphore_acquire(sem))
	c.inside = c.inside + 1
	if (c.inside > c.max_inside):
		c.max_inside = c.inside
	task_sleep_ms(1)
	c.inside = c.inside - 1
	c.value = c.value + 1
	task_semaphore_release(sem)


void test_semaphore_bounds_concurrency():
	task_scheduler* s = task_scheduler_new()
	task_semaphore* sem = task_semaphore_new(3)
	shared_counter* c = shared_counter_new()
	int i = 0
	while (i < 10):
		task_spawn(s, limited_work(sem, c))
		i = i + 1
	assert_equal(0, task_run(s))
	assert_equal(10, c.value)
	assert_equal(3, c.max_inside)
	assert_equal(3, sem.permits)
	free(cast(void*, c))
	task_semaphore_free(sem)
	task_scheduler_free(s)


/* An event releases every waiter at once. */

generator int wait_event(task_event* e, list[int] out, int id):
	assert_equal(0, task_event_wait(e))
	out.push(id)


generator int set_event_later(task_event* e, list[int] out):
	task_sleep_ms(2)
	out.push(0)
	task_event_set(e)


void test_event_wakes_all_waiters():
	task_scheduler* s = task_scheduler_new()
	task_event* e = task_event_new()
	list[int] out = new list[int]
	task_spawn(s, wait_event(e, out, 1))
	task_spawn(s, wait_event(e, out, 2))
	task_spawn(s, set_event_later(e, out))
	assert_equal(0, task_run(s))
	assert_equal(3, out.length)
	assert_equal(0, out[0])
	assert_equal(1, out[1])
	assert_equal(2, out[2])
	# Already set: waiting returns at once.
	task_spawn(s, wait_event(e, out, 3))
	assert_equal(0, task_run(s))
	assert_equal(4, out.length)
	list_free[int](out)
	task_event_free(e)
	task_scheduler_free(s)
