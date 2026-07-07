# Windows twin of dynamic_test.w: call the C runtime (msvcrt.dll) through
# extern declarations and check the results against the kernel32-backed
# runtime wrappers. Exercises the Win64 ABI shims (rcx/rdx/r8/r9, shadow
# space), the variadic inline path with on-stack arguments, and float
# argument/result passing through xmm registers.

c_lib "msvcrt.dll"

# _getpid rather than getpid: the runtime's kernel32 wrappers
# (auto-imported into every program) already define getpid.
extern int _getpid()
extern int puts(char* s)
extern int printf(char* fmt, ...)
extern float64 sqrt(float64 x)
# The entry stub exits through ExitProcess, bypassing the CRT's atexit
# flush, so buffered stdout must be flushed explicitly.
extern int fflush(int stream)


int _main():
	int crt_pid = _getpid()
	int win_pid = getpid()

	# Nine arguments so the variadic call exercises its on-stack argument
	# path past the four register slots.
	printf(c"stack args: %d %d %d %d %d %d %d %d\x0a", 1, 2, 3, 4, 5, 6, 7, 8)
	# Promoted float64 in a variadic call: win64 passes it in both the
	# positional GP register and the xmm register.
	printf(c"float arg: %.2f\x0a", 2.5)

	int rc = 0
	if (crt_pid != win_pid):
		puts(c"FAIL: msvcrt _getpid disagrees with GetCurrentProcessId")
		rc = 1
	else if (sqrt(1024.0) != 32.0):
		puts(c"FAIL: sqrt float ABI")
		rc = 1
	else:
		puts(c"dynamic linking OK")

	fflush(0)
	return rc
