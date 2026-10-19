# Checked synchronization runtime behavior (#699 deliverable 4): guards
# release their mutex on every exit path (return, break, continue, early
# unlock, replacement, absent try-lock), mutexes and atomics contended
# across fork-join trees and spawned threads reach exact final counts,
# release/acquire publication, and each mutex payload is destroyed exactly
# once. main returns the number of allocations leaked by the measured round.
import lib.memory_debug
import lib.safe_thread


own int* boxed(int value):
	own int* item = new int
	*item = value
	return item


# 1 when nobody holds the mutex: the probe guard is dropped on return.
int unlocked(ref WSafeMutex* mutex):
	optown[t] WSafeGuard* probe = safe_mutex_try_lock(mutex)
	if (!probe): return 0
	return 1


int read_locked(ref WSafeMutex* mutex):
	own[a] WSafeGuard* guard = safe_mutex_lock(mutex)
	refmut int* value = safe_guard_value(guard)
	return *value


int add_then_return(ref WSafeMutex* mutex, int stop):
	own[a] WSafeGuard* guard = safe_mutex_lock(mutex)
	refmut int* value = safe_guard_value(guard)
	*value = *value + 1
	if (stop): return 7
	*value = *value + 100
	return 0


int add_in_loop(ref WSafeMutex* mutex):
	int counted = 0
	for i in range(10):
		own[a] WSafeGuard* guard = safe_mutex_lock(mutex)
		refmut int* value = safe_guard_value(guard)
		*value = *value + 1
		if (i == 2): continue
		if (i == 5): break
		counted = counted + 1
	int extra = 0
	while (extra < 3):
		own[a] WSafeGuard* guard = safe_mutex_lock(mutex)
		extra = extra + 1
	return counted


int replace_guard(ref WSafeMutex* first, ref WSafeMutex* second):
	optown[a] WSafeGuard* guard = safe_mutex_lock(first)
	if (unlocked(first)): return 1
	guard = safe_mutex_lock(second)
	if (unlocked(first) == 0): return 2
	if (unlocked(second)): return 3
	guard = 0
	if (unlocked(second) == 0): return 4
	return 0


struct Holder:
	own[h] WSafeGuard* guard
	int tag


own[a] Holder* hold(ref[a] WSafeMutex* mutex, int tag):
	return new Holder(safe_mutex_lock(mutex), tag)


int exit_paths():
	own WSafeMutex* mutex = safe_mutex_new(boxed(0))
	own WSafeMutex* other = safe_mutex_new(boxed(0))
	if (unlocked(mutex) == 0): return 1
	if (add_then_return(mutex, 1) != 7): return 2
	if (unlocked(mutex) == 0): return 3
	if (add_then_return(mutex, 0) != 0): return 4
	if (unlocked(mutex) == 0): return 5
	if (add_in_loop(mutex) != 4): return 6
	if (unlocked(mutex) == 0): return 7
	if (replace_guard(mutex, other) != 0): return 8
	if (unlocked(mutex) == 0): return 9
	own[a] WSafeGuard* guard = safe_mutex_lock(mutex)
	if (unlocked(mutex)): return 10
	safe_guard_unlock(guard)
	if (unlocked(mutex) == 0): return 11
	if (1):
		own[b] Holder* holder = hold(mutex, 3)
		if (unlocked(mutex)): return 12
		if (holder.tag != 3): return 13
	if (unlocked(mutex) == 0): return 14
	# 1 + 101 + 6 increments from the loop.
	if (read_locked(mutex) != 108): return 15
	return 0


type Contend = fn[](ref WSafeMutex*) -> int


int add_locked(ref WSafeMutex* mutex):
	for i in range(2000):
		own[a] WSafeGuard* guard = safe_mutex_lock(mutex)
		refmut int* value = safe_guard_value(guard)
		*value = *value + 1
	return 1


# Each level shares the same mutex with two more threads: level n runs
# 2^n contenders and returns that count.
int level1(ref WSafeMutex* mutex):
	Contend* entry = add_locked
	return safe_thread_fork_join(entry, mutex, mutex)


int level2(ref WSafeMutex* mutex):
	Contend* entry = level1
	return safe_thread_fork_join(entry, mutex, mutex)


int level3(ref WSafeMutex* mutex):
	Contend* entry = level2
	return safe_thread_fork_join(entry, mutex, mutex)


type AtomicContend = fn[](ref WSafeAtomic*) -> int


int add_atomic(ref WSafeAtomic* counter):
	for i in range(5000): safe_atomic_fetch_add(counter, 1, memory_order_relaxed)
	# Increment by compare-exchange as well; failures reload and retry.
	for i in range(1000):
		int seen = safe_atomic_load(counter, memory_order_relaxed)
		while (safe_atomic_compare_exchange(counter, seen, seen + 1, memory_order_acq_rel, memory_order_relaxed) != seen):
			seen = safe_atomic_load(counter, memory_order_acquire)
	return 1


int atomic_level1(ref WSafeAtomic* counter):
	AtomicContend* entry = add_atomic
	return safe_thread_fork_join(entry, counter, counter)


int atomic_level2(ref WSafeAtomic* counter):
	AtomicContend* entry = atomic_level1
	return safe_thread_fork_join(entry, counter, counter)


struct Channel:
	own WSafeAtomic* role
	own WSafeAtomic* data
	own WSafeAtomic* ready


type Exchange = fn[](ref Channel*) -> int


# Whichever entry claims role 0 publishes; the other waits for the flag.
# The relaxed data store is visible after the acquire load observes the
# release store that follows it.
int exchange(ref Channel* channel):
	ref WSafeAtomic* role = channel.role
	ref WSafeAtomic* data = channel.data
	ref WSafeAtomic* ready = channel.ready
	if (safe_atomic_fetch_add(role, 1, memory_order_seq_cst) == 0):
		safe_atomic_store(data, 42, memory_order_relaxed)
		safe_atomic_store(ready, 1, memory_order_release)
		return 0
	while (safe_atomic_load(ready, memory_order_acquire) == 0): pass
	return safe_atomic_load(data, memory_order_relaxed)


struct Job:
	own WSafeMutex* mutex
	own WSafeAtomic* counter


type Worker = fn[](own Job*) -> int


# A spawned thread owns the job; it runs its own contended tree on both
# the mutex and the atomic, then destroys them on its way out.
int run_job(own Job* job):
	ref WSafeMutex* mutex = job.mutex
	ref WSafeAtomic* counter = job.counter
	if (level2(mutex) != 4): return -1
	if (atomic_level2(counter) != 4): return -2
	return read_locked(mutex) + safe_atomic_load(counter, memory_order_seq_cst)


int contention():
	own WSafeMutex* mutex = safe_mutex_new(boxed(0))
	ref WSafeMutex* shared = mutex
	if (level3(shared) != 8): return 1
	if (read_locked(shared) != 16000): return 2
	if (unlocked(shared) == 0): return 3
	own WSafeAtomic* counter = safe_atomic_new(0)
	ref WSafeAtomic* lent = counter
	if (atomic_level2(lent) != 4): return 4
	if (safe_atomic_load(lent, memory_order_seq_cst) != 24000): return 5
	own Channel* channel = new Channel(safe_atomic_new(0), safe_atomic_new(0), safe_atomic_new(0))
	ref Channel* line = channel
	Exchange* swap = exchange
	if (safe_thread_fork_join(swap, line, line) != 42): return 6
	# Two spawned threads each own a mutex/atomic pair and contend inside
	# their own trees while the parent contends on its own mutex.
	Worker* worker = run_job
	optown WSafeThread* first = safe_thread_spawn(worker, new Job(safe_mutex_new(boxed(5)), safe_atomic_new(7)))
	optown WSafeThread* second = safe_thread_spawn(worker, new Job(safe_mutex_new(boxed(0)), safe_atomic_new(0)))
	if (level2(shared) != 4): return 7
	if (!first): return 8
	if (!second): return 9
	own WSafeThread* started = first
	own WSafeThread* other = second
	# Each job: 4 x 2000 locked increments, 4 x 6000 atomic increments.
	if (safe_thread_join(started) != 8005 + 24007): return 10
	if (safe_thread_join(other) != 8000 + 24000): return 11
	if (read_locked(shared) != 24000): return 12
	return 0


int exercise():
	int status = exit_paths()
	if (status != 0): return status
	status = contention()
	if (status != 0): return 20 + status
	return 0


int main():
	# The first round installs the per-thread heaps; measure the second.
	int status = exercise()
	if (status != 0): return 100 + status
	int before = 0
	unsafe:
		before = debug_alloc_report_leaks()
	status = exercise()
	if (status != 0): return 100 + status
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return after - before
