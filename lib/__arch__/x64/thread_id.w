# The calling thread's kernel id, for the REPL's thread checks (repl/core.w).
# Linux x86-64 gettid.
int arch_gettid():
	return syscall(186, 0, 0, 0)
