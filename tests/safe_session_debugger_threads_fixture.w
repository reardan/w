# Debuggee for tests/safe_session_debugger_test.w (#713): wdbg gives the
# debuggee per-thread storage, so lib/safe_thread.w loads, and a stop on a
# checked worker thread shows that thread's checked locals and
# thread_local values, evaluates on its stack and resumes it.
import lib.lib
import lib.safe_thread


thread_local int seen


struct job:
	int amount


type job_fn = fn[](own job*) -> int


# Checked code reaches the thread_local through an unsafe boundary.
void note_seen(int value):
	unsafe:
		seen = value


int seen_now():
	int value = 0
	unsafe:
		value = seen
	return value


int run_job(own job* work):
	note_seen(work.amount + 1)
	ref job* view = work
	int doubled = view.amount * 2
	debugger
	return doubled + seen_now()


# Evaluated at a worker stop: its fault rolls back that evaluation alone.
int crash(int zero):
	return 10 / zero


void report(int result):
	unsafe:
		println(itoa(result))
		println(itoa(seen))


int main():
	note_seen(100)
	job_fn* entry = run_job
	optown WSafeThread* thread = safe_thread_spawn(entry, new job(20))
	if (!thread): return 1
	own WSafeThread* started = thread
	int result = safe_thread_join(started)
	report(result)
	# Two threads stop at the same statement: one stop at a time
	optown WSafeThread* left = safe_thread_spawn(entry, new job(1))
	optown WSafeThread* right = safe_thread_spawn(entry, new job(2))
	if (!left): return 1
	if (!right): return 1
	own WSafeThread* first = left
	own WSafeThread* second = right
	int both = safe_thread_join(first) + safe_thread_join(second)
	report(both)
	return result + both - 61 - 11
