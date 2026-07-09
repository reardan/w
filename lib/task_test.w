# Tests for the cooperative task runtime (lib/task.w): scheduling,
# suspension at arbitrary call depth, timers, fd wakeups, join,
# cancellation-as-resume, timeouts and deadlock detection.
import lib.testing
import lib.net
import lib.task
import lib.container


/* A task completes and delivers its result. */

generator int finish_forty_two():
	task_finish(42)


void test_task_runs_to_completion():
	task_scheduler* s = task_scheduler_new()
	task* t = task_spawn(s, finish_forty_two())
	assert_equal(0, task_done(t))
	assert_equal(0, task_run(s))
	assert_equal(1, task_done(t))
	assert_equal(42, task_result(t))
	task_scheduler_free(s)


/* Suspension from plain functions at arbitrary call depth — the
   mechanism the whole runtime rests on. Neither helper is a
   generator; the suspension happens two frames below the body. */

int depth_two(int value):
	task_yield_now()
	return value + 1


int depth_one(int value):
	int r = depth_two(value)
	task_yield_now()
	return r + 10


generator int deep_suspender(int start):
	task_finish(depth_one(start))


void test_suspension_at_arbitrary_depth():
	task_scheduler* s = task_scheduler_new()
	task* t = task_spawn(s, deep_suspender(5))
	assert_equal(0, task_run(s))
	assert_equal(16, task_result(t))
	task_scheduler_free(s)


/* Two tasks alternate through task_yield_now: FIFO fairness. */

struct order_log:
	list[int] entries


generator int yielding_pusher(order_log* log, int id, int rounds):
	int i = 0
	while (i < rounds):
		log.entries.push(id)
		task_yield_now()
		i = i + 1


void test_yield_now_interleaves_tasks():
	task_scheduler* s = task_scheduler_new()
	order_log* log = new order_log()
	log.entries = new list[int]
	task_spawn(s, yielding_pusher(log, 1, 3))
	task_spawn(s, yielding_pusher(log, 2, 3))
	assert_equal(0, task_run(s))
	assert_equal(6, log.entries.length)
	int i = 0
	while (i < 6):
		# 1,2,1,2,1,2: strict alternation under FIFO scheduling.
		assert_equal(1 + (i & 1), log.entries[i])
		i = i + 1
	list_free[int](log.entries)
	free(cast(void*, log))
	task_scheduler_free(s)


/* Sleeps wake in deadline order, not spawn order. */

generator int sleep_then_push(order_log* log, int id, int ms):
	assert_equal(0, task_sleep_ms(ms))
	log.entries.push(id)


void test_sleeps_wake_in_deadline_order():
	task_scheduler* s = task_scheduler_new()
	order_log* log = new order_log()
	log.entries = new list[int]
	task_spawn(s, sleep_then_push(log, 1, 40))
	task_spawn(s, sleep_then_push(log, 2, 5))
	assert_equal(0, task_run(s))
	assert_equal(2, log.entries.length)
	assert_equal(2, log.entries[0])
	assert_equal(1, log.entries[1])
	list_free[int](log.entries)
	free(cast(void*, log))
	task_scheduler_free(s)


/* An fd wakeup: the reader suspends first, a slower writer wakes it. */

generator int await_then_read(int fd):
	int revents = task_await_fd(fd, poll_in())
	asserts(c"expected POLLIN", (revents & poll_in()) != 0)
	char* buf = malloc(8)
	int n = read(fd, buf, 8)
	assert_equal(4, n)
	free(buf)
	task_finish(n)


generator int sleep_then_write(int fd):
	assert_equal(0, task_sleep_ms(10))
	assert_equal(4, write(fd, c"ping", 4))


void test_await_fd_wakes_on_data():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	socket_set_nonblocking(fds[1])

	task_scheduler* s = task_scheduler_new()
	task* reader = task_spawn(s, await_then_read(fds[1]))
	task_spawn(s, sleep_then_write(fds[0]))
	assert_equal(0, task_run(s))
	assert_equal(4, task_result(reader))
	task_scheduler_free(s)
	close(fds[0])
	close(fds[1])
	free(fds)


/* Two tasks ping-pong bytes across a socketpair: each direction
   suspends on the other's writes, several rounds deep. */

generator int ponger(int fd, int rounds):
	char* buf = malloc(4)
	int received = 0
	int i = 0
	while (i < rounds):
		int revents = task_await_fd(fd, poll_in())
		asserts(c"ponger expected POLLIN", (revents & poll_in()) != 0)
		if (read(fd, buf, 1) == 1):
			received = received + 1
		assert_equal(1, write(fd, c"o", 1))
		i = i + 1
	free(buf)
	task_finish(received)


generator int pinger(int fd, int rounds):
	char* buf = malloc(4)
	int received = 0
	int i = 0
	while (i < rounds):
		assert_equal(1, write(fd, c"i", 1))
		int revents = task_await_fd(fd, poll_in())
		asserts(c"pinger expected POLLIN", (revents & poll_in()) != 0)
		if (read(fd, buf, 1) == 1):
			received = received + 1
		i = i + 1
	free(buf)
	task_finish(received)


void test_ping_pong_across_socketpair():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	socket_set_nonblocking(fds[0])
	socket_set_nonblocking(fds[1])

	task_scheduler* s = task_scheduler_new()
	task* a = task_spawn(s, ponger(fds[1], 5))
	task* b = task_spawn(s, pinger(fds[0], 5))
	assert_equal(0, task_run(s))
	assert_equal(5, task_result(a))
	assert_equal(5, task_result(b))
	task_scheduler_free(s)
	close(fds[0])
	close(fds[1])
	free(fds)


/* Join: result delivery from a still-running and an already-done task. */

generator int slow_hundred():
	assert_equal(0, task_sleep_ms(5))
	task_finish(100)


generator int join_and_double(task* target):
	int value = task_join(target)
	task_finish(value * 2)


void test_join_delivers_result():
	task_scheduler* s = task_scheduler_new()
	task* child = task_spawn(s, slow_hundred())
	task* parent = task_spawn(s, join_and_double(child))
	assert_equal(0, task_run(s))
	assert_equal(200, task_result(parent))
	task_scheduler_free(s)


void test_join_already_done_task():
	task_scheduler* s = task_scheduler_new()
	task* child = task_spawn(s, finish_forty_two())
	assert_equal(0, task_run(s))
	assert_equal(1, task_done(child))
	# Joining after completion returns the stored result immediately.
	task* parent = task_spawn(s, join_and_double(child))
	assert_equal(0, task_run(s))
	assert_equal(84, task_result(parent))
	task_scheduler_free(s)


/* task_go spawns onto the current scheduler from inside a task. */

generator int go_parent():
	task* child = task_go(finish_forty_two())
	task_finish(task_join(child) + 1)


void test_task_go_spawns_from_inside_a_task():
	task_scheduler* s = task_scheduler_new()
	task* parent = task_spawn(s, go_parent())
	assert_equal(0, task_run(s))
	assert_equal(43, task_result(parent))
	task_scheduler_free(s)


/* Cancellation-as-resume: the victim's await returns -ECANCELED and
   every later await fails fast; the body unwinds and completes. */

generator int sleep_forever_twice():
	int first = task_sleep_ms(100000)
	# Already cancelled: returns immediately instead of suspending.
	int second = task_sleep_ms(100000)
	assert_equal(first, second)
	task_finish(first)


generator int cancel_after_5ms(task* victim):
	assert_equal(0, task_sleep_ms(5))
	assert_equal(1, task_cancel(victim))
	# A second cancel is a no-op.
	assert_equal(0, task_cancel(victim))


void test_cancel_sleeping_task():
	task_scheduler* s = task_scheduler_new()
	task* victim = task_spawn(s, sleep_forever_twice())
	task_spawn(s, cancel_after_5ms(victim))
	assert_equal(0, task_run(s))
	assert_equal(1, task_done(victim))
	assert_equal(task_err_cancelled(), task_result(victim))
	task_scheduler_free(s)


generator int await_silent_fd(int fd):
	task_finish(task_await_fd(fd, poll_in()))


void test_cancel_task_waiting_on_fd():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	socket_set_nonblocking(fds[1])

	task_scheduler* s = task_scheduler_new()
	task* victim = task_spawn(s, await_silent_fd(fds[1]))
	task_spawn(s, cancel_after_5ms(victim))
	assert_equal(0, task_run(s))
	assert_equal(task_err_cancelled(), task_result(victim))
	task_scheduler_free(s)
	close(fds[0])
	close(fds[1])
	free(fds)


generator int join_task(task* target):
	task_finish(task_join(target))


generator int sleep_fifty_finish_seven():
	assert_equal(0, task_sleep_ms(50))
	task_finish(7)


void test_cancel_task_waiting_in_join():
	task_scheduler* s = task_scheduler_new()
	task* sleeper = task_spawn(s, sleep_fifty_finish_seven())
	task* victim = task_spawn(s, join_task(sleeper))
	task_spawn(s, cancel_after_5ms(victim))
	assert_equal(0, task_run(s))
	assert_equal(task_err_cancelled(), task_result(victim))
	# The join target is unaffected and completed normally.
	assert_equal(7, task_result(sleeper))
	task_scheduler_free(s)


/* Await timeouts: the timer path and the operation-wins path. */

generator int await_with_timeout(int fd, int timeout_ms):
	task_finish(task_await_fd_timeout(fd, poll_in(), timeout_ms))


void test_await_fd_timeout_fires():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	socket_set_nonblocking(fds[1])

	task_scheduler* s = task_scheduler_new()
	task* waiter = task_spawn(s, await_with_timeout(fds[1], 20))
	assert_equal(0, task_run(s))
	assert_equal(task_err_timed_out(), task_result(waiter))
	task_scheduler_free(s)
	close(fds[0])
	close(fds[1])
	free(fds)


void test_await_fd_timeout_operation_wins():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	socket_set_nonblocking(fds[1])
	assert_equal(4, write(fds[0], c"data", 4))

	task_scheduler* s = task_scheduler_new()
	task* waiter = task_spawn(s, await_with_timeout(fds[1], 1000))
	assert_equal(0, task_run(s))
	asserts(c"expected POLLIN before the timeout", (task_result(waiter) & poll_in()) != 0)
	task_scheduler_free(s)
	close(fds[0])
	close(fds[1])
	free(fds)


/* A join cycle can never make progress: task_run reports deadlock and
   task_scheduler_free reclaims the abandoned suspended stacks. */

struct deadlock_pair:
	task* a
	task* b


generator int join_peer(deadlock_pair* pair, int which):
	if (which == 0):
		task_join(pair.b)
	else:
		task_join(pair.a)


void test_join_cycle_reports_deadlock():
	task_scheduler* s = task_scheduler_new()
	deadlock_pair* pair = new deadlock_pair()
	pair.a = task_spawn(s, join_peer(pair, 0))
	pair.b = task_spawn(s, join_peer(pair, 1))
	assert_equal(task_err_deadlock(), task_run(s))
	assert_equal(0, task_done(pair.a))
	assert_equal(0, task_done(pair.b))
	free(cast(void*, pair))
	task_scheduler_free(s)
