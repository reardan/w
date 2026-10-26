# Debuggee for tests/safe_session_debugger_test.w (#713): a fault on a
# worker thread stops wdbg there for a post-mortem look; it cannot resume.
import lib.lib
import lib.thread


int divisor


void divide(void* out):
	int* result = cast(int*, out)
	*result = 100 / divisor


int main():
	int result = 0
	wthread* worker = thread_spawn(divide, &result)
	thread_join(worker)
	return result
