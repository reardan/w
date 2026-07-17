# Dynamic-linking smoke test: call libc through extern declarations and
# check the result against the equivalent raw syscall. Builds on both
# targets (32-bit links the i386 libc, 64-bit the x86-64 libc). Also
# builds and runs on arm64 (dynamic_test_arm64, under qemu via
# tools/run_arm64.sh).
# wbuild: arch=arm64 expect_stdout="dynamic linking OK"

c_lib "libc.so.6"

# getppid rather than getpid: the runtime's syscall wrappers (auto-imported
# into every program) already define getpid, which would clash with the
# libc extern of the same name.
extern int getppid()
extern int puts(char* s)
extern int printf(char* fmt, ...)
# The entry stub exits with a raw exit_group syscall, bypassing libc's
# atexit flush, so buffered stdout must be flushed explicitly.
extern int fflush(int stream)


# getppid syscall number differs by architecture (x86: 64, x64: 110,
# arm64: 173).
int raw_getppid():
	if (__target_isa__ == 1):
		return syscall(173, 0, 0, 0)
	if (__word_size__ == 8):
		return syscall(110, 0, 0, 0)
	return syscall(64, 0, 0, 0)


int _main():
	int libc_pid = getppid()
	int raw_pid = raw_getppid()

	# Nine arguments so the x64 variadic call exercises its on-stack
	# argument path.
	printf(c"stack args: %d %d %d %d %d %d %d %d\x0a", 1, 2, 3, 4, 5, 6, 7, 8)

	int rc = 0
	if (libc_pid != raw_pid):
		puts(c"FAIL: libc getppid disagrees with the raw syscall")
		rc = 1
	else:
		puts(c"dynamic linking OK")

	fflush(0)
	return rc
