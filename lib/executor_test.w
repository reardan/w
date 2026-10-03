# wbuild: x64 timeout=60000
# Tests for the bounded blocking-work executor (lib/executor.w):
# saturation and byte limits, admission waits with deadlines,
# cancellation before and after dispatch, orderly shutdown in both
# modes, separate capacity classes, the event loop staying live while a
# slow job runs, and completions crossing task_runtime workers. Jobs
# block on gates the test opens, never on sleeps, so outcomes do not
# depend on timing.
import lib.testing
import lib.io
import lib.time
import lib.thread
import lib.task
import lib.task_runtime
import lib.executor
import lib.container


/* A gate: jobs count themselves in, then block until it opens. */

struct gate:
	int open
	int started
	int ran


gate* gate_new():
	return new gate(0, 0, 0)


void gate_open(gate* g):
	g.open = 1
	sys_futex(cast(int, &g.open), thread_futex_wake_op, 0x7fffffff, 0)


# Plain thread: block until at least n jobs have started.
void gate_wait_started(gate* g, int n):
	int seen = g.started
	while (seen < n):
		sys_futex(cast(int, &g.started), thread_futex_wait_op, seen, 0)
		seen = g.started


# Inside a task: poll (parking between checks) until n jobs started.
void gate_task_wait_started(gate* g, int n):
	while (g.started < n): task_sleep_ms(1)


int gated_job(void* p):
	gate* g = cast(gate*, p)
	atomic_add(&g.started, 1)
	sys_futex(cast(int, &g.started), thread_futex_wake_op, 0x7fffffff, 0)
	thread_wait_word(&g.open)
	atomic_add(&g.ran, 1)
	return 1


# Never blocks; records that it ran.
int counting_job(void* p):
	gate* g = cast(gate*, p)
	atomic_add(&g.ran, 1)
	return 5


/* Limits: workers + queue slots bound admitted jobs, costs bound bytes. */

void test_saturation_and_limits():
	executor* ex = executor_new(c"sat", 2, 2, 1000)
	gate* g = gate_new()
	executor_job** jobs = cast(executor_job**, malloc(4 * __word_size__))
	int i = 0
	while (i < 4):
		assert_equal(IO_OK, executor_try_submit(ex, gated_job, g, 100, &jobs[i]))
		i = i + 1
	executor_job* extra = 0
	assert_equal(EXEC_OVERLOADED, executor_try_submit(ex, gated_job, g, 100, &extra))
	asserts(c"a refused submit returns no handle", cast(int, extra) == 0)
	assert_equal(EXEC_TOO_LARGE, executor_try_submit(ex, gated_job, g, 1001, &extra))
	gate_wait_started(g, 2)
	executor_stats s
	executor_get_stats(ex, &s)
	assert_equal(2, s.running_jobs)
	assert_equal(2, s.workers)
	assert_equal(2, s.queued_jobs)
	assert_equal(200, s.queued_bytes)
	assert_equal(200, s.running_bytes)
	assert_equal(4, s.submitted)
	assert_equal(2, s.rejected)
	gate_open(g)
	i = 0
	while (i < 4):
		executor_result r
		assert_equal(IO_OK, executor_wait(jobs[i], &r))
		assert_equal(1, r.value)
		assert_equal(0, r.cancelled)
		i = i + 1
	executor_get_stats(ex, &s)
	assert_equal(4, s.completed)
	assert_equal(0, s.running_jobs + s.queued_jobs + s.queued_bytes + s.running_bytes)
	# Workers are reused, never more than max_workers.
	assert_equal(2, s.workers)
	free(cast(void*, jobs))
	executor_shutdown(ex, EXEC_DRAIN)
	executor_free(ex)
	free(cast(void*, g))


void test_byte_budget():
	executor* ex = executor_new(c"bytes", 2, 8, 100)
	gate* g = gate_new()
	executor_job* a = 0
	executor_job* b = 0
	executor_job* c = 0
	executor_job* d = 0
	assert_equal(IO_OK, executor_try_submit(ex, gated_job, g, 60, &a))
	assert_equal(EXEC_OVERLOADED, executor_try_submit(ex, gated_job, g, 50, &b))
	assert_equal(IO_OK, executor_try_submit(ex, gated_job, g, 40, &b))
	# Cost 0 pins nothing, so it fits even with the budget used up.
	assert_equal(IO_OK, executor_try_submit(ex, counting_job, g, 0, &c))
	assert_equal(EXEC_OVERLOADED, executor_try_submit(ex, gated_job, g, 1, &d))
	gate_open(g)
	executor_result r
	assert_equal(IO_OK, executor_wait(a, &r))
	assert_equal(IO_OK, executor_wait(b, &r))
	assert_equal(IO_OK, executor_wait(c, &r))
	assert_equal(5, r.value)
	# Completion released the budget.
	assert_equal(IO_OK, executor_try_submit(ex, counting_job, g, 100, &d))
	assert_equal(IO_OK, executor_wait(d, &r))
	executor_free(ex)
	free(cast(void*, g))


/* A plain thread waits for capacity with a timeout. */

void test_thread_admission_timeout():
	executor* ex = executor_new(c"thread", 1, 0, 1000)
	gate* g = gate_new()
	executor_job* a = 0
	assert_equal(IO_OK, executor_try_submit(ex, gated_job, g, 0, &a))
	executor_job* b = 0
	int t0 = time_monotonic_ms()
	assert_equal(IO_TIMED_OUT, executor_submit(ex, counting_job, g, 0, 20, &b))
	asserts(c"the timed wait returned early", (time_monotonic_ms() - t0) >= 15)
	executor_stats s
	executor_get_stats(ex, &s)
	assert_equal(1, s.wait_expired)
	assert_equal(0, s.waiting_submitters)
	gate_open(g)
	executor_result r
	assert_equal(IO_OK, executor_wait(a, &r))
	assert_equal(1, g.ran)
	executor_free(ex)
	free(cast(void*, g))


/* Shutdown: close admission, cancel or drain the queue, join. */

void test_shutdown_cancel_mode():
	executor* ex = executor_new(c"cancel", 1, 4, 1000)
	gate* g = gate_new()
	gate* other = gate_new()
	executor_job* a = 0
	executor_job* b = 0
	executor_job* c = 0
	assert_equal(IO_OK, executor_try_submit(ex, gated_job, g, 10, &a))
	gate_wait_started(g, 1)
	assert_equal(IO_OK, executor_try_submit(ex, counting_job, other, 10, &b))
	assert_equal(IO_OK, executor_try_submit(ex, counting_job, other, 10, &c))
	executor_close(ex, EXEC_CANCEL)
	executor_result r
	assert_equal(IO_CANCELLED, executor_wait(b, &r))
	assert_equal(IO_CANCELLED, executor_wait(c, &r))
	executor_job* d = 0
	assert_equal(EXEC_CLOSED, executor_try_submit(ex, counting_job, other, 0, &d))
	assert_equal(EXEC_CLOSED, executor_post(ex, counting_job, other, 0, -1))
	executor_stats s
	executor_get_stats(ex, &s)
	assert_equal(2, s.cancelled)
	assert_equal(0, s.queued_bytes)
	# The running job is not cancelled: join waits it out.
	gate_open(g)
	executor_join(ex)
	assert_equal(IO_OK, executor_wait(a, &r))
	assert_equal(1, r.value)
	assert_equal(0, other.ran)
	executor_get_stats(ex, &s)
	assert_equal(0, s.workers)
	executor_free(ex)
	free(cast(void*, g))
	free(cast(void*, other))


void test_shutdown_drain_mode():
	executor* ex = executor_new(c"drain", 1, 4, 1000)
	gate* g = gate_new()
	gate* other = gate_new()
	assert_equal(IO_OK, executor_post(ex, gated_job, g, 0, 0))
	gate_wait_started(g, 1)
	assert_equal(IO_OK, executor_post(ex, counting_job, other, 0, 0))
	assert_equal(IO_OK, executor_post(ex, counting_job, other, 0, 0))
	executor_close(ex, EXEC_DRAIN)
	assert_equal(EXEC_CLOSED, executor_post(ex, counting_job, other, 0, 0))
	gate_open(g)
	executor_join(ex)
	assert_equal(2, other.ran)
	executor_stats s
	executor_get_stats(ex, &s)
	assert_equal(3, s.completed)
	assert_equal(0, s.cancelled)
	executor_free(ex)
	free(cast(void*, g))
	free(cast(void*, other))


/* Shutdown from inside a task joins on a helper thread, so the loop
   keeps running (the gate only opens from a timer-driven task). */

generator int shutdown_in_task(executor* ex, gate* g, list[int] order):
	gate_task_wait_started(g, 1)
	executor_shutdown(ex, EXEC_DRAIN)
	order.push(2)


generator int open_after_ticks(gate* g, list[int] order):
	gate_task_wait_started(g, 1)
	int i = 0
	while (i < 5):
		task_sleep_ms(1)
		i = i + 1
	order.push(1)
	gate_open(g)


void test_shutdown_from_a_task():
	executor* ex = executor_new(c"task-shutdown", 1, 2, 1000)
	gate* g = gate_new()
	gate* other = gate_new()
	assert_equal(IO_OK, executor_post(ex, gated_job, g, 0, 0))
	assert_equal(IO_OK, executor_post(ex, counting_job, other, 0, 0))
	task_scheduler* sch = task_scheduler_new()
	list[int] order = new list[int]
	task_spawn(sch, shutdown_in_task(ex, g, order))
	task_spawn(sch, open_after_ticks(g, order))
	assert_equal(0, task_run(sch))
	assert_equal(2, order.length)
	assert_equal(1, order[0])
	assert_equal(2, order[1])
	# Drained: the queued job ran before the workers exited.
	assert_equal(1, other.ran)
	executor_dump_fd(ex, 2)
	list_free[int](order)
	task_scheduler_free(sch)
	executor_free(ex)
	free(cast(void*, g))
	free(cast(void*, other))


/* Tasks: admission waits park only the waiting task. */

struct outcome:
	int status
	int value
	int cancelled
	int after         # what the task's next await returned


void outcome_set(outcome* o, executor_result* r):
	o.status = r.status
	o.value = r.value
	o.cancelled = r.cancelled


outcome* outcome_new():
	return new outcome(-1, -1, -1, 0)


generator int run_into(executor* ex, executor_fn* func, gate* g, int timeout_ms, outcome* o):
	executor_result r
	executor_run(ex, func, g, 0, timeout_ms, &r)
	outcome_set(o, &r)


generator int open_when_done(task* waiting_for, gate* g):
	while (task_done(waiting_for) == 0): task_sleep_ms(1)
	gate_open(g)


generator int admission_driver(executor* ex, gate* g, task* timed, outcome* overloaded):
	# The short wait expires while the worker is still blocked; then a
	# second submitter queues up behind the full executor.
	while (task_done(timed) == 0): task_sleep_ms(1)
	executor_stats s
	executor_get_stats(ex, &s)
	while (s.waiting_submitters == 0):
		task_sleep_ms(1)
		executor_get_stats(ex, &s)
	# FIFO: a try-submit cannot jump ahead of a waiting submitter.
	executor_job* j = 0
	overloaded.status = executor_try_submit(ex, counting_job, g, 0, &j)
	gate_open(g)


void test_task_admission_waits():
	executor* ex = executor_new(c"admit", 1, 0, 1000)
	gate* g = gate_new()
	task_scheduler* sch = task_scheduler_new()
	outcome* first = outcome_new()
	outcome* timed = outcome_new()
	outcome* patient = outcome_new()
	outcome* tried = outcome_new()
	task_spawn(sch, run_into(ex, gated_job, g, -1, first))
	task* t = task_spawn(sch, run_into(ex, counting_job, g, 20, timed))
	task_spawn(sch, run_into(ex, counting_job, g, -1, patient))
	task_spawn(sch, admission_driver(ex, g, t, tried))
	assert_equal(0, task_run(sch))
	assert_equal(IO_OK, first.status)
	assert_equal(1, first.value)
	assert_equal(IO_TIMED_OUT, timed.status)
	assert_equal(EXEC_OVERLOADED, tried.status)
	assert_equal(IO_OK, patient.status)
	assert_equal(5, patient.value)
	# The gated job and the patient one ran; the timed-out one never did.
	assert_equal(2, g.ran)
	executor_stats s
	executor_get_stats(ex, &s)
	assert_equal(1, s.wait_expired)
	assert_equal(1, s.rejected)
	task_scheduler_free(sch)
	executor_free(ex)
	free(cast(void*, g))


/* Cancellation before dispatch removes the job: it never runs. */

generator int cancel_when_queued(executor* ex, task* victim, gate* g):
	executor_stats s
	executor_get_stats(ex, &s)
	while (s.queued_jobs == 0):
		task_sleep_ms(1)
		executor_get_stats(ex, &s)
	task_cancel(victim)
	while (task_done(victim) == 0): task_sleep_ms(1)
	gate_open(g)


generator int run_with_deadline(executor* ex, gate* g, int ms, outcome* o):
	task_deadline_scope scope
	task_deadline_enter(&scope, ms)
	executor_result r
	executor_run(ex, counting_job, g, 0, -1, &r)
	task_deadline_exit(&scope)
	outcome_set(o, &r)


void test_cancel_before_dispatch():
	executor* ex = executor_new(c"queued", 1, 4, 1000)
	gate* g = gate_new()
	gate* victim_gate = gate_new()
	task_scheduler* sch = task_scheduler_new()
	outcome* first = outcome_new()
	outcome* victim = outcome_new()
	task_spawn(sch, run_into(ex, gated_job, g, -1, first))
	assert_equal(0, task_run_once(sch, 0))
	gate_wait_started(g, 1)
	task* v = task_spawn(sch, run_into(ex, counting_job, victim_gate, -1, victim))
	task_spawn(sch, cancel_when_queued(ex, v, g))
	assert_equal(0, task_run(sch))
	assert_equal(IO_OK, first.status)
	assert_equal(IO_CANCELLED, victim.status)
	assert_equal(0, victim_gate.ran)
	executor_stats s
	executor_get_stats(ex, &s)
	assert_equal(1, s.cancelled)
	assert_equal(0, s.queued_jobs)
	# A deadline that expires while queued works the same way.
	gate* g2 = gate_new()
	outcome* late = outcome_new()
	task_spawn(sch, run_into(ex, gated_job, g2, -1, first))
	assert_equal(0, task_run_once(sch, 0))
	gate_wait_started(g2, 1)
	task* d = task_spawn(sch, run_with_deadline(ex, victim_gate, 10, late))
	task_spawn(sch, open_when_done(d, g2))
	assert_equal(0, task_run(sch))
	assert_equal(IO_TIMED_OUT, late.status)
	assert_equal(0, victim_gate.ran)
	executor_get_stats(ex, &s)
	assert_equal(2, s.cancelled)
	task_scheduler_free(sch)
	executor_free(ex)
	free(cast(void*, g))
	free(cast(void*, g2))
	free(cast(void*, victim_gate))


/* Cancellation after dispatch: the wait stays shielded until the job
   returns, so the job may keep writing into the waiter's stack. */

struct stack_request:
	gate* g
	int* words        # 16 words on the waiting task's stack
	int written


int fill_request(void* p):
	stack_request* req = cast(stack_request*, p)
	gated_job(cast(void*, req.g))
	int i = 0
	while (i < 16):
		req.words[i] = i * 3
		i = i + 1
	req.written = 1
	return 42


generator int run_on_stack(executor* ex, gate* g, outcome* o, list[int] seen):
	int[16] words
	stack_request req
	req.g = g
	req.words = &words[0]
	req.written = 0
	executor_result r
	executor_run(ex, fill_request, &req, 0, -1, &r)
	outcome_set(o, &r)
	int sum = 0
	int i = 0
	while (i < 16):
		sum = sum + words[i]
		i = i + 1
	seen.push(req.written)
	seen.push(sum)
	o.after = task_sleep_ms(1)


generator int cancel_while_running(task* victim, gate* g, list[int] seen):
	gate_task_wait_started(g, 1)
	task_cancel(victim)
	# The victim stays parked however long the job takes.
	int i = 0
	while (i < 5):
		task_sleep_ms(1)
		seen.push(task_done(victim))
		i = i + 1
	gate_open(g)


void test_cancel_after_dispatch():
	executor* ex = executor_new(c"running", 1, 1, 1000)
	gate* g = gate_new()
	task_scheduler* sch = task_scheduler_new()
	outcome* o = outcome_new()
	list[int] seen = new list[int]
	list[int] done_while_running = new list[int]
	task* v = task_spawn(sch, run_on_stack(ex, g, o, seen))
	task_spawn(sch, cancel_while_running(v, g, done_while_running))
	assert_equal(0, task_run(sch))
	assert_equal(IO_OK, o.status)
	assert_equal(42, o.value)
	assert_equal(1, o.cancelled)
	assert_equal(task_err_cancelled(), o.after)
	assert_equal(1, seen[0])
	# 3 * (0 + 1 + ... + 15)
	assert_equal(360, seen[1])
	assert_equal(5, done_while_running.length)
	for int d in done_while_running: assert_equal(0, d)
	executor_stats s
	executor_get_stats(ex, &s)
	assert_equal(0, s.cancelled)
	assert_equal(1, s.completed)
	list_free[int](seen)
	list_free[int](done_while_running)
	task_scheduler_free(sch)
	executor_free(ex)
	free(cast(void*, g))


/* The event loop keeps running while a slow job blocks a worker: the
   job can only finish after timers on the loop fired. */

generator int ticker_then_open(gate* g, list[int] ticks):
	gate_task_wait_started(g, 1)
	while (ticks.length < 10):
		task_sleep_ms(1)
		ticks.push(1)
	gate_open(g)


struct sync_request:
	char* path
	int rounds


# A deliberately slow job: write and fsync a scratch file repeatedly.
int fsync_loop(void* p):
	sync_request* req = cast(sync_request*, p)
	# O_WRONLY|O_CREAT|O_TRUNC
	int fd = open(req.path, 577, 420)
	if (fd < 0): return fd
	char* block = malloc(4096)
	int i = 0
	while (i < 4096):
		block[i] = 'w'
		i = i + 1
	int status = 0
	i = 0
	while ((i < req.rounds) && (status == 0)):
		if (write(fd, block, 4096) != 4096): status = -5
		else if (fsync(fd) != 0): status = -5
		i = i + 1
	free(block)
	close(fd)
	unlink(req.path)
	return status


generator int run_fsync(executor* ex, sync_request* req, outcome* o):
	executor_result r
	executor_run(ex, fsync_loop, req, 4096, -1, &r)
	outcome_set(o, &r)


generator int tick_until(task* t, list[int] ticks):
	while (task_done(t) == 0):
		task_sleep_ms(1)
		ticks.push(1)


void test_event_loop_stays_live():
	executor* ex = executor_new(c"slow", 1, 4, 65536)
	gate* g = gate_new()
	task_scheduler* sch = task_scheduler_new()
	outcome* slow = outcome_new()
	list[int] ticks = new list[int]
	task_spawn(sch, run_into(ex, gated_job, g, -1, slow))
	task_spawn(sch, ticker_then_open(g, ticks))
	assert_equal(0, task_run(sch))
	assert_equal(IO_OK, slow.status)
	assert_equal(10, ticks.length)
	# A real slow sync: the loop keeps ticking while it runs.
	sync_request* req = new sync_request(c"bin/executor_test_32.tmp", 20)
	if (__word_size__ == 8): req.path = c"bin/executor_test_64.tmp"
	outcome* synced = outcome_new()
	list[int] sync_ticks = new list[int]
	task* t = task_spawn(sch, run_fsync(ex, req, synced))
	task_spawn(sch, tick_until(t, sync_ticks))
	assert_equal(0, task_run(sch))
	assert_equal(IO_OK, synced.status)
	assert_equal(0, synced.value)
	asserts(c"no timer ran during the fsync job", sync_ticks.length >= 1)
	free(cast(void*, req))
	list_free[int](ticks)
	list_free[int](sync_ticks)
	task_scheduler_free(sch)
	executor_free(ex)
	free(cast(void*, g))


/* Capacity classes: a saturated maintenance executor does not delay
   latency-sensitive work submitted to a separate executor. */

generator int sync_while_maintenance_blocked(executor* sync_ex, executor* maint, gate* g, list[int] results):
	gate_task_wait_started(g, 1)
	gate* counted = gate_new()
	# maintenance: 1 running + 1 queued, so it is full.
	results.push(executor_post(maint, counting_job, counted, 0, 0))
	results.push(executor_post(maint, counting_job, counted, 0, 0))
	int i = 0
	while (i < 3):
		executor_result r
		results.push(executor_run(sync_ex, counting_job, counted, 0, 100, &r))
		i = i + 1
	results.push(counted.ran)
	gate_open(g)


void test_capacity_classes():
	executor* maint = executor_new(c"maintenance", 1, 1, 1000)
	executor* sync_ex = executor_new(c"sync", 1, 4, 1000)
	gate* g = gate_new()
	task_scheduler* sch = task_scheduler_new()
	outcome* long_job = outcome_new()
	list[int] results = new list[int]
	task_spawn(sch, run_into(maint, gated_job, g, -1, long_job))
	task_spawn(sch, sync_while_maintenance_blocked(sync_ex, maint, g, results))
	assert_equal(0, task_run(sch))
	assert_equal(IO_OK, long_job.status)
	assert_equal(IO_OK, results[0])
	assert_equal(EXEC_OVERLOADED, results[1])
	assert_equal(IO_OK, results[2])
	assert_equal(IO_OK, results[3])
	assert_equal(IO_OK, results[4])
	# All three sync jobs finished while maintenance was still blocked.
	assert_equal(3, results[5])
	list_free[int](results)
	task_scheduler_free(sch)
	executor_free(sync_ex)
	executor_free(maint)
	free(cast(void*, g))


/* Completions cross threads: tasks on several runtime workers share
   one small executor and wait for capacity. */

struct rt_totals:
	int ok
	int sum


int sum_to(void* p):
	int n = cast(int, p)
	int total = 0
	for i in range(1, n + 1): total = total + i
	return total


generator int rt_submitter(executor* ex, rt_totals* totals, int n):
	executor_result r
	if (executor_run(ex, sum_to, cast(void*, n), 8, -1, &r) == IO_OK):
		atomic_add(&totals.ok, 1)
		atomic_add(&totals.sum, r.value)


void test_runtime_workers_share_an_executor():
	executor* ex = executor_new(c"shared", 2, 2, 1000)
	task_runtime* rt = task_runtime_new(3)
	rt_totals* totals = new rt_totals(0, 0)
	int expect = 0
	for n in range(1, 61):
		task_runtime_spawn(rt, rt_submitter(ex, totals, n))
		expect = expect + n * (n + 1) / 2
	assert_equal(0, task_runtime_run(rt))
	assert_equal(60, totals.ok)
	assert_equal(expect, totals.sum)
	executor_stats s
	executor_get_stats(ex, &s)
	assert_equal(60, s.completed)
	assert_equal(0, s.rejected)
	asserts(c"more workers than the limit", s.workers <= 2)
	free(cast(void*, totals))
	task_runtime_free(rt)
	executor_free(ex)
