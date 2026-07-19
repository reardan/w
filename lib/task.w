/*
Single-threaded cooperative task runtime (docs/projects/async.md).

A task wraps a generator (lib/generator.w): its body runs on a private
64KB stack, and any plain function it calls can suspend the whole task
by filling the task's wait_* fields and switching back to the scheduler
with __w_gen_yield. The scheduler owns an event loop (lib/event_loop.w)
and translates wait requests into fd watches and timers; when one
fires, the task goes back on the ready queue and the next gen_next
resumes it exactly where it suspended.

Task bodies are ordinary generator declarations; the declared yield
type is unused (int by convention) and bodies must never execute a
plain 'yield' — the yield channel belongs to the runtime:

	generator int ticker(int n):
		int i = 0
		while (i < n):
			task_sleep_ms(10)
			i = i + 1
		task_finish(i)

	task_scheduler* s = task_scheduler_new()
	task* t = task_spawn(s, ticker(5))
	task_run(s)                        # 0, or negative errno / deadlock
	int n = task_result(t)
	task_scheduler_free(s)

Cancellation is cancellation-as-resume: task_cancel marks the task and
wakes it with -ECANCELED; every await returns that error immediately
from then on, so the body unwinds through its normal error paths and
frees what it owns. Suspended stacks are only reclaimed without running
(gen_free) for tasks still alive at task_scheduler_free.

Everything here assumes one thread: the current-task global, the
allocator, and the generator single-consumer rule all rely on it.
Awaits are only legal inside a task; buffers on the task stack must
respect the 64KB budget (prefer malloc for anything big).
*/
import lib.lib
import lib.assert
import lib.generator
import lib.poll
import lib.event_loop
import lib.container


int task_state_ready():
	return 0


int task_state_waiting_fd():
	return 1


int task_state_waiting_timer():
	return 2


int task_state_waiting_task():
	return 3


int task_state_done():
	return 4


# Errors delivered through awaits, negative-errno convention.
int task_err_cancelled():
	return -125 /* ECANCELED */


int task_err_timed_out():
	return -110 /* ETIMEDOUT */


int task_err_deadlock():
	return -35 /* EDEADLK */


struct task:
	generator* gen     # 0 once completed (object freed) or abandoned
	int state
	int wait_fd        # valid in waiting_fd
	int wait_events    #   poll mask to register
	int wait_ms        # sleep duration / fd timeout, -1 = none
	int wait_timer_id  # active sleep/timeout timer, 0 when none
	int wake_value     # delivered on resume: revents, 0, or an error
	int result         # completion value, set by task_finish
	int cancelled
	task* joiner       # task blocked in task_join on this one, 0 if none
	task* join_target  # task this one is blocked on (cancel bookkeeping)
	void* sched        # task_scheduler*, see task_sched


struct task_scheduler:
	event_loop* loop
	list[task*] ready  # task* queue, FIFO
	list[task*] tasks  # every spawned task, freed by task_scheduler_free
	int active_count   # tasks not yet done


# The running task, set around every resume. One thread, so a plain
# global is the whole "TLS" story.
task* task_active


task_scheduler* task_sched(task* t):
	return cast(task_scheduler*, t.sched)


# The task currently executing; only meaningful inside task code.
task* task_current():
	asserts(c"task_current() called outside a running task", cast(int, task_active) != 0)
	return task_active


void task_make_ready(task_scheduler* s, task* t):
	t.state = task_state_ready()
	s.ready.push(t)


# Event-loop callback: the fd a task waited on became ready. Fires at
# most once per suspension: the watch is removed here, and a pending
# timeout timer is cancelled so it cannot wake the task a second time.
void task_on_fd_event(int fd, int revents, void* context):
	task* t = cast(task*, context)
	task_scheduler* s = task_sched(t)
	event_loop_remove_fd(s.loop, fd)
	if (t.wait_timer_id != 0):
		event_loop_cancel_timer(s.loop, t.wait_timer_id)
		t.wait_timer_id = 0
	t.wake_value = revents
	task_make_ready(s, t)


# Event-loop callback for both sleeps and fd timeouts; the task's state
# tells them apart. One-shot timers deactivate before the callback runs,
# so no cancellation is needed here.
void task_on_timer(int timer_id, void* context):
	task* t = cast(task*, context)
	task_scheduler* s = task_sched(t)
	t.wait_timer_id = 0
	if (t.state == task_state_waiting_fd()):
		# Timeout beat readiness: stop watching the fd.
		event_loop_remove_fd(s.loop, t.wait_fd)
		t.wake_value = task_err_timed_out()
	else:
		t.wake_value = 0
	task_make_ready(s, t)


# The body returned or fell off the end: gen_next already unmapped its
# stack, so gen_free only releases the generator object here.
void task_complete(task_scheduler* s, task* t):
	t.state = task_state_done()
	s.active_count = s.active_count - 1
	gen_free(t.gen)
	t.gen = 0
	task* j = t.joiner
	t.joiner = 0
	if (cast(int, j) != 0):
		j.join_target = 0
		j.wake_value = t.result
		task_make_ready(s, j)


# Switch into the task until its next suspension or completion, then
# register whatever it asked to wait for.
void task_resume(task_scheduler* s, task* t):
	if (t.state == task_state_done()):
		return
	task* previous = task_active
	task_active = t
	int alive = gen_next(t.gen)
	task_active = previous
	if (alive == 0):
		task_complete(s, t)
		return
	if (t.state == task_state_waiting_fd()):
		event_loop_add_fd(s.loop, t.wait_fd, t.wait_events, task_on_fd_event, cast(void*, t))
		if (t.wait_ms >= 0):
			t.wait_timer_id = event_loop_add_timer(s.loop, t.wait_ms, task_on_timer, cast(void*, t))
	else if (t.state == task_state_waiting_timer()):
		t.wait_timer_id = event_loop_add_timer(s.loop, t.wait_ms, task_on_timer, cast(void*, t))
	else if (t.state == task_state_ready()):
		# task_yield_now: straight back onto the queue.
		s.ready.push(t)
	else if (t.state == task_state_waiting_task()):
		# Registered as the target's joiner; completion wakes it.
		return
	else:
		asserts(c"task suspended in an unknown wait state", 0)


task_scheduler* task_scheduler_new():
	task_scheduler* s = new task_scheduler()
	s.loop = event_loop_new()
	s.ready = new list[task*]
	s.tasks = new list[task*]
	s.active_count = 0
	return s


# Wrap a freshly created generator (the call expression creates it
# without running the body) as a task and queue it.
task* task_spawn(task_scheduler* s, generator* g):
	task* t = new task()
	t.gen = g
	t.state = task_state_ready()
	t.wait_fd = -1
	t.wait_events = 0
	t.wait_ms = -1
	t.wait_timer_id = 0
	t.wake_value = 0
	t.result = 0
	t.cancelled = 0
	t.joiner = 0
	t.join_target = 0
	t.sched = cast(void*, s)
	s.tasks.push(t)
	s.ready.push(t)
	s.active_count = s.active_count + 1
	return t


# Spawn onto the current task's scheduler; only legal inside a task.
task* task_go(generator* g):
	return task_spawn(task_sched(task_current()), g)


# Run until every spawned task completes. Returns 0, a negative errno
# from poll, or task_err_deadlock() when tasks remain but nothing can
# ever wake them (e.g. a join cycle).
int task_run(task_scheduler* s):
	while (s.active_count > 0):
		while (s.ready.length > 0):
			task* t = s.ready[0]
			list_remove_at[task*](s.ready, 0)
			task_resume(s, t)
		if (s.active_count == 0):
			return 0
		int watches = event_loop_active_count[event_watch*](s.loop, s.loop.watches)
		int timers = event_loop_active_count[event_timer*](s.loop, s.loop.timers)
		if ((watches == 0) && (timers == 0)):
			return task_err_deadlock()
		int fired = event_loop_run_once(s.loop, -1)
		if (fired < 0):
			return fired
	return 0


# Frees the scheduler and every task. A task still suspended (task_run
# returned early, or was never run to completion) is abandoned:
# gen_free reclaims its stack without running the body, so cleanup code
# after its suspension point does not execute — prefer cancelling and
# draining with task_run first.
void task_scheduler_free(task_scheduler* s):
	int i = 0
	while (i < s.tasks.length):
		task* t = s.tasks[i]
		if (cast(int, t.gen) != 0):
			gen_free(t.gen)
		free(cast(void*, t))
		i = i + 1
	list_free[task*](s.tasks)
	list_free[task*](s.ready)
	event_loop_free(s.loop)
	free(cast(void*, s))


/* Awaits. Only legal inside a task; each returns task_err_cancelled()
   immediately once the task has been cancelled. */


# Suspend until fd has one of events (a poll mask) or timeout_ms
# elapses. Returns the revents mask, task_err_timed_out(), or
# task_err_cancelled(). timeout_ms < 0 waits indefinitely.
int task_await_fd_timeout(int fd, int events, int timeout_ms):
	task* t = task_current()
	if (t.cancelled):
		return task_err_cancelled()
	t.state = task_state_waiting_fd()
	t.wait_fd = fd
	t.wait_events = events
	t.wait_ms = timeout_ms
	__w_gen_yield(t.gen, 0)
	t.wait_ms = -1
	return t.wake_value


int task_await_fd(int fd, int events):
	return task_await_fd_timeout(fd, events, -1)


# Suspend for ms milliseconds. Returns 0, or task_err_cancelled().
int task_sleep_ms(int ms):
	task* t = task_current()
	if (t.cancelled):
		return task_err_cancelled()
	t.state = task_state_waiting_timer()
	t.wait_ms = ms
	__w_gen_yield(t.gen, 0)
	t.wait_ms = -1
	return t.wake_value


# Reschedule behind every currently ready task without waiting on
# anything; the cooperative pressure valve for long computations.
# Returns 0, or task_err_cancelled().
int task_yield_now():
	task* t = task_current()
	if (t.cancelled):
		return task_err_cancelled()
	t.state = task_state_ready()
	t.wake_value = 0
	__w_gen_yield(t.gen, 0)
	return t.wake_value


# Record this task's completion value for task_result / task_join; the
# body still returns normally afterwards.
void task_finish(int value):
	task_current().result = value


int task_result(task* t):
	return t.result


int task_done(task* t):
	return t.state == task_state_done()


# Suspend until target completes and return its result. A task has at
# most one joiner; a second concurrent join fails with -EINVAL.
# Returns task_err_cancelled() when the *calling* task is cancelled.
int task_join(task* target):
	task* t = task_current()
	if (t.cancelled):
		return task_err_cancelled()
	if (target.state == task_state_done()):
		return target.result
	if (cast(int, target.joiner) != 0):
		return -22 /* EINVAL */
	target.joiner = t
	t.join_target = target
	t.state = task_state_waiting_task()
	__w_gen_yield(t.gen, 0)
	return t.wake_value


# Cancel a task: mark it, detach whatever it waits on, and wake it with
# task_err_cancelled() so its body unwinds through normal error paths
# (every subsequent await also returns the error immediately). The task
# still runs to completion; join it to observe that. Returns 1, or 0
# when the task was already done or already cancelled.
int task_cancel(task* t):
	if (t.state == task_state_done()):
		return 0
	if (t.cancelled):
		return 0
	t.cancelled = 1
	task_scheduler* s = task_sched(t)
	if (t.state == task_state_waiting_fd()):
		event_loop_remove_fd(s.loop, t.wait_fd)
		if (t.wait_timer_id != 0):
			event_loop_cancel_timer(s.loop, t.wait_timer_id)
			t.wait_timer_id = 0
		t.wake_value = task_err_cancelled()
		task_make_ready(s, t)
	else if (t.state == task_state_waiting_timer()):
		if (t.wait_timer_id != 0):
			event_loop_cancel_timer(s.loop, t.wait_timer_id)
			t.wait_timer_id = 0
		t.wake_value = task_err_cancelled()
		task_make_ready(s, t)
	else if (t.state == task_state_waiting_task()):
		if (cast(int, t.join_target) != 0):
			t.join_target.joiner = 0
			t.join_target = 0
		t.wake_value = task_err_cancelled()
		task_make_ready(s, t)
	# task_state_ready(): running or already queued — the flag alone
	# makes its next await return task_err_cancelled().
	return 1
