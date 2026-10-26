# The calling thread's kernel id, for the REPL's thread checks (repl/core.w).
# Linux x86-64 gettid.
int arch_gettid():
	return syscall(186, 0, 0, 0)


# 1 while the thread tid of this process still exists (tgkill with signal
# 0), for wdbg's stop lock (repl/core.w repl_host_enter).
int arch_thread_alive(int tid):
	return syscall(234, getpid(), tid, 0) == 0


# Compare-and-swap for wdbg's stop lock; returns the previous value.
int arch_thread_cas(int* word, int expected, int desired):
	return atomic_cas(word, expected, desired)
