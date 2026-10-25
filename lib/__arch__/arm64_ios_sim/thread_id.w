# The calling thread's kernel id, for the REPL's thread checks (repl/core.w).
# No in-process REPL threads on this target: every caller is the main thread.
int arch_gettid():
	return getpid()
