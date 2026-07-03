# Dynamic-linking smoke test: call libc through extern declarations and
# check the result against the equivalent raw syscall. Builds on both
# targets (32-bit links the i386 libc, 64-bit the x86-64 libc).

c_lib "libc.so.6"

extern int getpid()
extern int puts(char* s)
extern int printf(char* fmt, int a, int b, int c, int d, int e, int f, int g, int h)
# The entry stub exits with a raw exit_group syscall, bypassing libc's
# atexit flush, so buffered stdout must be flushed explicitly.
extern int fflush(int stream)


# getpid syscall number differs by architecture (x86: 20, x64: 39).
int raw_getpid():
	if (__word_size__ == 8):
		return syscall(39, 0, 0, 0)
	return syscall(20, 0, 0, 0)


int _main():
	int libc_pid = getpid()
	int raw_pid = raw_getpid()

	# Nine arguments so the x64 shim exercises its on-stack argument path.
	printf("stack args: %d %d %d %d %d %d %d %d\x0a", 1, 2, 3, 4, 5, 6, 7, 8)

	int rc = 0
	if (libc_pid != raw_pid):
		puts("FAIL: libc getpid disagrees with the raw syscall")
		rc = 1
	else:
		puts("dynamic linking OK")

	fflush(0)
	return rc
