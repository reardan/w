/*
Bounded blocking-work executor (docs/projects/async.md, "Bounded
executor"; design: docs/projects/reliable_services.md, W3).

A fixed set of reused worker threads runs plain functions (blocking
syscalls such as fsync, CPU-heavy work) on behalf of tasks or threads,
under explicit limits:

	executor* sync_ex = executor_new(c"fsync", 2, 16, 1048576)
	executor_result r
	# inside a task: parks only this task until fsync_fn(&req) returned
	if (executor_run(sync_ex, fsync_fn, &req, 0, 100, &r) != IO_OK):
		# EXEC_OVERLOADED / EXEC_CLOSED / EXEC_TOO_LARGE / IO_TIMED_OUT /
		# IO_CANCELLED: fsync_fn never ran
	...
	executor_shutdown(sync_ex, EXEC_DRAIN)
	executor_free(sync_ex)

Limits. max_workers threads at most (one is started with the executor,
the rest on demand, all reused until shutdown). At most max_workers +
max_queued jobs are admitted at once (running plus queued), and the
declared byte costs of admitted jobs never sum past max_bytes (a cost
is whatever memory the job pins -- its buffers; 0 is fine for jobs that
pin nothing; a job whose cost alone exceeds max_bytes can never run
and is refused with EXEC_TOO_LARGE). Separate executors are separate
capacity classes: a slow maintenance job saturating one cannot delay a
latency-sensitive fsync queued on another.

Admission. timeout_ms 0 is try-submit: capacity now, or EXEC_OVERLOADED
at once. Otherwise the caller waits for capacity, FIFO, up to
timeout_ms (-1: no limit) and, inside a task, the task's deadline: a
task parks (the event loop and other tasks keep running), a plain
thread blocks. Expiry returns IO_TIMED_OUT, cancelling the waiting task
IO_CANCELLED. While submitters wait, try-submit refuses, so a stream of
small try-submits cannot starve a waiting large job. After
executor_close every submission returns EXEC_CLOSED.

Completion contract (join before return). executor_run submits and
waits; executor_wait waits for a job from executor_submit. Neither
returns while the function may still touch its argument, so arg and
any output buffers may live on the caller's (task's) stack:

- Cancelled (or past its deadline) while the job is still queued: the
  job is removed before dispatch, the function never runs, and the wait
  returns IO_CANCELLED (IO_TIMED_OUT). Capacity is released at once.
- Cancelled after dispatch: the function is already running and a
  blocking syscall cannot be stopped or undone. The wait stays shielded
  until the function returns and then reports its real outcome
  (status IO_OK, value) with r.cancelled = 1. The task sees its
  cancellation again at its next await.

executor_detach hands a job to the executor instead (fire and forget):
its argument must then be owned by the function or outlive the
executor. Every handle is waited or detached exactly once, on the
thread (or scheduler) that submitted it, before executor_free.

Shutdown. executor_close(ex, mode) closes admission (waiting
submitters get EXEC_CLOSED) and either drains (EXEC_DRAIN: queued jobs
still run) or cancels (EXEC_CANCEL: queued jobs complete as
IO_CANCELLED without running). executor_join then waits for the
workers to finish what they are running and exit -- inside a task the
blocking join runs on a helper thread so only that task waits.
executor_shutdown is close + join; executor_free shuts down (draining)
if that has not happened and frees the queues.

How completions reach a task. A worker that finishes a job posts a
task_remote_call to the waiting task's scheduler inbox
(lib/task_runtime.w), the same eventfd wakeup task_spawn_blocking uses.
The callback runs on the waiter's own thread and wakes the task only if
it is still parked in the park that expects this job; jobs are
reference counted, so a callback that arrives after a cancelled waiter
already returned finds the job alive and the waiter gone. Plain-thread
waiters sleep on a condition variable instead.

Locking. One wmutex per executor guards the queues and counters; it is
never held across a task park, a job function, or a join. Linux
x86/x64 only, like lib/thread.w and lib/task_runtime.w.
*/
import lib.lib
import lib.assert
import lib.io
import lib.time
import lib.thread
import lib.task
import lib.task_runtime


# Executor statuses beyond lib/io.w's IO_* categories (which supply
# IO_OK, IO_CANCELLED and IO_TIMED_OUT here).
const int EXEC_OVERLOADED = 16    # no capacity, and the caller would not wait
const int EXEC_CLOSED = 17        # admission is closed (executor_close)
const int EXEC_TOO_LARGE = 18     # cost exceeds max_bytes: could never run


# executor_close / executor_shutdown modes.
const int EXEC_DRAIN = 0     # queued jobs still run
const int EXEC_CANCEL = 1    # queued jobs complete as IO_CANCELLED unrun


# Job states.
const int executor_job_admitting = 0   # submitter waiting for capacity
const int executor_job_queued = 1
const int executor_job_running = 2
const int executor_job_done = 3        # ran; value is the result
const int executor_job_dropped = 4     # never ran; status says why


type executor_fn = fn(void*) -> int


struct executor_job:
	executor_job* prev
	executor_job* next
	void* ex                 # executor*
	executor_fn* func
	void* arg
	int cost
	int state
	int status               # final status once done or dropped
	int value                # func's result once done
	int refs                 # owner handle + executor membership + posted calls
	int detached
	task_remote* remote      # waiting task's inbox; 0 for a plain-thread waiter
	task* parked             # waiting task while parked (its thread only)
	int park_seq             #   the park that expects this job


struct executor_queue:
	executor_job* head
	executor_job* tail
	int length


struct executor:
	wmutex lock
	wcond work               # idle workers sleep here
	wcond changed            # plain-thread waiters sleep here
	char* name
	int max_workers
	int max_queued
	int max_bytes
	executor_queue queue     # admitted, not yet dispatched
	executor_queue admitting # submitters waiting for capacity, FIFO
	int queued_bytes
	int running
	int running_bytes
	int workers              # live worker threads
	int idle_workers
	list[wthread*] threads
	int closed
	int stopping
	int joined
	int submitted
	int completed
	int rejected
	int wait_expired
	int cancelled


# Snapshot for diagnostics (executor_get_stats).
struct executor_stats:
	int queued_jobs          # admitted, waiting for a worker
	int queued_bytes
	int running_jobs         # = busy workers
	int running_bytes
	int waiting_submitters   # blocked in admission
	int workers              # live worker threads
	int idle_workers
	int submitted            # jobs ever admitted
	int completed            # jobs whose function returned
	int rejected             # refused at once for lack of capacity
	int wait_expired         # admission waits ended by timeout or cancellation
	int cancelled            # admitted jobs removed before dispatch


# What a wait reports. status IO_OK means the function ran and value
# is its result; any other status means it never ran.
struct executor_result:
	int status
	int value
	int cancelled            # the waiter was cancelled (or hit its
	                         # deadline) after dispatch; the job still ran


char* executor_status_name(int status):
	if (status == EXEC_OVERLOADED): return c"overloaded"
	if (status == EXEC_CLOSED): return c"closed"
	if (status == EXEC_TOO_LARGE): return c"too_large"
	return io_status_name(status)


/* Intrusive FIFO of jobs (executor lock held). */

void executor_queue_init(executor_queue* q):
	q.head = 0
	q.tail = 0
	q.length = 0


void executor_queue_push(executor_queue* q, executor_job* j):
	j.next = 0
	j.prev = q.tail
	if (cast(int, q.tail) != 0): q.tail.next = j
	else: q.head = j
	q.tail = j
	q.length = q.length + 1


void executor_queue_unlink(executor_queue* q, executor_job* j):
	if (cast(int, j.prev) != 0): j.prev.next = j.next
	else: q.head = j.next
	if (cast(int, j.next) != 0): j.next.prev = j.prev
	else: q.tail = j.prev
	j.prev = 0
	j.next = 0
	q.length = q.length - 1


/* Jobs. */

executor_job* executor_job_new(executor* ex, executor_fn* func, void* arg, int cost):
	executor_job* j = new executor_job()
	j.prev = 0
	j.next = 0
	j.ex = cast(void*, ex)
	j.func = func
	j.arg = arg
	j.cost = cost
	j.state = executor_job_admitting
	j.status = IO_OK
	j.value = 0
	j.refs = 2
	j.detached = 0
	j.remote = 0
	j.parked = 0
	j.park_seq = 0
	return j


void executor_job_unref(executor_job* j):
	if (atomic_add(&j.refs, -1) == 1): free(cast(void*, j))


# On the waiting task's own thread: wake it if it is still parked in the
# park that expects this job, then drop the call's reference.
void executor_job_on_notify(void* p):
	executor_job* j = cast(executor_job*, p)
	task* t = j.parked
	if (cast(int, t) != 0):
		if ((t.park_seq == j.park_seq) && task_is_parked(t)): task_wake(t, 0)
	executor_job_unref(j)


# Tell j's waiter that its state changed (lock held).
void executor_notify_locked(executor* ex, executor_job* j):
	if (j.detached): return
	if (cast(int, j.remote) != 0):
		atomic_add(&j.refs, 1)
		task_remote_call(j.remote, executor_job_on_notify, cast(void*, j))
		return
	cond_broadcast(&ex.changed)


/* Workers. */

void executor_admit_waiters_locked(executor* ex);


void executor_worker_main(void* p):
	executor* ex = cast(executor*, p)
	mutex_lock(&ex.lock)
	while (1):
		executor_job* j = ex.queue.head
		if (cast(int, j) == 0):
			if (ex.stopping): break
			ex.idle_workers = ex.idle_workers + 1
			cond_wait(&ex.work, &ex.lock)
			ex.idle_workers = ex.idle_workers - 1
			continue
		executor_queue_unlink(&ex.queue, j)
		ex.queued_bytes = ex.queued_bytes - j.cost
		ex.running = ex.running + 1
		ex.running_bytes = ex.running_bytes + j.cost
		j.state = executor_job_running
		mutex_unlock(&ex.lock)
		int value = j.func(j.arg)
		mutex_lock(&ex.lock)
		ex.running = ex.running - 1
		ex.running_bytes = ex.running_bytes - j.cost
		ex.completed = ex.completed + 1
		j.value = value
		j.status = IO_OK
		j.state = executor_job_done
		executor_notify_locked(ex, j)
		executor_job_unref(j)
		executor_admit_waiters_locked(ex)
	ex.workers = ex.workers - 1
	mutex_unlock(&ex.lock)


# Start one more worker (lock held: thread_spawn only waits for the
# child's handshake, which never takes this lock). 1 on success.
int executor_spawn_worker_locked(executor* ex):
	wthread* th = thread_spawn(executor_worker_main, cast(void*, ex))
	if (cast(int, th) == 0): return 0
	ex.threads.push(th)
	ex.workers = ex.workers + 1
	return 1


# Queue an admitted job and make sure a worker will take it (lock held).
void executor_enqueue_locked(executor* ex, executor_job* j):
	j.state = executor_job_queued
	executor_queue_push(&ex.queue, j)
	ex.queued_bytes = ex.queued_bytes + j.cost
	ex.submitted = ex.submitted + 1
	# A failed spawn is not fatal: the workers that exist drain the queue.
	if ((ex.queue.length > ex.idle_workers) && (ex.workers < ex.max_workers)):
		executor_spawn_worker_locked(ex)
	cond_signal(&ex.work)


# Whether a job of cost fits now (lock held).
int executor_fits_locked(executor* ex, int cost):
	if ((ex.queue.length + ex.running) >= (ex.max_workers + ex.max_queued)): return 0
	int used = ex.queued_bytes + ex.running_bytes
	if (cost > (ex.max_bytes - used)): return 0
	return 1


# Capacity was released: admit waiting submitters in FIFO order while
# the head fits (lock held).
void executor_admit_waiters_locked(executor* ex):
	while (ex.closed == 0):
		executor_job* j = ex.admitting.head
		if (cast(int, j) == 0): return
		if (executor_fits_locked(ex, j.cost) == 0): return
		executor_queue_unlink(&ex.admitting, j)
		executor_enqueue_locked(ex, j)
		executor_notify_locked(ex, j)


# End a job that never ran: unlink it from wherever it waits, record why,
# release what it held and drop the executor's reference (lock held).
void executor_drop_locked(executor* ex, executor_job* j, int status):
	if (j.state == executor_job_queued):
		executor_queue_unlink(&ex.queue, j)
		ex.queued_bytes = ex.queued_bytes - j.cost
		ex.cancelled = ex.cancelled + 1
	else:
		executor_queue_unlink(&ex.admitting, j)
	j.state = executor_job_dropped
	j.status = status
	j.value = 0
	executor_notify_locked(ex, j)
	executor_job_unref(j)
	executor_admit_waiters_locked(ex)


/* Construction. */

# An executor with at most max_workers threads (>= 1), max_queued jobs
# waiting beyond those (>= 0) and max_bytes of admitted job cost
# (>= 0). name labels diagnostics and is not owned. One worker starts
# now; returns 0 if even that thread cannot be created.
executor* executor_new(char* name, int max_workers, int max_queued, int max_bytes):
	# Current-task accessors become per-thread before any worker exists,
	# so task_in_task() is false on worker threads.
	task_runtime_install()
	if (max_workers < 1): max_workers = 1
	if (max_queued < 0): max_queued = 0
	if (max_bytes < 0): max_bytes = 0
	executor* ex = new executor()
	mutex_init(&ex.lock)
	cond_init(&ex.work)
	cond_init(&ex.changed)
	ex.name = name
	ex.max_workers = max_workers
	ex.max_queued = max_queued
	ex.max_bytes = max_bytes
	executor_queue_init(&ex.queue)
	executor_queue_init(&ex.admitting)
	ex.queued_bytes = 0
	ex.running = 0
	ex.running_bytes = 0
	ex.workers = 0
	ex.idle_workers = 0
	ex.threads = new list[wthread*]
	ex.closed = 0
	ex.stopping = 0
	ex.joined = 0
	ex.submitted = 0
	ex.completed = 0
	ex.rejected = 0
	ex.wait_expired = 0
	ex.cancelled = 0
	mutex_lock(&ex.lock)
	int ok = executor_spawn_worker_locked(ex)
	mutex_unlock(&ex.lock)
	if (ok == 0):
		list_free[wthread*](ex.threads)
		free(cast(void*, ex))
		return 0
	return ex


/* Submission. */

# IO_CANCELLED / IO_TIMED_OUT for a task await error.
int executor_status_from_task_err(int err):
	if (err == task_err_timed_out()): return IO_TIMED_OUT
	return IO_CANCELLED


struct executor_timespec:
	int sec
	int nsec


# cond_wait bounded by ms (< 0: unbounded). Same contract: spurious
# wakes happen, re-check the predicate.
void executor_cond_wait_ms(wcond* c, wmutex* m, int ms):
	if (ms < 0):
		cond_wait(c, m)
		return
	executor_timespec ts
	ts.sec = ms / 1000
	ts.nsec = (ms % 1000) * 1000000
	int observed = c.seq
	mutex_unlock(m)
	sys_futex(cast(int, &c.seq), thread_futex_wait_op, observed, cast(int, &ts))
	mutex_lock(m)


# Wait (lock held) until j leaves the admitting state or the wait ends.
# Returns IO_OK once admitted (or dropped by close, which j.status
# reports), else why the wait ended; j is then already dropped.
int executor_await_admission_locked(executor* ex, executor_job* j, int timeout_ms):
	task* t = task_active_get()
	int start = time_monotonic_ms()
	while (j.state == executor_job_admitting):
		int remaining = -1
		if (timeout_ms >= 0):
			remaining = timeout_ms - (time_monotonic_ms() - start)
			if (remaining <= 0):
				ex.wait_expired = ex.wait_expired + 1
				executor_drop_locked(ex, j, IO_TIMED_OUT)
				return IO_TIMED_OUT
		if (cast(int, t) == 0):
			executor_cond_wait_ms(&ex.changed, &ex.lock, remaining)
		else:
			int err = task_park_check(t)
			if (err < 0):
				ex.wait_expired = ex.wait_expired + 1
				executor_drop_locked(ex, j, executor_status_from_task_err(err))
				return j.status
			j.parked = t
			j.park_seq = t.park_seq + 1
			mutex_unlock(&ex.lock)
			task_park(t, task_state_waiting_external, remaining, 0)
			j.parked = 0
			mutex_lock(&ex.lock)
	return IO_OK


# Submit func(arg) with a byte cost, waiting up to timeout_ms for
# capacity (0: try-submit, -1: no limit; a task's deadline also
# applies). On IO_OK *out is a handle for executor_wait or
# executor_detach; otherwise *out is 0 and func will never run:
# EXEC_OVERLOADED, EXEC_CLOSED, EXEC_TOO_LARGE, IO_TIMED_OUT or
# IO_CANCELLED.
int executor_submit(executor* ex, executor_fn* func, void* arg, int cost, int timeout_ms, executor_job** out):
	*out = 0
	if (cost < 0): cost = 0
	task* t = task_active_get()
	task_remote* remote = 0
	if (cast(int, t) != 0):
		# Like every await: a cancelled or expired task submits nothing.
		int interrupted = task_park_check(t)
		if (interrupted < 0): return executor_status_from_task_err(interrupted)
		remote = task_remote_attach(task_sched(t))
	mutex_lock(&ex.lock)
	if (ex.closed):
		mutex_unlock(&ex.lock)
		return EXEC_CLOSED
	if (cost > ex.max_bytes):
		ex.rejected = ex.rejected + 1
		mutex_unlock(&ex.lock)
		return EXEC_TOO_LARGE
	executor_job* j = executor_job_new(ex, func, arg, cost)
	j.remote = remote
	if ((ex.admitting.length == 0) && executor_fits_locked(ex, cost)):
		executor_enqueue_locked(ex, j)
		mutex_unlock(&ex.lock)
		*out = j
		return IO_OK
	if (timeout_ms == 0):
		ex.rejected = ex.rejected + 1
		mutex_unlock(&ex.lock)
		free(cast(void*, j))
		return EXEC_OVERLOADED
	executor_queue_push(&ex.admitting, j)
	int status = executor_await_admission_locked(ex, j, timeout_ms)
	if (j.state == executor_job_dropped):
		status = j.status
		mutex_unlock(&ex.lock)
		executor_job_unref(j)
		return status
	mutex_unlock(&ex.lock)
	*out = j
	return IO_OK


int executor_try_submit(executor* ex, executor_fn* func, void* arg, int cost, executor_job** out):
	return executor_submit(ex, func, arg, cost, 0, out)


/* Waiting. */

# Whether t was cancelled or is past its deadline (ignoring shielding).
int executor_task_interrupted(task* t):
	if (t.cancelled): return 1
	if (t.has_deadline):
		if ((t.deadline_ms - time_monotonic_ms()) <= 0): return 1
	return 0


int executor_terminal(executor_job* j):
	return (j.state == executor_job_done) || (j.state == executor_job_dropped)


# Wait for a submitted job and release its handle; see the header for
# the cancellation contract. Fills r and returns r.status.
int executor_wait(executor_job* j, executor_result* r):
	executor* ex = cast(executor*, j.ex)
	task* t = task_active_get()
	task_remote* remote = 0
	if (cast(int, t) != 0): remote = task_remote_attach(task_sched(t))
	mutex_lock(&ex.lock)
	j.remote = remote
	while (executor_terminal(j) == 0):
		if (cast(int, t) == 0):
			cond_wait(&ex.changed, &ex.lock)
			continue
		int shield = 0
		if (j.state == executor_job_queued):
			# Not dispatched yet: cancellation removes it, unrun.
			int err = task_park_check(t)
			if (err < 0):
				executor_drop_locked(ex, j, executor_status_from_task_err(err))
				break
		else:
			# Running: func may be using memory this task owns, so wait
			# it out whatever arrives meanwhile.
			shield = 1
		j.parked = t
		j.park_seq = t.park_seq + 1
		int saved = t.shielded
		if (shield): t.shielded = 1
		mutex_unlock(&ex.lock)
		task_park(t, task_state_waiting_external, -1, 0)
		t.shielded = saved
		j.parked = 0
		mutex_lock(&ex.lock)
	r.status = j.status
	r.value = j.value
	r.cancelled = 0
	if ((j.status == IO_OK) && (cast(int, t) != 0)): r.cancelled = executor_task_interrupted(t)
	mutex_unlock(&ex.lock)
	executor_job_unref(j)
	return r.status


# Give up the handle: the job still runs (or stays dropped), nobody
# waits for it, and the executor frees it. arg must not live on the
# caller's stack.
void executor_detach(executor_job* j):
	executor* ex = cast(executor*, j.ex)
	mutex_lock(&ex.lock)
	j.detached = 1
	mutex_unlock(&ex.lock)
	executor_job_unref(j)


# Submit (waiting up to timeout_ms for capacity, as executor_submit)
# and wait for the result: join before return. Fills r and returns
# r.status; IO_OK means func ran and r.value is its result.
int executor_run(executor* ex, executor_fn* func, void* arg, int cost, int timeout_ms, executor_result* r):
	executor_job* j = 0
	int status = executor_submit(ex, func, arg, cost, timeout_ms, &j)
	if (status != IO_OK):
		r.status = status
		r.value = 0
		r.cancelled = 0
		return status
	return executor_wait(j, r)


# Fire and forget: submit and detach. Returns the submit status.
int executor_post(executor* ex, executor_fn* func, void* arg, int cost, int timeout_ms):
	executor_job* j = 0
	int status = executor_submit(ex, func, arg, cost, timeout_ms, &j)
	if (status == IO_OK): executor_detach(j)
	return status


/* Shutdown. */

# Close admission: later submissions and every waiting submitter get
# EXEC_CLOSED. EXEC_CANCEL also drops every queued job (IO_CANCELLED,
# never run); EXEC_DRAIN leaves them to run. Workers exit once the
# queue is empty. Never blocks; idempotent (a later EXEC_CANCEL still
# cancels what is queued).
void executor_close(executor* ex, int mode):
	mutex_lock(&ex.lock)
	ex.closed = 1
	while (ex.admitting.length > 0): executor_drop_locked(ex, ex.admitting.head, EXEC_CLOSED)
	if (mode == EXEC_CANCEL):
		while (ex.queue.length > 0): executor_drop_locked(ex, ex.queue.head, IO_CANCELLED)
	ex.stopping = 1
	cond_broadcast(&ex.work)
	mutex_unlock(&ex.lock)


int executor_join_workers(void* p):
	executor* ex = cast(executor*, p)
	mutex_lock(&ex.lock)
	list[wthread*] threads = ex.threads
	ex.threads = new list[wthread*]
	mutex_unlock(&ex.lock)
	int i = 0
	while (i < threads.length):
		thread_join(threads[i])
		i = i + 1
	list_free[wthread*](threads)
	return 0


# Wait until every worker finished its running job (and, after
# EXEC_DRAIN, the queue) and exited. Closes with EXEC_DRAIN first if
# executor_close was not called. Inside a task only that task waits.
void executor_join(executor* ex):
	if (ex.joined): return
	if (ex.stopping == 0): executor_close(ex, EXEC_DRAIN)
	if (task_in_task()): task_spawn_blocking(executor_join_workers, cast(void*, ex))
	else: executor_join_workers(cast(void*, ex))
	ex.joined = 1


void executor_shutdown(executor* ex, int mode):
	executor_close(ex, mode)
	executor_join(ex)


# Shut down (draining) unless done already, then free the executor.
# Every job handle must have been waited or detached.
void executor_free(executor* ex):
	executor_join(ex)
	asserts(c"executor_free: jobs still admitted", (ex.queue.length + ex.running) == 0)
	list_free[wthread*](ex.threads)
	free(cast(void*, ex))


/* Diagnostics. */

void executor_get_stats(executor* ex, executor_stats* s):
	mutex_lock(&ex.lock)
	s.queued_jobs = ex.queue.length
	s.queued_bytes = ex.queued_bytes
	s.running_jobs = ex.running
	s.running_bytes = ex.running_bytes
	s.waiting_submitters = ex.admitting.length
	s.workers = ex.workers
	s.idle_workers = ex.idle_workers
	s.submitted = ex.submitted
	s.completed = ex.completed
	s.rejected = ex.rejected
	s.wait_expired = ex.wait_expired
	s.cancelled = ex.cancelled
	mutex_unlock(&ex.lock)


# One line of counters to fd, for "why is the disk queue stuck" moments.
void executor_dump_fd(executor* ex, int fd):
	executor_stats s
	executor_get_stats(ex, &s)
	write_string(fd, c"executor ")
	if (cast(int, ex.name) != 0): write_string(fd, ex.name)
	write_string(fd, c": queued ")
	write_string(fd, itoa(s.queued_jobs))
	write_string(fd, c" (")
	write_string(fd, itoa(s.queued_bytes))
	write_string(fd, c" bytes), running ")
	write_string(fd, itoa(s.running_jobs))
	write_string(fd, c"/")
	write_string(fd, itoa(s.workers))
	write_string(fd, c" workers, waiting ")
	write_string(fd, itoa(s.waiting_submitters))
	write_string(fd, c", completed ")
	write_string(fd, itoa(s.completed))
	write_string(fd, c", rejected ")
	write_string(fd, itoa(s.rejected))
	write_string(fd, c", expired ")
	write_string(fd, itoa(s.wait_expired))
	write_string(fd, c", cancelled ")
	write_string(fd, itoa(s.cancelled))
	write_string(fd, c"\x0a")
