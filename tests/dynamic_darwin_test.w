# Darwin dynamic-linking smoke test: bind libSystem functions through
# extern declarations and check one against the equivalent raw BSD
# syscall. Cross-compiled as arm64_darwin on Linux, signed and executed
# natively on the Mac by tools/mac/run_darwin_tests.sh.

c_lib "/usr/lib/libSystem.B.dylib"

# getppid rather than getpid: the runtime's syscall wrappers (auto-imported
# into every program) already define getpid, which would clash with the
# libSystem extern of the same name.
extern int getppid()
extern int puts(char* s)
# The entry stub exits with a raw syscall, bypassing libSystem's atexit
# flush, so buffered stdout must be flushed explicitly.
extern int fflush(int stream)


# BSD getppid is syscall 39 (xnu bsd/kern/syscalls.master).
int raw_getppid():
	return syscall(39, 0, 0, 0)


int _main():
	int libc_pid = getppid()
	int raw_pid = raw_getppid()

	int rc = 0
	if (libc_pid != raw_pid):
		puts(c"FAIL: libSystem getppid disagrees with the raw syscall")
		rc = 1
	else:
		puts(c"darwin dynamic linking OK")

	fflush(0)
	return rc
