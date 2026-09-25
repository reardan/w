/*
Task-aware synchronization (docs/projects/async.md): a mutex, a
counting semaphore and a one-shot/resettable event for tasks on one
scheduler. Waiting parks only the calling task, never the thread --
unlike lib/thread.w's futex mutex and condvar, which would stall every
task on the loop.

Every blocking call takes a timeout_ms (-1 waits forever) and follows
the runtime's error convention: 0 on success, task_err_timed_out(),
task_err_cancelled(), or the task's deadline. Waiters are served FIFO
and ownership is handed over directly, so a released lock cannot be
stolen by a task that was not waiting.
*/
import lib.lib
import lib.task


/* Mutex. */

struct task_mutex:
	int locked
	task_wait_queue waiters


task_mutex* task_mutex_new():
	task_mutex* m = new task_mutex()
	m.locked = 0
	task_wait_queue_init(&m.waiters)
	return m


void task_mutex_free(task_mutex* m):
	free(cast(void*, m))


# 1 when the lock was free and is now held, 0 otherwise. Never parks.
int task_mutex_try_lock(task_mutex* m):
	if (m.locked):
		return 0
	m.locked = 1
	return 1


int task_mutex_lock_timeout(task_mutex* m, int timeout_ms):
	if (m.locked == 0):
		m.locked = 1
		return 0
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		return err
	task_waiter w
	task_waiter_init(&w, t)
	int r = task_park_on(&m.waiters, &w, timeout_ms)
	if (w.status == task_waiter_completed):
		return 0
	return r


int task_mutex_lock(task_mutex* m):
	return task_mutex_lock_timeout(m, -1)


# Hand the lock to the longest waiter, or free it.
void task_mutex_unlock(task_mutex* m):
	task_waiter* w = task_wait_queue_first(&m.waiters)
	if (cast(int, w) != 0):
		task_waiter_fire(w, task_waiter_completed, 0)
		return
	m.locked = 0


/* Counting semaphore. */

struct task_semaphore:
	int permits
	task_wait_queue waiters


task_semaphore* task_semaphore_new(int permits):
	task_semaphore* sem = new task_semaphore()
	sem.permits = permits
	task_wait_queue_init(&sem.waiters)
	return sem


void task_semaphore_free(task_semaphore* sem):
	free(cast(void*, sem))


int task_semaphore_try_acquire(task_semaphore* sem):
	if (sem.permits > 0):
		sem.permits = sem.permits - 1
		return 1
	return 0


int task_semaphore_acquire_timeout(task_semaphore* sem, int timeout_ms):
	if (task_wait_queue_empty(&sem.waiters) && (sem.permits > 0)):
		sem.permits = sem.permits - 1
		return 0
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		return err
	task_waiter w
	task_waiter_init(&w, t)
	int r = task_park_on(&sem.waiters, &w, timeout_ms)
	if (w.status == task_waiter_completed):
		return 0
	return r


int task_semaphore_acquire(task_semaphore* sem):
	return task_semaphore_acquire_timeout(sem, -1)


# Return one permit: straight to the longest waiter when there is one.
void task_semaphore_release(task_semaphore* sem):
	task_waiter* w = task_wait_queue_first(&sem.waiters)
	if (cast(int, w) != 0):
		task_waiter_fire(w, task_waiter_completed, 0)
		return
	sem.permits = sem.permits + 1


/* Event: a flag tasks can wait for. */

struct task_event:
	int set
	task_wait_queue waiters


task_event* task_event_new():
	task_event* e = new task_event()
	e.set = 0
	task_wait_queue_init(&e.waiters)
	return e


void task_event_free(task_event* e):
	free(cast(void*, e))


# Set the flag and wake every waiter. Stays set until task_event_clear.
void task_event_set(task_event* e):
	e.set = 1
	task_wait_queue_fire_all(&e.waiters, task_waiter_completed, 0)


void task_event_clear(task_event* e):
	e.set = 0


int task_event_is_set(task_event* e):
	return e.set


# Wait until the flag is set. Returns 0 or an error.
int task_event_wait_timeout(task_event* e, int timeout_ms):
	if (e.set):
		return 0
	task* t = task_current()
	int err = task_park_check(t)
	if (err < 0):
		return err
	task_waiter w
	task_waiter_init(&w, t)
	int r = task_park_on(&e.waiters, &w, timeout_ms)
	if (w.status == task_waiter_completed):
		return 0
	return r


int task_event_wait(task_event* e):
	return task_event_wait_timeout(e, -1)
