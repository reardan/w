# The calling thread's kernel id, for the REPL's thread checks (repl/core.w).
# Linux arm64 gettid.
int arch_gettid():
	return syscall(178, 0, 0, 0)
