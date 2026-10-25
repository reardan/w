# Helpers loaded into the REPL by tests/safe_repl_session_test.w (with
# --no_main) for checked lock guards and threads in a session (#713). It
# runs without W_DEBUG_ALLOC: the guard-page allocator's two mappings per
# block exhaust vm.max_map_count while the in-process compiler retains the
# thread runtime. The REPL reports the held guards it releases at :reset
# and exit, which is how those unlocks are counted.
import lib.lib
import lib.safe_thread


own int* safe_repl_boxed(int value):
	own int* item = new int
	*item = value
	return item


# 1 when nobody holds the mutex: the probe guard is dropped on return.
int safe_repl_unlocked(ref WSafeMutex[int]* mutex):
	optown[t] WSafeGuard[int]* probe = safe_mutex_try_lock(mutex)
	if (!probe): return 0
	return 1


int safe_repl_bump(refmut[a] WSafeGuard[int]* guard):
	refmut int* value = safe_guard_value(guard)
	*value = *value + 1
	return *value


# A checked thread whose handle a session binding can hold: replacing the
# binding, :reset and exit join it (its drop waits for the child).
struct safe_repl_job:
	int amount


type safe_repl_job_fn = fn[](own safe_repl_job*) -> int


int safe_repl_job_entry(own safe_repl_job* job):
	return job.amount * 2


optown WSafeThread* safe_repl_start(int amount):
	safe_repl_job_fn* entry = safe_repl_job_entry
	return safe_thread_spawn(entry, new safe_repl_job(amount))


int safe_repl_finish(optown WSafeThread* thread):
	if (!thread): return -1
	own WSafeThread* started = thread
	return safe_thread_join(started)


int main():
	return 0
