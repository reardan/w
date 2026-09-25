# wbuild: x64
# Tests for the cooperative task runtime (lib/task.w): scheduling,
# suspension at arbitrary call depth, timers, fd wakeups, join,
# cancellation-as-resume, timeouts and deadlock detection.
import lib.testing
import lib.net
import lib.task
import lib.container
import lib.time
import lib.io_wait


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
	for i in range(rounds):
		log.entries.push(id)
		task_yield_now()


void test_yield_now_interleaves_tasks():
	task_scheduler* s = task_scheduler_new()
	order_log* log = new order_log(new list[int])
	task_spawn(s, yielding_pusher(log, 1, 3))
	task_spawn(s, yielding_pusher(log, 2, 3))
	assert_equal(0, task_run(s))
	assert_equal(6, log.entries.length)
	for i in range(6):
		# 1,2,1,2,1,2: strict alternation under FIFO scheduling.
		assert_equal(1 + (i & 1), log.entries[i])
	list_free[int](log.entries)
	free(cast(void*, log))
	task_scheduler_free(s)


/* Sleeps wake in deadline order, not spawn order. */

generator int sleep_then_push(order_log* log, int id, int ms):
	assert_equal(0, task_sleep_ms(ms))
	log.entries.push(id)


void test_sleeps_wake_in_deadline_order():
	task_scheduler* s = task_scheduler_new()
	order_log* log = new order_log(new list[int])
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
	for i in range(rounds):
		int revents = task_await_fd(fd, poll_in())
		asserts(c"ponger expected POLLIN", (revents & poll_in()) != 0)
		if (read(fd, buf, 1) == 1):
			received = received + 1
		assert_equal(1, write(fd, c"o", 1))
	free(buf)
	task_finish(received)


generator int pinger(int fd, int rounds):
	char* buf = malloc(4)
	int received = 0
	for i in range(rounds):
		assert_equal(1, write(fd, c"i", 1))
		int revents = task_await_fd(fd, poll_in())
		asserts(c"pinger expected POLLIN", (revents & poll_in()) != 0)
		if (read(fd, buf, 1) == 1):
			received = received + 1
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


/* Several tasks may join the same target; all get its result. */

generator int join_into(task* target, list[int] out):
	out.push(task_join(target))


void test_many_joiners_share_result():
	task_scheduler* s = task_scheduler_new()
	list[int] out = new list[int]
	task* target = task_spawn(s, sleep_fifty_finish_seven())
	task_spawn(s, join_into(target, out))
	task_spawn(s, join_into(target, out))
	task_spawn(s, join_into(target, out))
	assert_equal(0, task_run(s))
	assert_equal(3, out.length)
	assert_equal(7, out[0])
	assert_equal(7, out[2])
	list_free[int](out)
	task_scheduler_free(s)


generator int join_with_timeout(task* target, int ms):
	task_finish(task_join_timeout(target, ms))


void test_join_timeout_expires():
	task_scheduler* s = task_scheduler_new()
	task* target = task_spawn(s, sleep_fifty_finish_seven())
	task* joiner = task_spawn(s, join_with_timeout(target, 5))
	assert_equal(0, task_run(s))
	assert_equal(task_err_timed_out(), task_result(joiner))
	assert_equal(7, task_result(target))
	task_scheduler_free(s)


/* Deadlines bound every await in scope, however deep. */

int sleep_deep(int ms):
	return task_sleep_ms(ms)


generator int sleep_under_deadline(int deadline_ms, int sleep_ms):
	task_deadline_scope scope
	task_deadline_enter(&scope, deadline_ms)
	int r = sleep_deep(sleep_ms)
	# Once expired, every later await fails at once without parking.
	int again = task_yield_now()
	task_deadline_exit(&scope)
	# Outside the scope awaits work again.
	int after = task_yield_now()
	task_finish(r * 1000 + again * 10 + after)


void test_deadline_scope_bounds_awaits():
	task_scheduler* s = task_scheduler_new()
	task* t = task_spawn(s, sleep_under_deadline(5, 5000))
	int start = time_monotonic_ms()
	assert_equal(0, task_run(s))
	asserts(c"deadline did not cut the sleep short", (time_monotonic_ms() - start) < 1000)
	int e = task_err_timed_out()
	assert_equal(e * 1000 + e * 10, task_result(t))
	task_scheduler_free(s)


generator int nested_deadlines():
	task_deadline_scope outer
	task_deadline_scope inner
	task_deadline_enter(&outer, 10)
	# A later, longer inner scope cannot extend the outer deadline.
	task_deadline_enter(&inner, 10000)
	asserts(c"inner scope extended the deadline", task_deadline_remaining() <= 10)
	task_deadline_exit(&inner)
	task_deadline_exit(&outer)
	assert_equal(-1, task_deadline_remaining())
	# A sleep that ends before the deadline is unaffected.
	task_deadline_enter(&outer, 5000)
	int r = task_sleep_ms(1)
	task_deadline_exit(&outer)
	task_finish(r + 1)


void test_nested_deadlines():
	task_scheduler* s = task_scheduler_new()
	task* t = task_spawn(s, nested_deadlines())
	assert_equal(0, task_run(s))
	assert_equal(1, task_result(t))
	task_scheduler_free(s)


generator int child_sleeps_long():
	task_finish(task_sleep_ms(5000))


generator int parent_with_deadline(list[int] out):
	task_deadline_scope scope
	task_deadline_enter(&scope, 5)
	task* child = task_go(child_sleeps_long())
	task_deadline_exit(&scope)
	out.push(task_join(child))


void test_task_go_inherits_deadline():
	task_scheduler* s = task_scheduler_new()
	list[int] out = new list[int]
	task_spawn(s, parent_with_deadline(out))
	assert_equal(0, task_run(s))
	assert_equal(1, out.length)
	assert_equal(task_err_timed_out(), out[0])
	list_free[int](out)
	task_scheduler_free(s)


/* Task groups. */

generator int group_child(list[int] log, int id, int ms, int result):
	int r = task_sleep_ms(ms)
	if (r < 0):
		log.push(0 - id)
		task_finish(r)
		return
	log.push(id)
	task_finish(result)


generator int group_parent(list[int] log, int fail):
	task_group* g = task_group_here()
	task_group_spawn(g, group_child(log, 1, 30, 0))
	task_group_spawn(g, group_child(log, 2, 5, fail))
	task_group_spawn(g, group_child(log, 3, 10, 0))
	int r = task_group_wait(g)
	log.push(100)
	task_group_free(g)
	task_finish(r)


void test_group_waits_for_all_children():
	task_scheduler* s = task_scheduler_new()
	list[int] log = new list[int]
	task* parent = task_spawn(s, group_parent(log, 0))
	assert_equal(0, task_run(s))
	assert_equal(0, task_result(parent))
	assert_equal(4, log.length)
	assert_equal(2, log[0])
	assert_equal(3, log[1])
	assert_equal(1, log[2])
	assert_equal(100, log[3])
	# Group children are reclaimed as they finish.
	assert_equal(1, s.tasks.length)
	list_free[int](log)
	task_scheduler_free(s)


void test_group_first_error_cancels_siblings():
	task_scheduler* s = task_scheduler_new()
	list[int] log = new list[int]
	task* parent = task_spawn(s, group_parent(log, -5))
	int start = time_monotonic_ms()
	assert_equal(0, task_run(s))
	assert_equal(-5, task_result(parent))
	asserts(c"siblings were not cancelled", (time_monotonic_ms() - start) < 25)
	assert_equal(4, log.length)
	assert_equal(2, log[0])
	# Siblings saw cancellation (negative ids), in spawn order.
	assert_equal(-1, log[1])
	assert_equal(-3, log[2])
	assert_equal(100, log[3])
	list_free[int](log)
	task_scheduler_free(s)


generator int cancel_later(task* victim, int ms):
	task_sleep_ms(ms)
	task_cancel(victim)


void test_cancelling_group_waiter_cancels_children():
	task_scheduler* s = task_scheduler_new()
	list[int] log = new list[int]
	task* parent = task_spawn(s, group_parent(log, 0))
	task_spawn(s, cancel_later(parent, 7))
	assert_equal(0, task_run(s))
	assert_equal(task_err_cancelled(), task_result(parent))
	# Child 2 finished at 5ms; 3 and 1 were cancelled; the parent's
	# wait returned only after they unwound.
	assert_equal(4, log.length)
	assert_equal(2, log[0])
	assert_equal(-1, log[1])
	assert_equal(-3, log[2])
	assert_equal(100, log[3])
	list_free[int](log)
	task_scheduler_free(s)


generator int group_under_deadline(list[int] log):
	task_deadline_scope scope
	task_deadline_enter(&scope, 7)
	task_group* g = task_group_here()
	task_group_spawn(g, group_child(log, 1, 30, 0))
	task_group_spawn(g, group_child(log, 2, 5, 0))
	int r = task_group_wait(g)
	task_deadline_exit(&scope)
	task_group_free(g)
	task_finish(r)


void test_group_deadline_applies_to_children():
	task_scheduler* s = task_scheduler_new()
	list[int] log = new list[int]
	task* parent = task_spawn(s, group_under_deadline(log))
	assert_equal(0, task_run(s))
	assert_equal(task_err_timed_out(), task_result(parent))
	assert_equal(2, log.length)
	assert_equal(2, log[0])
	assert_equal(-1, log[1])
	list_free[int](log)
	task_scheduler_free(s)


/* Detached tasks are reclaimed when they finish. */

void test_detach_reclaims_task():
	task_scheduler* s = task_scheduler_new()
	task* a = task_spawn(s, finish_forty_two())
	task* b = task_spawn(s, sleep_fifty_finish_seven())
	task_detach(a)
	assert_equal(0, task_run(s))
	assert_equal(1, s.tasks.length)
	assert_equal(7, task_result(b))
	task_detach(b)
	assert_equal(0, s.tasks.length)
	task_scheduler_free(s)


/* A reader and a writer task can wait on the same descriptor. */

generator int read_n(int fd, int n):
	char* buf = malloc(n)
	int got = 0
	while (got < n):
		int r = read(fd, buf + got, n - got)
		if (r == -11):
			task_await_fd(fd, poll_in())
		else if (r <= 0):
			break
		else:
			got = got + r
	free(buf)
	task_finish(got)


generator int write_n(int fd, int n):
	char* buf = malloc(n)
	int sent = 0
	while (sent < n):
		int r = write(fd, buf + sent, n - sent)
		if (r == -11):
			task_await_fd(fd, poll_out())
		else if (r < 0):
			break
		else:
			sent = sent + r
	free(buf)
	task_finish(sent)


generator int echo_n(int fd, int n):
	char* buf = malloc(4096)
	int moved = 0
	while (moved < n):
		int r = read(fd, buf, 4096)
		if (r == -11):
			task_await_fd(fd, poll_in())
		else if (r <= 0):
			break
		else:
			int off = 0
			while (off < r):
				int w = write(fd, buf + off, r - off)
				if (w == -11):
					task_await_fd(fd, poll_out())
				else:
					off = off + w
			moved = moved + r
	free(buf)


void test_reader_and_writer_share_fd():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	socket_set_nonblocking(fds[0])
	socket_set_nonblocking(fds[1])
	int n = 1 << 20
	task_scheduler* s = task_scheduler_new()
	task* r = task_spawn(s, read_n(fds[0], n))
	task* w = task_spawn(s, write_n(fds[0], n))
	task_spawn(s, echo_n(fds[1], n))
	assert_equal(0, task_run(s))
	assert_equal(n, task_result(w))
	assert_equal(n, task_result(r))
	task_scheduler_free(s)
	close(fds[0])
	close(fds[1])
	free(fds)


/* Sized stacks: a recursion far deeper than the default 64KB. */

int burn_stack(int depth):
	char[256] pad
	pad[0] = 1
	pad[255] = 0
	if (depth == 0):
		task_yield_now()
		return 0
	return burn_stack(depth - 1) + pad[0] + pad[255]


generator int deep_recursion(int depth):
	task_finish(burn_stack(depth))


void test_spawn_sized_runs_deep_recursion():
	task_scheduler* s = task_scheduler_new()
	# ~1000 frames of 256+ bytes: well past 64KB, inside 1MB.
	task* t = task_spawn_sized(s, deep_recursion(1000), 1 << 20)
	assert_equal(0, task_run(s))
	assert_equal(1000, task_result(t))
	task_scheduler_free(s)


/* io_wait (lib/io_wait.w) suspends inside tasks, fails outside. */

generator int io_wait_reader(int fd):
	task_finish(io_wait(fd, poll_in(), 1000))


void test_io_wait_follows_context():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	task_scheduler* s = task_scheduler_new()
	assert_equal(-11, io_wait(fds[1], poll_in(), 1000))
	assert_equal(0, io_wait_available())
	task* t = task_spawn(s, io_wait_reader(fds[1]))
	task_spawn(s, sleep_then_write(fds[0]))
	assert_equal(0, task_run(s))
	asserts(c"io_wait did not report POLLIN", (task_result(t) & poll_in()) != 0)
	task_scheduler_free(s)
	close(fds[0])
	close(fds[1])
	free(fds)


/* task_dump lists live tasks. */

void test_task_dump_smoke():
	task_scheduler* s = task_scheduler_new()
	task* t = task_spawn(s, sleep_fifty_finish_seven())
	task_set_name(t, c"sleeper")
	int fd = open(c"/dev/null", 1, 0)
	task_dump_fd(s, fd)
	close(fd)
	assert_equal(0, task_run(s))
	task_scheduler_free(s)
