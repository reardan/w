# The calling thread's kernel id, for the REPL's thread checks (repl/core.w).
# Linux i386 gettid.
int arch_gettid():
	return syscall(224, 0, 0, 0)
