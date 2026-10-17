# CLOCK_REALTIME as 64-bit (hi, lo) parts for targets whose
# sys_clock_gettime already reports full word-sized seconds: the 64-bit
# Linux and Darwin targets, and wasm32 (whose WASI stub divides the u64
# nanosecond clock and wraps the seconds to an i32, i.e. exactly the low
# 32 bits, so hi stays 0 until 2106). Imported by the per-arch
# lib/__arch__/<arch>/realtime.w modules; lib/time.w's time_now_parts
# is the public entry point.
import lib.lib
import lib.bytes


struct time_word_timespec:
	int seconds
	int nanoseconds


# Writes Unix seconds as masked 32-bit halves (lib/bytes.w convention)
# and the nanoseconds within that second. Returns 0 or -errno.
int time_arch_realtime(int* hi, int* lo, int* nanoseconds):
	time_word_timespec ts
	ts.seconds = 0
	ts.nanoseconds = 0
	int err = sys_clock_gettime(0, cast(int, &ts))
	if (err < 0):
		return err
	bytes_split64(ts.seconds, hi, lo)
	nanoseconds[0] = ts.nanoseconds
	return 0
