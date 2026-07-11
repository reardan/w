/*
Phi-accrual failure detection over heartbeat inter-arrival times
(docs/projects/distributed.md, phase 2; Hayashibara et al. 2004, as
deployed in Cassandra).

Instead of a binary alive/dead verdict, the detector emits a suspicion
level phi = -log10(P_later(t)), where P_later(t) is the probability that
the next heartbeat arrives more than t ms after the last one, estimated
from a sliding window of observed inter-arrival intervals. Callers pick
their own threshold (Cassandra's convention is 8.0: phi >= 8 means the
estimated chance the peer is still alive is under 1e-8).

EXPONENTIAL SIMPLIFICATION: lib/fmath.w has no exp or log, so instead of
the paper's normal-distribution tail this module models inter-arrival
times as exponential with the window's mean — Cassandra itself made the
same switch (CASSANDRA-2597). Under an exponential model
P_later(t) = exp(-t / mean), hence

  phi(t) = -log10(exp(-t / mean)) = (t / mean) * log10(e)
         = 0.4342944819 * t / mean

one float multiply and divide, no transcendentals. Regular heartbeats
every M ms put phi at exactly log10(e) ~ 0.434 one period after the
last beat, and phi grows linearly with silence from there.

ALL time arithmetic goes through the monotime.w helpers: monotonic_ms
wraps a 32-bit int after ~24.8 days on the x86 target, so timestamps are
never compared or subtracted inline here. Word-size budget: the running
interval sum assumes window_cap * max-interval stays under 2^31 ms,
comfortably true for any sane window over heartbeats.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.monotime


struct failure_detector:
	int window_cap        # max retained inter-arrival intervals (>= 1)
	list[int] intervals   # sliding window of inter-arrival times, ms
	int interval_sum      # running sum of the window, for O(1) mean
	int last_heartbeat    # monotonic ms timestamp of the newest heartbeat
	int has_heartbeat     # 0 until the first heartbeat is recorded


failure_detector* fd_new(int window_cap):
	assert1(window_cap >= 1)
	failure_detector* fd = new failure_detector()
	fd.window_cap = window_cap
	fd.intervals = new list[int]
	fd.interval_sum = 0
	fd.last_heartbeat = 0
	fd.has_heartbeat = 0
	return fd


# Frees the detector struct itself; the interval list storage is
# runtime-managed (matching repair_plan_free in quorum.w).
void fd_free(failure_detector* fd):
	free(fd)


# Record a heartbeat at monotonic time now_ms. The first call only
# stores the timestamp; every later call pushes the wrap-safe delta
# since the previous heartbeat into the window, evicting the oldest
# interval once the window exceeds window_cap.
void fd_heartbeat(failure_detector* fd, int now_ms):
	if (fd.has_heartbeat == 0):
		fd.has_heartbeat = 1
		fd.last_heartbeat = now_ms
		return
	int delta = mono_delta_ms(now_ms, fd.last_heartbeat)
	assert1(delta >= 0)
	fd.intervals.push(delta)
	fd.interval_sum = fd.interval_sum + delta
	while (fd.intervals.length > fd.window_cap):
		fd.interval_sum = fd.interval_sum - fd.intervals[0]
		fd.intervals.remove(0)
	fd.last_heartbeat = now_ms


# Inter-arrival intervals currently retained (0 until the second
# heartbeat).
int fd_sample_count(failure_detector* fd):
	return fd.intervals.length


# Mean of the retained intervals; requires at least one sample.
float fd_mean_interval_ms(failure_detector* fd):
	assert1(fd.intervals.length >= 1)
	float total = fd.interval_sum
	float n = fd.intervals.length
	return total / n


# Suspicion level at monotonic time now_ms (see header for the formula).
# With no interval sample yet there is no model to judge silence
# against, so phi is 0.0: unknown means not suspicious, and callers
# needing liveness before the second heartbeat use fd_timed_out.
# Elapsed silence is clamped below at 0 (a heartbeat "from the future"
# just reads as no silence).
float fd_phi(failure_detector* fd, int now_ms):
	if (fd.intervals.length < 1):
		return 0.0
	int elapsed = mono_delta_ms(now_ms, fd.last_heartbeat)
	if (elapsed <= 0):
		return 0.0
	float mean = fd_mean_interval_ms(fd)
	if (mean <= 0.0):
		# Degenerate window: every retained interval was 0 ms, so any
		# positive silence is unboundedly suspicious. Skip the division
		# and return a phi past any practical threshold.
		return 1000000000.0
	float t = elapsed
	return 0.4342944819 * t / mean


# 1 when the suspicion level has reached threshold (>=, so a phi exactly
# at the threshold counts). The conventional threshold is 8.0.
int fd_suspect(failure_detector* fd, int now_ms, float threshold):
	if (fd_phi(fd, now_ms) >= threshold):
		return 1
	return 0


# Trivial fixed-timeout detector for callers that want one: 1 when no
# heartbeat was ever recorded, or when at least timeout_ms of silence
# has elapsed since the last one.
int fd_timed_out(failure_detector* fd, int now_ms, int timeout_ms):
	if (fd.has_heartbeat == 0):
		return 1
	if (mono_delta_ms(now_ms, fd.last_heartbeat) >= timeout_ms):
		return 1
	return 0
