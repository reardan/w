# wbuild: x64
import lib.testing
import lib.format
import lib.fmath
import libs.standard.distributed.failure_detector


# Same tolerance idiom as lib/stats_test.w: loose enough for float32
# arithmetic, tight enough for the values asserted here.
void assert_near(float want, float got):
	if (fabs(want - got) > 0.0001):
		print2(c"Assertion failed. wanted float(")
		print2(ftoa(want))
		print2(c") got float(")
		print2(ftoa(got))
		println2(c")")
		exit(1)


void test_no_heartbeats():
	failure_detector* fd = fd_new(4)
	assert_equal(0, fd_sample_count(fd))
	# no samples: phi is exactly 0.0 by construction
	assert1(fd_phi(fd, 1000) == 0.0)
	assert_equal(0, fd_suspect(fd, 1000, 8.0))
	# no heartbeat ever recorded times out under any timeout
	assert_equal(1, fd_timed_out(fd, 1000, 500))
	assert_equal(1, fd_timed_out(fd, 0, 1000000))
	fd_free(fd)


void test_one_heartbeat_no_intervals():
	failure_detector* fd = fd_new(4)
	fd_heartbeat(fd, 1000)
	assert_equal(0, fd_sample_count(fd))
	# one heartbeat gives no interval sample, so phi stays exactly 0.0
	assert1(fd_phi(fd, 1500) == 0.0)
	assert_equal(0, fd_suspect(fd, 1500, 8.0))
	# fixed timeout flips around the elapsed gap (400 ms at now = 1400)
	assert_equal(0, fd_timed_out(fd, 1400, 500))
	assert_equal(1, fd_timed_out(fd, 1500, 500))   # exactly at timeout: >=
	assert_equal(1, fd_timed_out(fd, 1600, 500))
	fd_free(fd)


void test_regular_heartbeats():
	failure_detector* fd = fd_new(16)
	# heartbeats at 1000, 1100, ..., 1900: nine intervals of 100 ms
	int t = 1000
	int i = 0
	while (i < 10):
		fd_heartbeat(fd, t)
		t = t + 100
		i = i + 1
	assert_equal(9, fd_sample_count(fd))
	# exact by construction: 900 / 9
	assert1(fd_mean_interval_ms(fd) == 100.0)
	# one mean interval after the last beat (1900): phi = log10(e)
	assert_near(0.4342945, fd_phi(fd, 2000))
	# eight mean intervals of silence: phi = 8 * log10(e)
	assert_near(3.4743559, fd_phi(fd, 2700))
	# conventional threshold 8.0: not suspect at +100, suspect at +2000
	assert_equal(0, fd_suspect(fd, 2000, 8.0))
	assert_equal(1, fd_suspect(fd, 3900, 8.0))
	# a query timestamp before the last heartbeat clamps to 0 silence
	assert1(fd_phi(fd, 1850) == 0.0)
	fd_free(fd)


void test_window_eviction():
	failure_detector* fd = fd_new(4)
	int t = 1000
	fd_heartbeat(fd, t)
	# six intervals of 100 ms: only the last four are retained
	int i = 0
	while (i < 6):
		t = t + 100
		fd_heartbeat(fd, t)
		i = i + 1
	assert_equal(4, fd_sample_count(fd))
	assert1(fd_mean_interval_ms(fd) == 100.0)
	# switch to 300 ms intervals: window becomes {100, 100, 300, 300}
	i = 0
	while (i < 2):
		t = t + 300
		fd_heartbeat(fd, t)
		i = i + 1
	assert_equal(4, fd_sample_count(fd))
	assert1(fd_mean_interval_ms(fd) == 200.0)
	# two more: the window holds only 300 ms intervals
	i = 0
	while (i < 2):
		t = t + 300
		fd_heartbeat(fd, t)
		i = i + 1
	assert_equal(4, fd_sample_count(fd))
	assert1(fd_mean_interval_ms(fd) == 300.0)
	fd_free(fd)


void test_phi_monotonic_in_silence():
	failure_detector* fd = fd_new(8)
	fd_heartbeat(fd, 1000)
	fd_heartbeat(fd, 1150)
	fd_heartbeat(fd, 1300)
	float prev = fd_phi(fd, 1300)
	assert1(prev == 0.0)
	int now = 1300
	int i = 0
	while (i < 10):
		now = now + 250
		float cur = fd_phi(fd, now)
		assert1(prev < cur)
		prev = cur
		i = i + 1
	fd_free(fd)


void fd_test_feed_three(failure_detector* fd, int base):
	fd_heartbeat(fd, base)
	fd_heartbeat(fd, base + 100)
	fd_heartbeat(fd, base + 200)


void test_wrap_safety():
	# Heartbeats straddling the 32-bit wrap point must behave exactly
	# like the same schedule at a small base. Build 2^31 - 50 at runtime
	# (no bit-31 literals, monotime_test.w style): base + 100 and later
	# timestamps cross the wrap on the x86 target and simply keep
	# growing on x64; the asserted values are identical on both.
	int q = 1 << 30
	int wrap_base = q + q - 50
	failure_detector* wrapped = fd_new(8)
	fd_test_feed_three(wrapped, wrap_base)
	failure_detector* plain = fd_new(8)
	fd_test_feed_three(plain, 1000)
	assert_equal(2, fd_sample_count(wrapped))
	assert_equal(fd_sample_count(plain), fd_sample_count(wrapped))
	assert1(fd_mean_interval_ms(wrapped) == 100.0)
	assert_near(fd_mean_interval_ms(plain), fd_mean_interval_ms(wrapped))
	# same silence past the last beat: identical phi and timeout verdicts
	assert_near(fd_phi(plain, 1000 + 450), fd_phi(wrapped, wrap_base + 450))
	assert1(fd_phi(wrapped, wrap_base + 450) > 0.0)
	assert_equal(0, fd_timed_out(wrapped, wrap_base + 350, 200))
	assert_equal(1, fd_timed_out(wrapped, wrap_base + 450, 200))
	assert_equal(fd_timed_out(plain, 1000 + 450, 200), fd_timed_out(wrapped, wrap_base + 450, 200))
	fd_free(wrapped)
	fd_free(plain)


void test_suspect_threshold_edge():
	failure_detector* fd = fd_new(4)
	fd_heartbeat(fd, 1000)
	fd_heartbeat(fd, 1100)
	float phi = fd_phi(fd, 1400)
	assert1(phi > 0.0)
	# same inputs recompute the same phi bit for bit, so passing it back
	# as the threshold exercises the exactly-at-threshold edge: >= counts
	assert_equal(1, fd_suspect(fd, 1400, phi))
	assert_equal(0, fd_suspect(fd, 1400, phi + 0.001))
	fd_free(fd)
