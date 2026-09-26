/*
Cooperative task runtime (docs/projects/async.md).

A task wraps a generator (lib/generator.w): its body runs on a private
stack, and any plain function it calls can suspend the whole task by
parking it and switching back to the scheduler with __w_gen_yield. The
scheduler owns an event loop (lib/event_loop.w); fd readiness, timers
and wait queues (channels, locks, joins, groups) wake parked tasks,
which go back on the ready queue and resume exactly where they parked.

Task bodies are ordinary generator declarations; the declared yield
type is unused (int by convention) and bodies must never execute a
plain 'yield' -- the yield channel belongs to the runtime:

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

Every await returns a value or a negative errno. Cancellation is
cancellation-as-resume: task_cancel marks the task and wakes it with
-ECANCELED; every await fails the same way from then on, so the body
unwinds through its normal error paths (and defer) and frees what it
owns. Deadlines work the same way with -ETIMEDOUT: a task_deadline
scope bounds every await inside it, however deep in the call chain.

Structured concurrency: a task_group owns the tasks spawned into it.
task_group_wait returns once all of them finished; the first child
that fails cancels its siblings, and cancelling the waiting task
cancels the whole group before the wait returns. Channels, locks and
select live in lib/task_chan.w and lib/task_sync.w on top of the wait
queues defined here.

Threads: one scheduler belongs to one thread. The current task is a
plain global unless lib/task_runtime.w installs thread-local accessors
(one scheduler per worker thread there). Awaits are only legal inside a
task; buffers on the task stack must respect its size (64KB by default,
task_spawn_sized for more; a guard page turns overflow into a fault).
*/
import lib.lib
import lib.assert
import lib.generator
import lib.poll
import lib.time
import lib.event_loop
import lib.io_wait
import lib.container
import structures.deque


const int task_state_ready = 0
const int task_state_waiting_fd = 1
const int task_state_waiting_timer = 2
const int task_state_waiting_task = 3
const int task_state_done = 4


# Parked on one or more wait queues (channel, lock, event, group).
const int task_state_waiting_queue = 5


# Parked until another thread wakes it (task_spawn_blocking).
const int task_state_waiting_external = 6


# Errors delivered through awaits, negative-errno convention.
int task_err_cancelled():
	return -125 /* ECANCELED */


int task_err_timed_out():
	return -110 /* ETIMEDOUT */


int task_err_deadlock():
	return -35 /* EDEADLK */


# A channel operation on a closed channel.
int task_err_closed():
	return -32 /* EPIPE */


# A non-blocking operation that would have had to wait.
int task_err_would_block():
	return -11 /* EAGAIN */


# One registration of a parked task on a wait queue. Waiters live in
# memory owned by the parked task (its stack, or a select's array) and
# are unlinked from every queue before the task resumes.
struct task_waiter:
	task_waiter* prev
	task_waiter* next
	void* queue              # task_wait_queue*, 0 when not linked
	void* owner              # task*
	int value                # payload word: value to send / value received
	int status               # 0 pending, 1 completed, 2 queue closed


struct task_wait_queue:
	task_waiter* head
	task_waiter* tail


# Values for task_waiter.status.
const int task_waiter_pending = 0
const int task_waiter_completed = 1
const int task_waiter_closed = 2


struct task:
	generator* gen     # 0 once completed (object freed) or abandoned
	int state
	int id
	char* name         # optional label for task_dump, not owned
	int wait_fd        # valid in waiting_fd
	int wait_events    #   poll mask registered
	event_watch* wait_watch    # active fd watch while parked, 0 otherwise
	int wait_timer_id  # active timeout timer while parked, 0 when none
	int timer_value    # what that timer delivers when it fires
	task_waiter* wait_one      # single-queue registration while parked
	task_waiter** wait_many    # select: wait_count registrations
	int wait_count
	int wake_value     # delivered on resume: revents, 0, a value or an error
	int result         # completion value, set by task_finish
	int cancelled
	int shielded       # parks ignore cancellation and deadlines
	int has_deadline
	int deadline_ms    # absolute time_monotonic_ms, valid with has_deadline
	int park_seq       # bumped on every park; remote wakers must match it
	int detached       # freed as soon as it completes
	int slot           # index in the scheduler's task list
	task_wait_queue* joiners   # tasks blocked in task_join, 0 until first join
	void* group        # task_group* that owns it, 0 if none
	void* sched        # task_scheduler*, see task_sched


# Called after a task completes (lib/task_runtime.w counts outstanding
# work across threads with it). Arguments: the task and the context.
type task_done_cb = fn(task*, void*) -> void


struct task_scheduler:
	event_loop* loop
	deque[task*]* ready    # FIFO run queue
	list[task*] tasks      # live (not yet reclaimed) tasks
	int active_count       # tasks not yet done
	int next_id
	task_done_cb* on_done  # optional completion hook
	void* on_done_context
	task_done_cb* on_spawn # optional hook, called for every new task
	void* on_spawn_context
	void* remote           # lib/task_runtime.w inbox, 0 if none


/* The current task. One thread by default; lib/task_runtime.w swaps in
   thread-local accessors so every worker thread has its own. */

task* task_active


type task_active_get_fn = fn() -> void*


type task_active_set_fn = fn(void*) -> void


task_active_get_fn* task_active_get_hook
task_active_set_fn* task_active_set_hook


task* task_active_get():
	if (cast(int, task_active_get_hook) != 0): return cast(task*, task_active_get_hook())
	return task_active


void task_active_set(task* t):
	if (cast(int, task_active_set_hook) != 0):
		task_active_set_hook(cast(void*, t))
		return
	task_active = t


task_scheduler* task_sched(task* t):
	return cast(task_scheduler*, t.sched)


# The task currently executing; only meaningful inside task code.
task* task_current():
	task* t = task_active_get()
	asserts(c"task_current() called outside a running task", cast(int, t) != 0)
	return t


# 1 when called from inside a running task.
int task_in_task():
	return cast(int, task_active_get()) != 0


/* Wait queues: intrusive doubly linked lists of task_waiter. */

void task_wait_queue_init(task_wait_queue* q):
	q.head = 0
	q.tail = 0


task_wait_queue* task_wait_queue_new():
	task_wait_queue* q = new task_wait_queue()
	task_wait_queue_init(q)
	return q


int task_wait_queue_empty(task_wait_queue* q):
	return cast(int, q.head) == 0


task_waiter* task_wait_queue_first(task_wait_queue* q):
	return q.head


void task_waiter_init(task_waiter* w, task* owner):
	w.prev = 0
	w.next = 0
	w.queue = 0
	w.owner = cast(void*, owner)
	w.value = 0
	w.status = task_waiter_pending


void task_waiter_link(task_wait_queue* q, task_waiter* w):
	w.queue = cast(void*, q)
	w.next = 0
	w.prev = q.tail
	if (cast(int, q.tail) != 0): q.tail.next = w
	else: q.head = w
	q.tail = w


void task_waiter_unlink(task_waiter* w):
	task_wait_queue* q = cast(task_wait_queue*, w.queue)
	if (cast(int, q) == 0): return
	if (cast(int, w.prev) != 0): w.prev.next = w.next
	else: q.head = w.next
	if (cast(int, w.next) != 0): w.next.prev = w.prev
	else: q.tail = w.prev
	w.prev = 0
	w.next = 0
	w.queue = 0


void task_make_ready(task_scheduler* s, task* t):
	t.state = task_state_ready
	deque_push_back[task*](s.ready, t)


# Undo every registration of a parked task: fd watch, timer, waiters.
void task_unpark(task* t):
	task_scheduler* s = task_sched(t)
	if (cast(int, t.wait_watch) != 0):
		event_loop_remove_watch(s.loop, t.wait_watch)
		t.wait_watch = 0
	if (t.wait_timer_id != 0):
		event_loop_cancel_timer(s.loop, t.wait_timer_id)
		t.wait_timer_id = 0
	if (cast(int, t.wait_one) != 0):
		task_waiter_unlink(t.wait_one)
		t.wait_one = 0
	int i = 0
	while (i < t.wait_count):
		task_waiter_unlink(t.wait_many[i])
		i = i + 1
	t.wait_many = 0
	t.wait_count = 0


int task_is_parked(task* t):
	return (t.state != task_state_ready) && (t.state != task_state_done)


# Wake a parked task with value (what its await returns). Returns 1, or
# 0 when the task was not parked (already woken, running or done).
int task_wake(task* t, int value):
	if (task_is_parked(t) == 0): return 0
	task_unpark(t)
	t.wake_value = value
	task_make_ready(task_sched(t), t)
	return 1


# Complete a waiter taken off a queue: record status and wake its owner
# with value.
void task_waiter_fire(task_waiter* w, int status, int value):
	task_waiter_unlink(w)
	w.status = status
	task_wake(cast(task*, w.owner), value)


# Fire every waiter on q (queue closed, event set, group finished).
void task_wait_queue_fire_all(task_wait_queue* q, int status, int value):
	while (cast(int, q.head) != 0): task_waiter_fire(q.head, status, value)


/* Event-loop callbacks. Each fires at most once per park: task_wake
   unregisters everything else the task was waiting on. */

void task_on_fd_event(int fd, int revents, void* context):
	task* t = cast(task*, context)
	task_wake(t, revents)


void task_on_timer(int timer_id, void* context):
	task* t = cast(task*, context)
	# One-shot timers deactivate before their callback runs.
	t.wait_timer_id = 0
	task_wake(t, t.timer_value)


/* Parking. An await checks task_park_check first, registers what it
   waits on (fd watch, waiters), then calls task_park. */

# The error an await must return without parking: cancellation or an
# expired deadline. 0 when the await may park.
int task_park_check(task* t):
	if (t.shielded): return 0
	if (t.cancelled): return task_err_cancelled()
	if (t.has_deadline):
		if ((t.deadline_ms - time_monotonic_ms()) <= 0): return task_err_timed_out()
	return 0


# Suspend t (the running task) in state until something wakes it.
# timeout_ms >= 0 arms a timer that wakes it with timeout_value; the
# task's deadline, when nearer, arms it with -ETIMEDOUT instead.
# Returns the wake value.
int task_park(task* t, int state, int timeout_ms, int timeout_value):
	int delay = timeout_ms
	int value = timeout_value
	if ((t.shielded == 0) && t.has_deadline):
		int remaining = t.deadline_ms - time_monotonic_ms()
		if (remaining < 0): remaining = 0
		if ((delay < 0) || (remaining < delay)):
			delay = remaining
			value = task_err_timed_out()
	if (delay >= 0):
		t.timer_value = value
		t.wait_timer_id = event_loop_add_timer(task_sched(t).loop, delay, task_on_timer, cast(void*, t))
	t.state = state
	t.park_seq = t.park_seq + 1
	__w_gen_yield(t.gen, 0)
	return t.wake_value


# Park the current task on one wait queue. Returns the wake value; the
# waiter's status says whether a peer completed the operation.
int task_park_on(task_wait_queue* q, task_waiter* w, int timeout_ms):
	task* t = task_current()
	task_waiter_link(q, w)
	t.wait_one = w
	return task_park(t, task_state_waiting_queue, timeout_ms, task_err_timed_out())


/* Scheduler. */

void task_reclaim(task_scheduler* s, task* t):
	int last = s.tasks.length - 1
	task* moved = s.tasks[last]
	s.tasks[t.slot] = moved
	moved.slot = t.slot
	list_remove_at[task*](s.tasks, last)
	if (cast(int, t.joiners) != 0): free(cast(void*, t.joiners))
	free(cast(void*, t))


type task_group_done_fn = fn(void*, task*) -> void


# Installed by task_group_new; keeps lib/task.w free of group internals
# the scheduler does not need.
task_group_done_fn* task_group_done_hook


# The body returned or fell off the end: gen_next already unmapped its
# stack, so gen_free only releases the generator object here.
void task_complete(task_scheduler* s, task* t):
	t.state = task_state_done
	s.active_count = s.active_count - 1
	gen_free(t.gen)
	t.gen = 0
	if (cast(int, t.joiners) != 0):
		task_wait_queue_fire_all(t.joiners, task_waiter_completed, t.result)
	if (cast(int, t.group) != 0): task_group_done_hook(t.group, t)
	if (cast(int, s.on_done) != 0): s.on_done(t, s.on_done_context)
	if (t.detached): task_reclaim(s, t)


# Switch into the task until its next suspension or completion.
void task_resume(task_scheduler* s, task* t):
	if (t.state == task_state_done): return
	task* previous = task_active_get()
	task_active_set(t)
	int alive = gen_next(t.gen)
	task_active_set(previous)
	if (alive == 0):
		task_complete(s, t)
		return
	if (t.state == task_state_ready):
		# task_yield_now (or a stray body-level yield): requeue.
		deque_push_back[task*](s.ready, t)


int task_await_fd_timeout(int fd, int events, int timeout_ms);


# io_wait hooks (lib/io_wait.w): suspend the calling task, or report
# EAGAIN outside tasks so blocking callers keep their behavior.
int task_io_wait(int fd, int events, int timeout_ms):
	if (task_in_task() == 0): return task_err_would_block()
	return task_await_fd_timeout(fd, events, timeout_ms)


int task_io_wait_active():
	return task_in_task()


task_scheduler* task_scheduler_new():
	io_wait_hook = task_io_wait
	io_wait_active_hook = task_io_wait_active
	task_scheduler* s = new task_scheduler()
	s.loop = event_loop_new()
	s.ready = deque_new[task*]()
	s.tasks = new list[task*]
	s.active_count = 0
	s.next_id = 1
	s.on_done = 0
	s.on_done_context = 0
	s.on_spawn = 0
	s.on_spawn_context = 0
	s.remote = 0
	return s


# Wrap a freshly created generator (the call expression creates it
# without running the body) as a task and queue it.
task* task_spawn(task_scheduler* s, generator* g):
	task* t = new task()
	t.gen = g
	t.state = task_state_ready
	t.id = s.next_id
	s.next_id = s.next_id + 1
	t.name = 0
	t.wait_fd = -1
	t.wait_events = 0
	t.wait_watch = 0
	t.wait_timer_id = 0
	t.timer_value = 0
	t.wait_one = 0
	t.wait_many = 0
	t.wait_count = 0
	t.wake_value = 0
	t.result = 0
	t.cancelled = 0
	t.shielded = 0
	t.has_deadline = 0
	t.deadline_ms = 0
	t.park_seq = 0
	t.detached = 0
	t.joiners = 0
	t.group = 0
	t.sched = cast(void*, s)
	t.slot = s.tasks.length
	s.tasks.push(t)
	deque_push_back[task*](s.ready, t)
	s.active_count = s.active_count + 1
	if (cast(int, s.on_spawn) != 0): s.on_spawn(t, s.on_spawn_context)
	return t


# task_spawn with a stack of stack_bytes usable bytes instead of the
# default 64KB, for bodies with deep call chains (TLS handshakes,
# recursive parsers).
task* task_spawn_sized(task_scheduler* s, generator* g, int stack_bytes):
	gen_set_stack_size(g, stack_bytes)
	return task_spawn(s, g)


# Spawn onto the current task's scheduler; only legal inside a task.
# The new task inherits the spawner's deadline.
task* task_go(generator* g):
	task* parent = task_current()
	task* t = task_spawn(task_sched(parent), g)
	t.has_deadline = parent.has_deadline
	t.deadline_ms = parent.deadline_ms
	return t


# Free the task as soon as it completes (immediately when it already
# has). The handle must not be used afterwards. For fire-and-forget
# tasks in long-running programs, which would otherwise keep their
# task struct until task_scheduler_free.
void task_detach(task* t):
	if (t.state == task_state_done):
		task_reclaim(task_sched(t), t)
		return
	t.detached = 1


void task_set_name(task* t, char* name):
	t.name = name


int task_run_pass(task_scheduler* s, int max_wait_ms, int wait_when_idle);


# Resume every ready task once, then run one event-loop iteration that
# waits at most max_wait_ms (-1: until an fd or timer fires). Returns
# 0, a negative errno from poll, or task_err_deadlock() when tasks
# remain but nothing can ever wake them (e.g. a join cycle or a
# channel nobody else holds).
int task_run_once(task_scheduler* s, int max_wait_ms):
	return task_run_pass(s, max_wait_ms, 0)


# task_run_once, except that with wait_when_idle set it also waits (for
# remote spawns, lib/task_runtime.w) when no task is left.
int task_run_pass(task_scheduler* s, int max_wait_ms, int wait_when_idle):
	while (s.ready.length > 0):
		task* t = deque_pop_front[task*](s.ready)
		task_resume(s, t)
	if (s.ready.length > 0): return 0
	if ((s.active_count == 0) && (wait_when_idle == 0)): return 0
	int watches = event_loop_watch_count(s.loop)
	int timers = event_loop_timer_count(s.loop)
	if ((watches == 0) && (timers == 0)):
		if (s.active_count > 0): return task_err_deadlock()
		return 0
	int fired = event_loop_run_once(s.loop, max_wait_ms)
	if (fired < 0):
		return fired
	return 0


# Run until every spawned task completes. Returns 0, a negative errno
# from poll, or task_err_deadlock().
int task_run(task_scheduler* s):
	while (s.active_count > 0):
		int err = task_run_once(s, -1)
		if (err < 0):
			return err
	return 0


# Frees the scheduler and every task. A task still suspended (task_run
# returned early, or was never run to completion) is abandoned:
# gen_free reclaims its stack without running the body, so cleanup code
# after its suspension point does not execute -- prefer cancelling and
# draining with task_run first.
void task_scheduler_free(task_scheduler* s):
	# Unlink every parked task from queues that may outlive the
	# scheduler before its stack (where the waiters live) goes away.
	int i = 0
	while (i < s.tasks.length):
		task* t = s.tasks[i]
		if (task_is_parked(t)): task_unpark(t)
		i = i + 1
	i = 0
	while (i < s.tasks.length):
		task* t = s.tasks[i]
		if (cast(int, t.gen) != 0): gen_free(t.gen)
		if (cast(int, t.joiners) != 0): free(cast(void*, t.joiners))
		free(cast(void*, t))
		i = i + 1
	list_free[task*](s.tasks)
	deque_free[task*](s.ready)
	event_loop_free(s.loop)
	free(cast(void*, s))


/* Awaits. Only legal inside a task; each returns task_err_cancelled()
   once the task has been cancelled and task_err_timed_out() once its
   deadline has passed. */


# Suspend until fd has one of events (a poll mask) or timeout_ms
# elapses. Returns the revents mask, task_err_timed_out(), or
# task_err_cancelled(). timeout_ms < 0 waits indefinitely.
int task_await_fd_timeout(int fd, int events, int timeout_ms):
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		return err
	t.wait_fd = fd
	t.wait_events = events
	t.wait_watch = event_loop_add_watch(task_sched(t).loop, fd, events, task_on_fd_event, cast(void*, t))
	return task_park(t, task_state_waiting_fd, timeout_ms, task_err_timed_out())


int task_await_fd(int fd, int events):
	return task_await_fd_timeout(fd, events, -1)


# Suspend for ms milliseconds. Returns 0, task_err_cancelled(), or
# task_err_timed_out() when the task's deadline comes first.
int task_sleep_ms(int ms):
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		return err
	if (ms < 0): ms = 0
	return task_park(t, task_state_waiting_timer, ms, 0)


# Reschedule behind every currently ready task without waiting on
# anything; the cooperative pressure valve for long computations.
# Returns 0, task_err_cancelled() or task_err_timed_out().
int task_yield_now():
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		return err
	t.state = task_state_ready
	t.wake_value = 0
	__w_gen_yield(t.gen, 0)
	return t.wake_value


# Record this task's completion value for task_result / task_join /
# task groups (a negative value is a failure there); the body still
# returns normally afterwards.
void task_finish(int value):
	task_current().result = value


int task_result(task* t):
	return t.result


int task_done(task* t):
	return t.state == task_state_done


int task_cancelled(task* t):
	return t.cancelled


# Wait up to timeout_ms (-1: forever) for target to complete and return
# its result, or an error: task_err_timed_out(), task_err_cancelled()
# when the *calling* task is cancelled. Any number of tasks may join
# the same target. A detached target must still be running.
int task_join_timeout(task* target, int timeout_ms):
	task* t = task_current()
	if (target.state == task_state_done): return target.result
	int err = task_park_check(t)
	if (err < 0):
		return err
	if (cast(int, target.joiners) == 0): target.joiners = task_wait_queue_new()
	task_waiter w
	task_waiter_init(&w, t)
	task_waiter_link(target.joiners, &w)
	t.wait_one = &w
	return task_park(t, task_state_waiting_task, timeout_ms, task_err_timed_out())


int task_join(task* target):
	return task_join_timeout(target, -1)


# Cancel a task: mark it and wake it with task_err_cancelled() so its
# body unwinds through normal error paths (every later await fails the
# same way). The task still runs to completion; join it to observe
# that. Returns 1, or 0 when it was already done or cancelled.
int task_cancel(task* t):
	if (t.state == task_state_done): return 0
	if (t.cancelled): return 0
	t.cancelled = 1
	if (t.shielded == 0):
		# A parked task wakes now; a ready or running one sees the flag
		# at its next await.
		task_wake(t, task_err_cancelled())
	return 1


/* Deadlines. A scope bounds every await of the current task until it
   is exited; scopes nest (the nearer deadline wins) and are inherited
   by tasks spawned with task_go and task_group_spawn. */

struct task_deadline_scope:
	task* owner
	int prev_has
	int prev_ms


# Enter a scope that expires ms milliseconds from now. Awaits inside it
# return task_err_timed_out() once it expires.
void task_deadline_enter(task_deadline_scope* scope, int ms):
	task* t = task_current()
	scope.owner = t
	scope.prev_has = t.has_deadline
	scope.prev_ms = t.deadline_ms
	int at = time_monotonic_ms() + ms
	if ((t.has_deadline == 0) || ((at - t.deadline_ms) < 0)): t.deadline_ms = at
	t.has_deadline = 1


void task_deadline_exit(task_deadline_scope* scope):
	task* t = scope.owner
	t.has_deadline = scope.prev_has
	t.deadline_ms = scope.prev_ms


# Milliseconds left before the current task's deadline (0 once it
# passed), or -1 when no deadline is set.
int task_deadline_remaining():
	task* t = task_current()
	if (t.has_deadline == 0): return -1
	int left = t.deadline_ms - time_monotonic_ms()
	if (left < 0): return 0
	return left


# Give a task (typically freshly spawned) a deadline ms from now.
void task_set_deadline(task* t, int ms):
	t.has_deadline = 1
	t.deadline_ms = time_monotonic_ms() + ms


/* Structured concurrency. */

struct task_group:
	task_scheduler* sched
	int active          # children not yet done
	int spawned         # children ever spawned
	int error           # first negative child result, 0 if none
	int cancelled
	task_wait_queue waiters


int task_group_cancel(task_group* g);


void task_group_on_child_done(void* context, task* child):
	task_group* g = cast(task_group*, context)
	g.active = g.active - 1
	if ((child.result < 0) && (g.error == 0) && (g.cancelled == 0)):
		g.error = child.result
		task_group_cancel(g)
	if (g.active == 0): task_wait_queue_fire_all(&g.waiters, task_waiter_completed, 0)


task_group* task_group_new(task_scheduler* s):
	task_group_done_hook = task_group_on_child_done
	task_group* g = new task_group()
	g.sched = s
	g.active = 0
	g.spawned = 0
	g.error = 0
	g.cancelled = 0
	task_wait_queue_init(&g.waiters)
	return g


# A group on the current task's scheduler; only legal inside a task.
task_group* task_group_here():
	return task_group_new(task_sched(task_current()))


# Spawn g into the group. Children are reclaimed when they complete, so
# there is no handle: report results through task_finish (a negative
# value fails the group), channels or shared state. Inside a task the
# child inherits the spawner's deadline. Spawning into a cancelled
# group starts the child already cancelled.
void task_group_spawn(task_group* g, generator* body):
	task* t = task_spawn(g.sched, body)
	t.group = cast(void*, g)
	t.detached = 1
	task* parent = task_active_get()
	if (cast(int, parent) != 0):
		t.has_deadline = parent.has_deadline
		t.deadline_ms = parent.deadline_ms
	g.active = g.active + 1
	g.spawned = g.spawned + 1
	if (g.cancelled): t.cancelled = 1


# task_group_spawn with a custom stack size (see task_spawn_sized).
void task_group_spawn_sized(task_group* g, generator* body, int stack_bytes):
	gen_set_stack_size(body, stack_bytes)
	task_group_spawn(g, body)


# Cancel every running child. Returns the number cancelled.
int task_group_cancel(task_group* g):
	g.cancelled = 1
	int count = 0
	task_scheduler* s = g.sched
	for i in range(s.tasks.length):
		task* t = s.tasks[i]
		if ((cast(task_group*, t.group) == g) && (t.state != task_state_done)):
			count = count + task_cancel(t)
	return count


# Wait until every child has finished. Returns the first failing
# child's result, 0 when all succeeded, or the error that interrupted
# the wait (the caller was cancelled or its deadline passed) -- in that
# case the children are cancelled and still waited for, so no child
# outlives this call.
int task_group_wait(task_group* g):
	task* t = task_current()
	int interrupted = 0
	while (g.active > 0):
		if (g.cancelled == 0):
			int err = task_park_check(t)
			if (err < 0):
				interrupted = err
				task_group_cancel(g)
		task_waiter w
		task_waiter_init(&w, t)
		int saved = t.shielded
		if (g.cancelled):
			# Tearing down: wait the children out even though this task
			# is cancelled or past its deadline.
			t.shielded = 1
		task_waiter_link(&g.waiters, &w)
		t.wait_one = &w
		int r = task_park(t, task_state_waiting_queue, -1, 0)
		t.shielded = saved
		if ((r < 0) && (g.cancelled == 0)):
			interrupted = r
			task_group_cancel(g)
	if (interrupted < 0):
		return interrupted
	return g.error


# Release a group whose children have all finished.
void task_group_free(task_group* g):
	asserts(c"task_group_free: children still running (task_group_wait first)", g.active == 0)
	free(cast(void*, g))


/* Diagnostics. */

char* task_state_name(int state):
	if (state == task_state_ready): return c"ready"
	if (state == task_state_waiting_fd): return c"waiting on fd"
	if (state == task_state_waiting_timer): return c"sleeping"
	if (state == task_state_waiting_task): return c"joining"
	if (state == task_state_done): return c"done"
	if (state == task_state_waiting_queue): return c"waiting on queue"
	if (state == task_state_waiting_external): return c"waiting on thread"
	return c"unknown"


# Write one line per live task to fd: id, name, state and what it waits
# on. For "why is my server stuck" moments.
void task_dump_fd(task_scheduler* s, int fd):
	write_string(fd, c"tasks: ")
	write_string(fd, itoa(s.active_count))
	write_string(fd, c" active, ")
	write_string(fd, itoa(s.ready.length))
	write_string(fd, c" ready\x0a")
	for i in range(s.tasks.length):
		task* t = s.tasks[i]
		write_string(fd, c"  #")
		write_string(fd, itoa(t.id))
		if (cast(int, t.name) != 0):
			write_string(fd, c" ")
			write_string(fd, t.name)
		write_string(fd, c": ")
		write_string(fd, task_state_name(t.state))
		if (t.state == task_state_waiting_fd):
			write_string(fd, c" ")
			write_string(fd, itoa(t.wait_fd))
		if (t.wait_timer_id != 0): write_string(fd, c" (timer armed)")
		if (t.cancelled): write_string(fd, c" [cancelled]")
		if (t.has_deadline):
			write_string(fd, c" [deadline in ")
			write_string(fd, itoa(t.deadline_ms - time_monotonic_ms()))
			write_string(fd, c"ms]")
		write_string(fd, c"\x0a")


void task_dump(task_scheduler* s):
	task_dump_fd(s, 2)
