# The calling thread's kernel id, for the REPL's thread checks (repl/core.w).
# No in-process REPL threads on this target: every caller is the main thread.
int arch_gettid():
	return getpid()


# Only the main thread exists here.
int arch_thread_alive(int tid):
	return 1


# No debuggee threads stop here (repl_threads_enable is x86/x64 Linux
# only), so the stop lock needs no atomic update.
int arch_thread_cas(int* word, int expected, int desired):
	int previous = *word
	if (previous == expected): *word = desired
	return previous
