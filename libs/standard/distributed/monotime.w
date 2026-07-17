/*
Wrap-safe arithmetic for monotonic millisecond timestamps
(docs/projects/distributed.md, phase 1).

monotonic_ms (lib/time.w) wraps a 32-bit int after ~24.8 days on the
x86 target, so raw comparisons like (now < deadline) go wrong near the
wrap point. Every helper here subtracts first: two's-complement
subtraction is exact modulo the word size, so deltas come out right on
every target as long as the true distance between the two timestamps is
under 2^31 ms (~24.8 days). This is serial-number arithmetic in the
RFC 1982 sense.

Protocol code (failure detectors, election timers, lease expiry) must
never compare monotonic timestamps with < directly; route every timing
decision through these helpers.
*/
import lib.lib
import lib.assert


# Signed milliseconds from then to now. Correct across the x86 wrap for
# true distances under ~24.8 days.
int mono_delta_ms(int now, int then):
	return now - then


# 1 when timestamp a is earlier than timestamp b.
int mono_before(int a, int b):
	if (mono_delta_ms(a, b) < 0):
		return 1
	return 0


# Deadline timeout_ms after now. The sum may wrap on the x86 target;
# that is fine, mono_expired/mono_remaining_ms handle it.
int mono_deadline(int now, int timeout_ms):
	assert1(timeout_ms >= 0)
	return now + timeout_ms


# 1 once now has reached or passed the deadline.
int mono_expired(int now, int deadline):
	if (mono_delta_ms(now, deadline) >= 0):
		return 1
	return 0


# Milliseconds still to run before the deadline, clamped at 0.
int mono_remaining_ms(int now, int deadline):
	int d = mono_delta_ms(deadline, now)
	if (d < 0):
		return 0
	return d
