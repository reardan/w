# CLOCK_REALTIME as 64-bit (hi, lo) parts on i386 Linux, past 2038.
#
# time(2) (13) and clock_gettime (265) use the i386 32-bit time_t and
# wrap at 2038-01-19 03:14:07 UTC. clock_gettime64 (403, Linux 5.1+)
# fills a __kernel_timespec of two 64-bit fields, which arrives here as
# four 32-bit words, so the seconds come back as (hi, lo) halves with no
# 64-bit arithmetic. Older kernels answer -ENOSYS; the fallback reads
# the 32-bit clock_gettime and sign-extends its seconds, which is exact
# until 2038. lib/time.w's time_now_parts is the public entry point.
import lib.lib


# struct __kernel_timespec { s64 tv_sec; s64 tv_nsec; }, little-endian.
struct time_x86_timespec64:
	int seconds_lo
	int seconds_hi
	int nanoseconds_lo
	int nanoseconds_hi


struct time_x86_timespec32:
	int seconds
	int nanoseconds


# The pre-5.1 path: 32-bit clock_gettime, valid until 2038.
int time_x86_realtime32(int* hi, int* lo, int* nanoseconds):
	time_x86_timespec32 ts
	ts.seconds = 0
	ts.nanoseconds = 0
	int err = syscall(265, 0, cast(int, &ts), 0)
	if (err < 0):
		return err
	hi[0] = 0
	if (ts.seconds < 0): hi[0] = 0 - 1
	lo[0] = ts.seconds
	nanoseconds[0] = ts.nanoseconds
	return 0


# Writes Unix seconds as masked 32-bit halves (lib/bytes.w convention)
# and the nanoseconds within that second. Returns 0 or -errno.
int time_arch_realtime(int* hi, int* lo, int* nanoseconds):
	time_x86_timespec64 ts
	ts.seconds_lo = 0
	ts.seconds_hi = 0
	ts.nanoseconds_lo = 0
	ts.nanoseconds_hi = 0
	int err = syscall(403, 0, cast(int, &ts), 0)
	if (err == 0 - 38):
		return time_x86_realtime32(hi, lo, nanoseconds)
	if (err < 0):
		return err
	hi[0] = ts.seconds_hi
	lo[0] = ts.seconds_lo
	nanoseconds[0] = ts.nanoseconds_lo
	return 0
