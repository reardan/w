# CLOCK_REALTIME as 64-bit (hi, lo) parts on Windows x64. The win64
# clock_gettime reads the performance counter (monotonic) whatever the
# clock id, so the wall clock comes from GetSystemTimeAsFileTime, as
# lib/__arch__/win64/syscalls.w's linux_time does: 100ns ticks since
# 1601-01-01, which is 134774 days before the Unix epoch.
# lib/time.w's time_now_parts is the public entry point.
import lib.lib
import lib.bytes


# Writes Unix seconds as masked 32-bit halves (lib/bytes.w convention)
# and the nanoseconds within that second. Returns 0 or -errno.
int time_arch_realtime(int* hi, int* lo, int* nanoseconds):
	int filetime = 0
	GetSystemTimeAsFileTime(&filetime)
	int seconds = filetime / 10000000 - 134774 * 86400
	bytes_split64(seconds, hi, lo)
	nanoseconds[0] = (filetime % 10000000) * 100
	return 0
