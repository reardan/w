# wbuild: x64 arch=arm64_darwin
# lib/signal.w: a handler installed with signal_install_handler runs on
# delivery, receives the signal number, and execution resumes after it.
# Before the arm64 Darwin path, that target ran x86 thunk bytes (SIGILL).
import lib.testing
import lib.signal


int st_received
int st_count


void st_handler(int sig, int context):
	st_received = sig
	st_count = st_count + 1


# i386 passes the classic 1-argument entry (see lib/signal.w).
void st_entry(int sig):
	st_handler(sig, 0)


int st_handler_address():
	if (__word_size__ == 4): return cast(int, st_entry)
	return cast(int, st_handler)


void test_signal_handler_runs_and_resumes():
	st_received = 0
	st_count = 0
	signal_install_handler(15, st_handler_address(), 0)  # SIGTERM
	assert_equal(0, kill(getpid(), 15))
	assert_equal(15, st_received)
	assert_equal(1, st_count)
	# Reinstalling and delivering again still works.
	signal_install_handler(2, st_handler_address(), 0)  # SIGINT
	assert_equal(0, kill(getpid(), 2))
	assert_equal(2, st_received)
	assert_equal(0, kill(getpid(), 15))
	assert_equal(15, st_received)
	assert_equal(3, st_count)
