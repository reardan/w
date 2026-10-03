# wbuild: x64
import lib.testing
import lib.time
import lib.wclock


void test_real_clock_readings():
	wclock* c = wclock_real_new()
	wtime a
	wtime b
	assert_equal(IO_OK, wclock_monotonic(c, &a))
	sleep_ms(2)
	assert_equal(IO_OK, wclock_monotonic(c, &b))
	assert1(wtime_compare(&b, &a) > 0)
	assert1(wtime_diff_ms(&b, &a) >= 2)
	assert1((a.nsec >= 0) && (a.nsec < WCLOCK_NS_PER_SEC))
	# Wall time is epoch seconds: after 2020-01-01, the same second as time(2).
	wtime wall
	assert_equal(IO_OK, wclock_wall(c, &wall))
	assert1(wall.sec > 1577836800)
	int skew = wall.sec - time_now()
	assert1((skew >= -1) && (skew <= 1))
	assert_equal(3, c.reads)
	wclock_free(c)


# wclock_monotonic_ms is time_monotonic_ms's contract, read from a clock.
void test_real_monotonic_ms_matches_time_monotonic_ms():
	wclock* c = wclock_real_new()
	int before = time_monotonic_ms()
	int ms = 0
	assert_equal(IO_OK, wclock_monotonic_ms(c, &ms))
	int after = time_monotonic_ms()
	assert1((ms - before) >= 0)
	assert1((after - ms) >= 0)
	wclock_free(c)


# Scalar readings either fit the word or report IO_UNSUPPORTED.
void test_scalar_units_are_explicit():
	wclock* c = wclock_real_new()
	int ns = 0
	int wall_ms = 0
	int s1 = wclock_monotonic_ns(c, &ns)
	int s2 = wclock_wall_ms(c, &wall_ms)
	if (__word_size__ == 8):
		assert_equal(IO_OK, s1)
		assert1(ns > 0)
		assert_equal(IO_OK, s2)
		assert1(wall_ms / 1000 > 1577836800)
	else:
		# 32-bit x86: epoch milliseconds never fit; uptime ns only for ~2 s.
		assert_equal(IO_UNSUPPORTED, s2)
		assert_equal(0, wall_ms)
		if (s1 != IO_OK):
			assert_equal(IO_UNSUPPORTED, s1)
	wclock_free(c)


void test_virtual_clock_moves_only_when_told():
	wclock* c = wclock_virtual_new(1700000000)
	wtime m
	wtime w
	assert_equal(IO_OK, wclock_monotonic(c, &m))
	assert_equal(0, m.sec)
	assert_equal(0, m.nsec)
	assert_equal(IO_OK, wclock_wall(c, &w))
	assert_equal(1700000000, w.sec)
	wclock_virtual_advance_ms(c, 1500)
	wclock_virtual_advance_ns(c, 600000000)
	assert_equal(IO_OK, wclock_monotonic(c, &m))
	assert_equal(2, m.sec)
	assert_equal(100000000, m.nsec)
	assert_equal(IO_OK, wclock_wall(c, &w))
	assert_equal(1700000002, w.sec)
	assert_equal(100000000, w.nsec)
	int ms = 0
	assert_equal(IO_OK, wclock_monotonic_ms(c, &ms))
	assert_equal(2100, ms)
	int ns = 0
	if (__word_size__ == 8):
		assert_equal(IO_OK, wclock_monotonic_ns(c, &ns))
		assert_equal(2100000000, ns)
	else:
		assert_equal(IO_UNSUPPORTED, wclock_monotonic_ns(c, &ns))
	# advance_to never moves backwards.
	wtime target
	wtime_set(&target, 1, 0)
	wclock_virtual_advance_to(c, &target)
	assert_equal(IO_OK, wclock_monotonic_ms(c, &ms))
	assert_equal(2100, ms)
	wtime_set(&target, 5, 50)
	wclock_virtual_advance_to(c, &target)
	assert_equal(IO_OK, wclock_monotonic(c, &m))
	assert_equal(5, m.sec)
	assert_equal(50, m.nsec)
	assert_equal(IO_OK, wclock_wall(c, &w))
	assert_equal(1700000005, w.sec)
	assert_equal(50, w.nsec)
	wclock_free(c)


# Wall time steps either way; monotonic time does not notice.
void test_wall_jumps_are_independent_of_monotonic():
	wclock* c = wclock_virtual_new(1700000000)
	wclock_virtual_advance_ms(c, 250)
	wclock_virtual_jump_wall_ms(c, 0 - 3600 * 1000)
	wtime m
	wtime w
	assert_equal(IO_OK, wclock_monotonic(c, &m))
	assert_equal(0, m.sec)
	assert_equal(250000000, m.nsec)
	assert_equal(IO_OK, wclock_wall(c, &w))
	assert_equal(1700000000 - 3600, w.sec)
	assert_equal(250000000, w.nsec)
	wclock_virtual_jump_wall_ms(c, 0 - 300)
	assert_equal(IO_OK, wclock_wall(c, &w))
	assert_equal(1700000000 - 3601, w.sec)
	assert_equal(950000000, w.nsec)
	wclock_virtual_set_wall(c, 42, 7)
	assert_equal(IO_OK, wclock_wall(c, &w))
	assert_equal(42, w.sec)
	assert_equal(7, w.nsec)
	assert_equal(IO_OK, wclock_monotonic(c, &m))
	assert_equal(250000000, m.nsec)
	wclock_free(c)


# A failed reading is a status, never a value.
void test_failed_readings_report_status():
	wclock* c = wclock_virtual_new(100)
	wclock_virtual_advance_ms(c, 10)
	wclock_virtual_fail(c, WCLOCK_MONOTONIC, IO_IO_ERROR)
	int ms = 77
	assert_equal(IO_IO_ERROR, wclock_monotonic_ms(c, &ms))
	assert_equal(0, ms)
	# The wall line is unaffected.
	wtime w
	assert_equal(IO_OK, wclock_wall(c, &w))
	assert_equal(100, w.sec)
	wclock_virtual_fail(c, WCLOCK_MONOTONIC, IO_OK)
	assert_equal(IO_OK, wclock_monotonic_ms(c, &ms))
	assert_equal(10, ms)
	wclock_free(c)


void test_wtime_arithmetic():
	wtime t
	wtime_set(&t, 10, 999000000)
	wtime_add_ms(&t, 2)
	assert_equal(11, t.sec)
	assert_equal(1000000, t.nsec)
	wtime_add_ms(&t, -1002)
	assert_equal(9, t.sec)
	assert_equal(999000000, t.nsec)
	wtime_add_ns(&t, 1000001)
	assert_equal(10, t.sec)
	assert_equal(1, t.nsec)
	wtime u
	wtime_set(&u, 9, 500000000)
	assert_equal(500, wtime_diff_ms(&t, &u))
	assert_equal(-500, wtime_diff_ms(&u, &t))
	assert_equal(1, wtime_compare(&t, &u))
	assert_equal(-1, wtime_compare(&u, &t))
	assert_equal(0, wtime_compare(&t, &t))


# Custom clocks plug in through the same read function type.
int wclock_test_fixed_read(void* self, int which, wtime* out):
	int* base = cast(int*, self)
	wtime_set(out, base[0] + which, 0)
	return IO_OK


void test_custom_clock():
	int* base = malloc(__word_size__)
	base[0] = 40
	wclock* c = wclock_custom_new(wclock_test_fixed_read, cast(void*, base))
	wtime t
	assert_equal(IO_OK, wclock_monotonic(c, &t))
	assert_equal(41, t.sec)
	assert_equal(IO_OK, wclock_wall(c, &t))
	assert_equal(42, t.sec)
	wclock_free(c)
	free(base)
