# wbuild: x64
# wbuild: step="bin/datetime_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# Expected values come from CPython's datetime module.
import lib.testing
import libs.standard.time.datetime


void assert_date(int year, int month, int day, date got):
	assert_equal(year, got.year)
	assert_equal(month, got.month)
	assert_equal(day, got.day)


void assert_duration(int days, int seconds, int nanoseconds, duration got):
	assert_equal(days, got.days)
	assert_equal(seconds, got.seconds)
	assert_equal(nanoseconds, got.nanoseconds)


void assert_datetime(int year, int month, int day, int hour, int minute, int second, int nanosecond, datetime got):
	assert_date(year, month, day, got.d)
	assert_equal(hour, got.t.hour)
	assert_equal(minute, got.t.minute)
	assert_equal(second, got.t.second)
	assert_equal(nanosecond, got.t.nanosecond)


void test_date_validity_and_leap_years():
	assert_equal(1, date_is_valid(1, 1, 1))
	assert_equal(1, date_is_valid(9999, 12, 31))
	assert_equal(0, date_is_valid(0, 12, 31))
	assert_equal(0, date_is_valid(10000, 1, 1))
	assert_equal(0, date_is_valid(2024, 0, 1))
	assert_equal(0, date_is_valid(2024, 13, 1))
	assert_equal(0, date_is_valid(2024, 4, 31))
	assert_equal(0, date_is_valid(2024, 1, 0))
	assert_equal(1, date_is_valid(2000, 2, 29))
	assert_equal(1, date_is_valid(2024, 2, 29))
	assert_equal(0, date_is_valid(1900, 2, 29))
	assert_equal(0, date_is_valid(2023, 2, 29))
	assert_equal(1, date_is_leap_year(2000))
	assert_equal(0, date_is_leap_year(2100))
	assert_equal(1, date_is_leap_year(4))
	assert_equal(0, date_is_leap_year(1))
	assert_equal(29, date_days_in_month(2024, 2))
	assert_equal(28, date_days_in_month(9999, 2))


void test_ordinals_match_python():
	assert_equal(1, date_to_ordinal(date_new(1, 1, 1)))
	assert_equal(3652059, date_to_ordinal(date_new(9999, 12, 31)))
	assert_equal(719163, date_to_ordinal(date_new(1970, 1, 1)))
	assert_equal(730179, date_to_ordinal(date_new(2000, 2, 29)))
	assert_equal(693655, date_to_ordinal(date_new(1900, 3, 1)))
	assert_equal(739905, date_to_ordinal(date_new(2026, 10, 16)))
	assert_date(1, 1, 1, date_from_ordinal(1))
	assert_date(9999, 12, 31, date_from_ordinal(3652059))
	assert_date(2000, 2, 29, date_from_ordinal(730179))
	assert_date(1969, 12, 31, date_from_ordinal(719162))
	assert_equal(0, date_ordinal_is_valid(0))
	assert_equal(0, date_ordinal_is_valid(3652060))


# Every ordinal in 1..9999 round-trips and steps by exactly one day.
void test_ordinal_round_trip_full_range():
	date prev = date_from_ordinal(1)
	int n = 2
	while (n <= DATE_MAX_ORDINAL):
		date d = date_from_ordinal(n)
		if (date_to_ordinal(d) != n): assert_equal(n, date_to_ordinal(d))
		if (!date_is_valid(d.year, d.month, d.day)): assert_date(0, 0, 0, d)
		date next = date_add_days(prev, 1)
		if (!date_equal(next, d)): assert_date(d.year, d.month, d.day, next)
		prev = d
		n = n + 1


void test_weekday_and_day_of_year():
	assert_equal(0, date_weekday(date_new(1, 1, 1)))
	assert_equal(4, date_weekday(date_new(9999, 12, 31)))
	assert_equal(3, date_weekday(date_new(1970, 1, 1)))
	assert_equal(1, date_weekday(date_new(2000, 2, 29)))
	assert_equal(6, date_weekday(date_new(2021, 1, 3)))
	assert_equal(7, date_isoweekday(date_new(2021, 1, 3)))
	assert_equal(1, date_day_of_year(date_new(1, 1, 1)))
	assert_equal(365, date_day_of_year(date_new(9999, 12, 31)))
	assert_equal(366, date_day_of_year(date_new(2020, 12, 31)))
	assert_equal(60, date_day_of_year(date_new(2000, 2, 29)))
	assert_equal(60, date_day_of_year(date_new(1900, 3, 1)))
	assert_equal(289, date_day_of_year(date_new(2026, 10, 16)))


void assert_iso(int year, int week, int weekday, iso_calendar_date got):
	assert_equal(year, got.year)
	assert_equal(week, got.week)
	assert_equal(weekday, got.weekday)


void test_isocalendar():
	assert_iso(1, 1, 1, date_isocalendar(date_new(1, 1, 1)))
	assert_iso(1, 1, 7, date_isocalendar(date_new(1, 1, 7)))
	assert_iso(9999, 52, 5, date_isocalendar(date_new(9999, 12, 31)))
	assert_iso(1970, 1, 4, date_isocalendar(date_new(1970, 1, 1)))
	assert_iso(2025, 1, 1, date_isocalendar(date_new(2024, 12, 30)))
	assert_iso(2020, 53, 7, date_isocalendar(date_new(2021, 1, 3)))
	assert_iso(2020, 53, 4, date_isocalendar(date_new(2020, 12, 31)))
	assert_iso(2026, 42, 5, date_isocalendar(date_new(2026, 10, 16)))


void test_from_isocalendar():
	date d = date_new(1, 1, 1)
	assert_equal(1, date_from_isocalendar(2020, 53, 5, &d))
	assert_date(2021, 1, 1, d)
	assert_equal(1, date_from_isocalendar(9999, 52, 5, &d))
	assert_date(9999, 12, 31, d)
	assert_equal(1, date_from_isocalendar(1, 1, 1, &d))
	assert_date(1, 1, 1, d)
	assert_equal(0, date_from_isocalendar(2021, 53, 1, &d))
	assert_equal(0, date_from_isocalendar(2021, 0, 1, &d))
	assert_equal(0, date_from_isocalendar(2021, 1, 8, &d))
	assert_equal(0, date_from_isocalendar(0, 1, 1, &d))
	assert_equal(0, date_from_isocalendar(9999, 52, 6, &d))
	assert_date(1, 1, 1, d)
	# Round trip a stretch of days across year boundaries.
	int n = date_to_ordinal(date_new(2019, 12, 1))
	while (n < date_to_ordinal(date_new(2021, 2, 1))):
		iso_calendar_date iso = date_isocalendar(date_from_ordinal(n))
		assert_equal(1, date_from_isocalendar(iso.year, iso.week, iso.weekday, &d))
		assert_equal(n, date_to_ordinal(d))
		n = n + 1


void test_date_arithmetic():
	assert_date(2024, 3, 1, date_add_days(date_new(2024, 2, 28), 2))
	assert_date(2023, 3, 1, date_add_days(date_new(2023, 2, 28), 1))
	assert_date(2023, 12, 31, date_add_days(date_new(2024, 1, 1), 0 - 1))
	assert_date(1, 1, 1, date_add_days(date_new(9999, 12, 31), 0 - 3652058))
	assert_equal(3652058, date_diff_days(date_new(9999, 12, 31), date_new(1, 1, 1)))
	assert_equal(0 - 3652058, date_diff_days(date_new(1, 1, 1), date_new(9999, 12, 31)))
	assert_duration(0 - 1, 0, 0, date_diff(date_new(2024, 1, 1), date_new(2024, 1, 2)))
	# date + timedelta uses whole days only; -1 second is -1 day + 86399s.
	assert_date(2024, 1, 1, date_add(date_new(2024, 1, 2), duration_from_seconds(0 - 1)))
	assert_date(2024, 1, 3, date_sub(date_new(2024, 1, 2), duration_from_seconds(0 - 1)))
	assert1(date_compare(date_new(2024, 1, 1), date_new(2024, 1, 2)) < 0)
	assert1(date_compare(date_new(2025, 1, 1), date_new(2024, 12, 31)) > 0)
	assert_equal(0, date_compare(date_new(2024, 5, 5), date_new(2024, 5, 5)))


void test_time_of_day():
	assert_equal(1, time_of_day_is_valid(23, 59, 59, 999999999))
	assert_equal(0, time_of_day_is_valid(24, 0, 0, 0))
	assert_equal(0, time_of_day_is_valid(0, 60, 0, 0))
	assert_equal(0, time_of_day_is_valid(0, 0, 60, 0))
	assert_equal(0, time_of_day_is_valid(0, 0, 0, 1000000000))
	assert_equal(0, time_of_day_is_valid(0, 0, 0 - 1, 0))
	time_of_day t = time_of_day_new(13, 14, 15, 16)
	assert_equal(47655, time_of_day_seconds(t))
	time_of_day u = time_of_day_from_seconds(86399, 5)
	assert_equal(23, u.hour)
	assert_equal(59, u.minute)
	assert_equal(59, u.second)
	assert_equal(5, u.nanosecond)
	assert1(time_of_day_compare(t, u) < 0)
	assert1(time_of_day_compare(time_of_day_new(1, 0, 0, 2), time_of_day_new(1, 0, 0, 1)) > 0)
	assert_equal(0, time_of_day_compare(t, time_of_day_new(13, 14, 15, 16)))


void test_duration_normalization():
	assert_duration(0 - 1, 86399, 0, duration_from_seconds(0 - 1))
	assert_duration(0 - 1, 86399, 999999999, duration_new(0, 0, 0 - 1))
	assert_duration(1, 1, 0, duration_new(0, 86401, 0))
	assert_duration(0, 2, 500000000, duration_new(0, 1, 1500000000))
	assert_duration(0 - 2, 82860, 0, duration_from_hms(0 - 25, 1, 0))
	assert_duration(0, 3723, 0, duration_from_hms(1, 2, 3))
	assert_duration(0 - 1, 86399, 999000000, duration_from_millis(0 - 1))
	assert_duration(0, 1, 500000000, duration_from_millis(1500))
	assert_duration(0 - 1, 86399, 999999000, duration_from_micros(0 - 1))
	assert_duration(3652058, 86399, 0, duration_new(3652058, 86399, 0))
	assert_equal(1, duration_is_zero(duration_zero()))
	assert_equal(1, duration_is_zero(duration_new(1, 0 - 86400, 0)))


void test_duration_arithmetic():
	duration a = duration_new(1, 1, 0)
	assert_duration(0 - 4, 86397, 0, duration_mul(a, 0 - 3))
	assert_duration(3, 3, 0, duration_mul(a, 3))
	assert_duration(0, 0, 0, duration_mul(a, 0))
	assert_duration(0 - 2, 86399, 0, duration_neg(a))
	assert_duration(1, 1, 0, duration_abs(duration_neg(a)))
	assert_equal(1, duration_is_negative(duration_neg(a)))
	assert_equal(0, duration_is_negative(a))
	duration half = duration_new(0, 0, 500000000)
	assert_duration(0, 1, 0, duration_add(half, half))
	assert_duration(0 - 1, 86399, 500000000, duration_sub(half, duration_from_seconds(1)))
	assert_duration(0, 0, 0, duration_add(a, duration_neg(a)))
	assert1(duration_compare(duration_neg(a), a) < 0)
	assert1(duration_compare(duration_from_seconds(0 - 1), duration_new(0, 0, 0 - 1)) < 0)
	assert_equal(1, duration_equal(duration_from_hms(0, 0, 3600), duration_from_hms(1, 0, 0)))


void test_duration_totals():
	assert_equal(90061, duration_total_seconds(duration_new(1, 3661, 0)))
	assert_equal(0 - 1, duration_total_seconds(duration_new(0, 0, 0 - 500000000)))
	assert_equal(1, duration_total_seconds(duration_new(0, 1, 500000000)))
	assert_equal(0 - 1500, duration_total_millis(duration_from_millis(0 - 1500)))
	assert_equal(86400001, duration_total_millis(duration_new(1, 0, 1000000)))
	int s = 0
	# 1..9999 does not fit 32 bits of seconds; it fits 64.
	int ok = duration_total_seconds_checked(duration_new(3652058, 86399, 0), &s)
	if (__word_size__ == 4):
		assert_equal(0, ok)
	else:
		assert_equal(1, ok)
		assert_equal(3652058 * 86400 + 86399, s)
	assert_equal(1, duration_total_seconds_checked(duration_new(24855, 11647, 0), &s))
	assert_equal(2147483647, s)


void test_datetime_arithmetic():
	datetime dt = datetime_new(2024, 2, 28, 23, 59, 59, 999999999)
	assert_datetime(2024, 2, 29, 0, 0, 0, 0, datetime_add(dt, duration_new(0, 0, 1)))
	assert_datetime(2024, 2, 28, 23, 59, 58, 999999999, datetime_sub(dt, duration_from_seconds(1)))
	assert_datetime(2024, 2, 27, 23, 59, 59, 999999999, datetime_add(dt, duration_new(0 - 1, 0, 0)))
	assert_datetime(2024, 3, 1, 0, 59, 59, 999999999, datetime_add(dt, duration_from_hms(25, 0, 0)))
	datetime new_year = datetime_new(2024, 1, 1, 0, 0, 0, 0)
	assert_datetime(2023, 12, 31, 23, 0, 0, 0, datetime_add(new_year, duration_from_hms(0 - 1, 0, 0)))
	datetime lo = datetime_new(1, 1, 1, 0, 0, 0, 0)
	datetime hi = datetime_new(9999, 12, 31, 23, 59, 59, 999999999)
	duration span = datetime_diff(hi, lo)
	assert_duration(3652058, 86399, 999999999, span)
	assert_datetime(1, 1, 1, 0, 0, 0, 0, datetime_sub(hi, span))
	assert_datetime(9999, 12, 31, 23, 59, 59, 999999999, datetime_add(lo, span))
	assert_duration(0 - 3652059, 0, 1, datetime_diff(lo, hi))
	assert1(datetime_compare(lo, hi) < 0)
	assert1(datetime_compare(hi, lo) > 0)
	assert_equal(0, datetime_compare(hi, datetime_add(lo, span)))
	assert_equal(1, datetime_equal(hi, datetime_add(lo, span)))
	assert_equal(5, datetime_weekday(datetime_new(2021, 1, 2, 12, 0, 0, 0)))
	assert_equal(6, datetime_isoweekday(datetime_new(2021, 1, 2, 12, 0, 0, 0)))
	assert_equal(2, datetime_day_of_year(datetime_new(2021, 1, 2, 12, 0, 0, 0)))
	assert_iso(2020, 53, 6, datetime_isocalendar(datetime_new(2021, 1, 2, 12, 0, 0, 0)))
	assert_date(2021, 1, 2, datetime_date(datetime_new(2021, 1, 2, 12, 0, 0, 0)))
	assert_equal(12, datetime_time(datetime_new(2021, 1, 2, 12, 0, 0, 0)).hour)


void test_datetime_offsets():
	# 12:00+02:00 and 10:00Z are the same instant.
	datetime a = datetime_with_offset(datetime_new(2024, 6, 1, 12, 0, 0, 0), 7200)
	datetime b = datetime_with_offset(datetime_new(2024, 6, 1, 10, 0, 0, 0), 0)
	assert_equal(0, datetime_compare(a, b))
	assert_equal(1, datetime_equal(a, b))
	assert_duration(0, 0, 0, datetime_diff(a, b))
	assert_equal(0, datetime_equal(a, datetime_new(2024, 6, 1, 12, 0, 0, 0)))
	datetime utc = datetime_to_utc(a)
	assert_datetime(2024, 6, 1, 10, 0, 0, 0, utc)
	assert_equal(1, utc.has_offset)
	assert_equal(0, utc.utc_offset)
	# -05:30 crosses back a day.
	datetime west = datetime_to_offset(datetime_with_offset(datetime_new(2024, 1, 1, 3, 0, 0, 0), 0), 0 - 19800)
	assert_datetime(2023, 12, 31, 21, 30, 0, 0, west)
	assert_equal(0 - 19800, west.utc_offset)
	assert_equal(1, datetime_equal(west, datetime_from_unix(1704078000)))
	assert_equal(1704078000, datetime_to_unix(west))
	# Wall-clock arithmetic keeps the offset.
	datetime later = datetime_add(a, duration_from_hms(13, 0, 0))
	assert_datetime(2024, 6, 2, 1, 0, 0, 0, later)
	assert_equal(7200, later.utc_offset)
	datetime plain = datetime_naive(a)
	assert_equal(0, plain.has_offset)
	assert_equal(1, datetime_utc_offset_is_valid(86399))
	assert_equal(0, datetime_utc_offset_is_valid(86400))
	assert_equal(0, datetime_utc_offset_is_valid(0 - 86400))


void test_unix_timestamps():
	assert_datetime(1970, 1, 1, 0, 0, 0, 0, datetime_from_unix(0))
	assert_datetime(1969, 12, 31, 23, 59, 59, 0, datetime_from_unix(0 - 1))
	assert_datetime(2038, 1, 19, 3, 14, 7, 0, datetime_from_unix(2147483647))
	assert_datetime(1901, 12, 13, 20, 45, 52, 0, datetime_from_unix(0 - 2147483647 - 1))
	assert_datetime(2000, 2, 29, 12, 0, 0, 5, datetime_from_unix_ns(951825600, 5))
	datetime e = datetime_from_unix(0)
	assert_equal(1, e.has_offset)
	assert_equal(0, e.utc_offset)
	assert_equal(0, datetime_to_unix(e))
	assert_equal(0 - 1, datetime_to_unix(datetime_from_unix_ns(0 - 1, 999999999)))
	assert_equal(951825600, datetime_to_unix(datetime_new(2000, 2, 29, 12, 0, 0, 0)))
	assert_equal(2147483647, datetime_to_unix(datetime_from_unix(2147483647)))
	assert_equal(0 - 2147483647 - 1, datetime_to_unix(datetime_from_unix(0 - 2147483647 - 1)))
	int s = 0
	int ok = datetime_to_unix_checked(datetime_new(2038, 1, 19, 3, 14, 8, 0), &s)
	int ok_early = datetime_to_unix_checked(datetime_new(1901, 12, 13, 20, 45, 51, 0), &s)
	int ok_far = datetime_to_unix_checked(datetime_new(9999, 12, 31, 23, 59, 59, 0), &s)
	if (__word_size__ == 4):
		assert_equal(0, ok)
		assert_equal(0, ok_early)
		assert_equal(0, ok_far)
	else:
		assert_equal(1, ok)
		assert_equal(1, ok_early)
		assert_equal(1, ok_far)
		assert_equal(2932896 * 86400 + 86399, s)
		assert_equal(1, datetime_to_unix_checked(datetime_new(1, 1, 1, 0, 0, 0, 0), &s))
		assert_equal(0 - 719162 * 86400, s)
		assert_datetime(1, 1, 1, 0, 0, 0, 0, datetime_from_unix(0 - 719162 * 86400))
		assert_datetime(9999, 12, 31, 23, 59, 59, 0, datetime_from_unix(2932896 * 86400 + 86399))


void test_now_utc():
	datetime now = datetime_now_utc()
	assert_equal(1, now.has_offset)
	assert1(now.d.year >= 2024)
	assert_equal(1, date_is_valid(now.d.year, now.d.month, now.d.day))
	time_of_day t = now.t
	assert1(datetime_is_valid(now.d.year, now.d.month, now.d.day, t.hour, t.minute, t.second, t.nanosecond))
	date today = date_today_utc()
	assert1(date_diff_days(today, now.d) >= 0)
	assert1(date_diff_days(today, now.d) <= 1)
