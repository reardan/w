/*
Multi-threaded task runtime (docs/projects/async.md, stage 6): one
task scheduler per worker thread ("thread-per-core"), cross-thread
wakeups, blocking work on helper threads, and channels between tasks
on different threads. Linux x86/x64 only: it builds on lib/thread.w
(clone threads, futex mutex) and thread_local (per-thread current
task), neither of which exists on the other targets yet.

	task_runtime* rt = task_runtime_new(4)
	int i = 0
	while (i < 100):
		task_runtime_spawn(rt, handle_job(i))   # round-robin over workers
		i = i + 1
	task_runtime_run(rt)                        # until every task is done
	task_runtime_free(rt)

Tasks never migrate: a task runs, parks and completes on the worker
that received it, so everything lib/task.w promises (wait queues,
task_chan, task_mutex, groups) holds within one worker, and the body
may keep pointers into its own stack across awaits. What crosses
threads:

- task_runtime_spawn / task_runtime_spawn_on post a new task into a
  worker's inbox (an eventfd its event loop watches).
- task_xchan is a mutex-protected channel whose parked senders and
  receivers are woken through their own worker's inbox, so tasks on
  different workers can exchange words. Same-scheduler peers are woken
  directly.
- task_spawn_blocking runs a plain function on a fresh thread and parks
  only the calling task until it returns: the answer for blocking
  syscalls and CPU-heavy work (it also works on a lone scheduler,
  without a task_runtime).

Allocation from any thread is safe (per-thread heaps,
lib/thread_heap.w), including freeing memory another thread allocated.
Plain globals are shared between workers: guard them with a wmutex
(never held across an await) or keep them per worker.
*/
import lib.lib
import lib.assert
import lib.thread
import lib.net
import lib.task
import lib.container
import structures.deque
import lib.mem


/* Per-thread current task. */

thread_local void* task_runtime_current_task


void* task_runtime_get_current():
	return task_runtime_current_task


void task_runtime_set_current(void* t):
	task_runtime_current_task = t


# Route lib/task.w's current-task accessors through thread-local
# storage. Idempotent; happens before any second thread runs tasks
# (task_runtime_new, or the first cross-thread primitive used).
void task_runtime_install():
	if (cast(int, task_active_get_hook) != 0):
		return
	# Installing from inside a task (first task_spawn_blocking on a lone
	# scheduler): no other thread runs tasks yet, so carry the running
	# task over into this thread's slot.
	task_runtime_current_task = cast(void*, task_active)
	task_active = 0
	task_active_get_hook = task_runtime_get_current
	task_active_set_hook = task_runtime_set_current


/* Remote inbox: how other threads reach a scheduler. */

int task_remote_msg_spawn():
	return 1


int task_remote_msg_wake():
	return 2


int task_remote_msg_nop():
	return 3


struct task_remote_msg:
	int kind
	generator* gen      # spawn
	task* target        # wake
	int seq             #   the park it was meant for
	int value           #   wake value


struct task_remote:
	wmutex lock
	list[task_remote_msg*] pending
	int read_fd
	int write_fd
	int* counter        # runtime outstanding-task counter, 0 if none
	task_scheduler* sched


# EFD_NONBLOCK | EFD_CLOEXEC
int task_remote_eventfd_flags():
	return 2048 + 524288


void task_remote_signal(task_remote* r):
	char[8] one
	mem_fill[char](one, 0, 8)
	one[0] = 1
	# An eventfd takes an 8-byte counter increment, a pipe any byte. A
	# full pipe (EAGAIN) already guarantees a pending wakeup.
	write(r.write_fd, &one[0], 8)


void task_remote_post(task_remote* r, task_remote_msg* m):
	mutex_lock(&r.lock)
	r.pending.push(m)
	mutex_unlock(&r.lock)
	task_remote_signal(r)


# Runs on the owning thread when the inbox fd turns readable.
void task_remote_on_readable(int fd, int revents, void* context):
	task_remote* r = cast(task_remote*, context)
	char* sink = malloc(64)
	while (read(r.read_fd, sink, 64) > 0):
		pass
	free(sink)
	mutex_lock(&r.lock)
	list[task_remote_msg*] batch = r.pending
	r.pending = new list[task_remote_msg*]
	mutex_unlock(&r.lock)
	int i = 0
	while (i < batch.length):
		task_remote_msg* m = batch[i]
		if (m.kind == task_remote_msg_spawn()):
			task_spawn(r.sched, m.gen)
			if (cast(int, r.counter) != 0):
				# The post counted it in flight; task_spawn counted it
				# again through the scheduler hook.
				atomic_add(r.counter, -1)
		else if (m.kind == task_remote_msg_wake()):
			task* t = m.target
			if ((t.park_seq == m.seq) && task_is_parked(t)):
				task_wake(t, m.value)
		free(cast(void*, m))
		i = i + 1
	list_free[task_remote_msg*](batch)


# The scheduler's inbox, created (and watched by its loop) on first use.
# Call it on the scheduler's own thread.
task_remote* task_remote_attach(task_scheduler* s):
	if (cast(int, s.remote) != 0):
		return cast(task_remote*, s.remote)
	task_runtime_install()
	task_remote* r = new task_remote()
	mutex_init(&r.lock)
	r.pending = new list[task_remote_msg*]
	r.counter = 0
	r.sched = s
	int efd = eventfd2(0, task_remote_eventfd_flags())
	if (efd >= 0):
		r.read_fd = efd
		r.write_fd = efd
	else:
		int* fds = cast(int*, malloc(2 * __word_size__))
		asserts(c"task_remote_attach: pipe failed", pipe(fds) >= 0)
		r.read_fd = fds[0]
		r.write_fd = fds[1]
		socket_set_nonblocking(fds[0])
		socket_set_nonblocking(fds[1])
		free(cast(void*, fds))
	s.remote = cast(void*, r)
	event_loop_add_watch(s.loop, r.read_fd, poll_in(), task_remote_on_readable, cast(void*, r))
	return r


void task_remote_free(task_remote* r):
	int i = 0
	while (i < r.pending.length):
		free(cast(void*, r.pending[i]))
		i = i + 1
	list_free[task_remote_msg*](r.pending)
	close(r.read_fd)
	if (r.write_fd != r.read_fd):
		close(r.write_fd)
	free(cast(void*, r))


# Wake target (parked in park number seq) from any thread.
void task_remote_wake(task_remote* r, task* target, int seq, int value):
	task_remote_msg* m = new task_remote_msg(task_remote_msg_wake(), 0, target, seq, value)
	task_remote_post(r, m)


# Spawn g on r's scheduler from any thread.
void task_remote_spawn(task_remote* r, generator* g):
	task_remote_msg* m = new task_remote_msg(task_remote_msg_spawn(), g, 0, 0, 0)
	if (cast(int, r.counter) != 0):
		atomic_add(r.counter, 1)
	task_remote_post(r, m)


/* Blocking work on a helper thread. */

type task_blocking_fn = fn(void*) -> int


struct task_blocking_job:
	task_blocking_fn* func
	void* arg
	int result
	task_remote* remote
	task* waiter
	int seq


void task_blocking_main(void* p):
	task_blocking_job* job = cast(task_blocking_job*, p)
	job.result = job.func(job.arg)
	task_remote_wake(job.remote, job.waiter, job.seq, 0)


# Run func(arg) on a new thread and park the calling task (not its
# thread) until it returns; returns func's result. The wait cannot be
# cancelled or cut short by a deadline -- func is already running and
# arg may live on this task's stack -- but a cancellation that arrives
# meanwhile is seen by the task's next await.
int task_spawn_blocking(task_blocking_fn* func, void* arg):
	task* t = task_current()
	task_remote* r = task_remote_attach(task_sched(t))
	task_blocking_job* job = new task_blocking_job()
	job.func = func
	job.arg = arg
	job.result = 0
	job.remote = r
	job.waiter = t
	# task_park bumps park_seq before suspending; the helper cannot post
	# before then because the wake is processed on this thread.
	job.seq = t.park_seq + 1
	int saved = t.shielded
	t.shielded = 1
	wthread* th = thread_spawn(task_blocking_main, cast(void*, job))
	task_park(t, task_state_waiting_external(), -1, 0)
	t.shielded = saved
	thread_join(th)
	int result = job.result
	free(cast(void*, job))
	return result


/* Cross-thread channel. */

struct task_xwaiter:
	task* owner
	task_remote* remote
	int seq
	int value
	int status          # task_waiter_* values, written under the channel lock


struct task_xchan:
	wmutex lock
	deque[int]* buffer
	int capacity
	int closed
	list[task_xwaiter*] senders
	list[task_xwaiter*] receivers


task_xchan* task_xchan_new(int capacity):
	task_xchan* ch = new task_xchan()
	mutex_init(&ch.lock)
	ch.buffer = deque_new[int]()
	if (capacity < 0):
		capacity = 0
	ch.capacity = capacity
	ch.closed = 0
	ch.senders = new list[task_xwaiter*]
	ch.receivers = new list[task_xwaiter*]
	return ch


void task_xchan_free(task_xchan* ch):
	deque_free[int](ch.buffer)
	list_free[task_xwaiter*](ch.senders)
	list_free[task_xwaiter*](ch.receivers)
	free(cast(void*, ch))


# Complete a parked peer (channel lock held). A peer on the calling
# thread's own scheduler is woken directly; others through their inbox.
void task_xwaiter_fire(task_xwaiter* w, int status):
	w.status = status
	task* me = task_active_get()
	if ((cast(int, me) != 0) && (task_sched(me) == task_sched(w.owner))):
		if ((w.owner.park_seq == w.seq) && task_is_parked(w.owner)):
			task_wake(w.owner, 0)
		return
	task_remote_wake(w.remote, w.owner, w.seq, 0)


task_xwaiter* task_xchan_take_first(list[task_xwaiter*] waiters):
	if (waiters.length == 0):
		return 0
	task_xwaiter* w = waiters[0]
	list_remove_at[task_xwaiter*](waiters, 0)
	return w


void task_xchan_forget(list[task_xwaiter*] waiters, task_xwaiter* w):
	int i = 0
	while (i < waiters.length):
		if (waiters[i] == w):
			list_remove_at[task_xwaiter*](waiters, i)
			return
		i = i + 1


void task_xchan_close(task_xchan* ch):
	mutex_lock(&ch.lock)
	ch.closed = 1
	while (ch.receivers.length > 0):
		task_xwaiter_fire(task_xchan_take_first(ch.receivers), task_waiter_closed())
	while (ch.senders.length > 0):
		task_xwaiter_fire(task_xchan_take_first(ch.senders), task_waiter_closed())
	mutex_unlock(&ch.lock)


# Lock held. 0 sent, task_err_would_block(), task_err_closed().
int task_xchan_try_send_locked(task_xchan* ch, int value):
	if (ch.closed):
		return task_err_closed()
	task_xwaiter* r = task_xchan_take_first(ch.receivers)
	if (cast(int, r) != 0):
		r.value = value
		task_xwaiter_fire(r, task_waiter_completed())
		return 0
	if (ch.buffer.length < ch.capacity):
		deque_push_back[int](ch.buffer, value)
		return 0
	return task_err_would_block()


# Lock held. 1 received, 0 closed and drained, task_err_would_block().
int task_xchan_try_recv_locked(task_xchan* ch, int* out):
	if (ch.buffer.length > 0):
		*out = deque_pop_front[int](ch.buffer)
		task_xwaiter* s = task_xchan_take_first(ch.senders)
		if (cast(int, s) != 0):
			deque_push_back[int](ch.buffer, s.value)
			task_xwaiter_fire(s, task_waiter_completed())
		return 1
	task_xwaiter* w = task_xchan_take_first(ch.senders)
	if (cast(int, w) != 0):
		*out = w.value
		task_xwaiter_fire(w, task_waiter_completed())
		return 1
	if (ch.closed):
		return 0
	return task_err_would_block()


int task_xchan_try_send(task_xchan* ch, int value):
	mutex_lock(&ch.lock)
	int r = task_xchan_try_send_locked(ch, value)
	mutex_unlock(&ch.lock)
	return r


int task_xchan_try_recv(task_xchan* ch, int* out):
	mutex_lock(&ch.lock)
	int r = task_xchan_try_recv_locked(ch, out)
	mutex_unlock(&ch.lock)
	return r


void task_xwaiter_init(task_xwaiter* w, task* t):
	w.owner = t
	w.remote = task_remote_attach(task_sched(t))
	w.seq = t.park_seq + 1
	w.value = 0
	w.status = task_waiter_pending()


# Park after registering w (lock held on entry, released here). Returns
# the park result; on a timeout or cancellation that raced a peer
# completing w, the peer's completion wins.
int task_xchan_park(task_xchan* ch, list[task_xwaiter*] queue, task_xwaiter* w, int timeout_ms):
	task* t = w.owner
	queue.push(w)
	mutex_unlock(&ch.lock)
	int r = task_park(t, task_state_waiting_external(), timeout_ms, task_err_timed_out())
	mutex_lock(&ch.lock)
	if (w.status == task_waiter_pending()):
		task_xchan_forget(queue, w)
	mutex_unlock(&ch.lock)
	return r


# Send from a task on any thread, parking up to timeout_ms (-1: forever)
# while full. Returns 0, task_err_closed(), task_err_timed_out() or
# task_err_cancelled().
int task_xchan_send_timeout(task_xchan* ch, int value, int timeout_ms):
	mutex_lock(&ch.lock)
	int r = task_xchan_try_send_locked(ch, value)
	if (r != task_err_would_block()):
		mutex_unlock(&ch.lock)
		return r
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		mutex_unlock(&ch.lock)
		return err
	task_xwaiter w
	task_xwaiter_init(&w, t)
	w.value = value
	r = task_xchan_park(ch, ch.senders, &w, timeout_ms)
	if (w.status == task_waiter_completed()):
		return 0
	if (w.status == task_waiter_closed()):
		return task_err_closed()
	return r


int task_xchan_send(task_xchan* ch, int value):
	return task_xchan_send_timeout(ch, value, -1)


# Receive from a task on any thread. Returns 1 with *out set, 0 once
# closed and drained, or a negative error.
int task_xchan_recv_timeout(task_xchan* ch, int* out, int timeout_ms):
	mutex_lock(&ch.lock)
	int r = task_xchan_try_recv_locked(ch, out)
	if (r != task_err_would_block()):
		mutex_unlock(&ch.lock)
		return r
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		mutex_unlock(&ch.lock)
		return err
	task_xwaiter w
	task_xwaiter_init(&w, t)
	r = task_xchan_park(ch, ch.receivers, &w, timeout_ms)
	if (w.status == task_waiter_completed()):
		*out = w.value
		return 1
	if (w.status == task_waiter_closed()):
		return 0
	return r


int task_xchan_recv(task_xchan* ch, int* out):
	return task_xchan_recv_timeout(ch, out, -1)


/* The runtime: N workers, each a thread running its own scheduler. */

struct task_runtime_worker:
	void* rt            # task_runtime*
	int index
	task_scheduler* sched
	task_remote* remote
	wthread* thread


struct task_runtime:
	int nthreads
	list[task_runtime_worker*] workers
	int next            # round-robin cursor
	int outstanding     # tasks spawned and not yet done, all workers
	int stopping


int task_runtime_stop(task_runtime* rt);


# Scheduler hooks: count every task that starts or finishes on a worker.
void task_runtime_on_done(task* t, void* context):
	task_runtime* rt = cast(task_runtime*, context)
	if (atomic_add(&rt.outstanding, -1) == 1):
		task_runtime_stop(rt)


void task_runtime_on_spawn(task* t, void* context):
	task_runtime* rt = cast(task_runtime*, context)
	atomic_add(&rt.outstanding, 1)


# nthreads worker schedulers (<= 0: 4). Workers start in
# task_runtime_run.
task_runtime* task_runtime_new(int nthreads):
	task_runtime_install()
	if (nthreads <= 0):
		nthreads = 4
	task_runtime* rt = new task_runtime(nthreads, new list[task_runtime_worker*], 0, 0, 0)
	int i = 0
	while (i < nthreads):
		task_runtime_worker* w = new task_runtime_worker()
		w.rt = cast(void*, rt)
		w.index = i
		w.sched = task_scheduler_new()
		w.sched.on_done = task_runtime_on_done
		w.sched.on_done_context = cast(void*, rt)
		w.sched.on_spawn = task_runtime_on_spawn
		w.sched.on_spawn_context = cast(void*, rt)
		w.remote = task_remote_attach(w.sched)
		w.remote.counter = &rt.outstanding
		w.thread = 0
		rt.workers.push(w)
		i = i + 1
	return rt


int task_runtime_threads(task_runtime* rt):
	return rt.nthreads


# Spawn g on worker index (mod the worker count), from any thread.
void task_runtime_spawn_on(task_runtime* rt, int index, generator* g):
	task_runtime_worker* w = rt.workers[index % rt.nthreads]
	task_remote_spawn(w.remote, g)


# Spawn g on the next worker in round-robin order, from any thread.
void task_runtime_spawn(task_runtime* rt, generator* g):
	int index = atomic_add(&rt.next, 1)
	if (index < 0):
		index = 0 - index
	task_runtime_spawn_on(rt, index, g)


# The worker the calling task runs on, or -1 outside the runtime.
int task_runtime_worker_index(task_runtime* rt):
	task* t = task_active_get()
	if (cast(int, t) == 0):
		return -1
	int i = 0
	while (i < rt.nthreads):
		if (rt.workers[i].sched == task_sched(t)):
			return i
		i = i + 1
	return -1


# Ask every worker to finish its current pass and exit (tasks still
# parked are abandoned). Called automatically when the last task is
# done.
int task_runtime_stop(task_runtime* rt):
	if (atomic_cas(&rt.stopping, 0, 1) != 0):
		return 0
	int i = 0
	while (i < rt.nthreads):
		task_remote_msg* m = new task_remote_msg(task_remote_msg_nop(), 0, 0, 0, 0)
		task_remote_post(rt.workers[i].remote, m)
		i = i + 1
	return 1


void task_runtime_worker_main(void* p):
	task_runtime_worker* w = cast(task_runtime_worker*, p)
	task_runtime* rt = cast(task_runtime*, w.rt)
	while (rt.stopping == 0):
		int err = task_run_pass(w.sched, -1, 1)
		if ((err < 0) && (err != task_err_deadlock())):
			break


# Start the workers and wait until every spawned task (including those
# spawned later, from any worker) has finished. Returns 0.
int task_runtime_run(task_runtime* rt):
	if (rt.outstanding == 0):
		return 0
	int i = 0
	while (i < rt.nthreads):
		task_runtime_worker* w = rt.workers[i]
		w.thread = thread_spawn(task_runtime_worker_main, cast(void*, w))
		i = i + 1
	i = 0
	while (i < rt.nthreads):
		thread_join(rt.workers[i].thread)
		rt.workers[i].thread = 0
		i = i + 1
	return 0


void task_runtime_free(task_runtime* rt):
	int i = 0
	while (i < rt.nthreads):
		task_runtime_worker* w = rt.workers[i]
		task_scheduler* s = w.sched
		task_remote_free(w.remote)
		s.remote = 0
		task_scheduler_free(s)
		free(cast(void*, w))
		i = i + 1
	list_free[task_runtime_worker*](rt.workers)
	free(cast(void*, rt))
