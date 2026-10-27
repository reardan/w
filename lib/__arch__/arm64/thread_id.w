# The calling thread's kernel id, for the REPL's thread checks (repl/core.w).
# Linux arm64 gettid.
int arch_gettid():
	return syscall(178, 0, 0, 0)


# 1 while the thread tid of this process still exists (tgkill with signal
# 0), for wdbg's stop lock (repl/core.w repl_host_enter).
int arch_thread_alive(int tid):
	return syscall(131, getpid(), tid, 0) == 0


# No debuggee threads stop here (repl_threads_enable is x86/x64 Linux
# only), so the stop lock needs no atomic update.
int arch_thread_cas(int* word, int expected, int desired):
	int previous = *word
	if (previous == expected): *word = desired
	return previous
