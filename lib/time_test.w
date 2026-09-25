# wbuild: x64
import lib.testing
import lib.time


void assert_epoch(date_time* dt, int year, int month, int day, int hour, int minute, int second, int weekday, int year_day):
	assert_equal(year, dt.year)
	assert_equal(month, dt.month)
	assert_equal(day, dt.day)
	assert_equal(hour, dt.hour)
	assert_equal(minute, dt.minute)
	assert_equal(second, dt.second)
	assert_equal(weekday, dt.weekday)
	assert_equal(year_day, dt.year_day)


void test_time_leap_years():
	assert_equal(0, time_is_leap_year(1970))
	assert_equal(1, time_is_leap_year(2000))
	assert_equal(0, time_is_leap_year(1900))
	assert_equal(1, time_is_leap_year(2024))


void test_time_days_in_year():
	assert_equal(365, time_days_in_year(1970))
	assert_equal(366, time_days_in_year(2000))
	assert_equal(365, time_days_in_year(1900))
	assert_equal(366, time_days_in_year(2024))


void test_time_days_in_month():
	assert_equal(31, time_days_in_month(2023, 1))
	assert_equal(28, time_days_in_month(2023, 2))
	assert_equal(29, time_days_in_month(2024, 2))
	assert_equal(30, time_days_in_month(2024, 11))


void test_time_unix_epoch():
	date_time dt
	time_utc_from_unix(0, &dt)
	assert_epoch(&dt, 1970, 1, 1, 0, 0, 0, 4, 1)


void test_time_known_utc_dates():
	date_time dt
	time_utc_from_unix(946684800, &dt)
	assert_epoch(&dt, 2000, 1, 1, 0, 0, 0, 6, 1)

	time_utc_from_unix(951782400, &dt)
	assert_epoch(&dt, 2000, 2, 29, 0, 0, 0, 2, 60)

	time_utc_from_unix(1709251199, &dt)
	assert_epoch(&dt, 2024, 2, 29, 23, 59, 59, 4, 60)

	time_utc_from_unix(1703980800, &dt)
	assert_epoch(&dt, 2023, 12, 31, 0, 0, 0, 0, 365)

	time_utc_from_unix(1735603200, &dt)
	assert_epoch(&dt, 2024, 12, 31, 0, 0, 0, 2, 366)

	time_utc_from_unix(2147483647, &dt)
	assert_epoch(&dt, 2038, 1, 19, 3, 14, 7, 2, 19)


void test_time_utc_new():
	date_time* sunday = time_utc_new(946771200)
	assert_equal(0, sunday.weekday)
	assert_epoch(sunday, 2000, 1, 2, 0, 0, 0, 0, 2)
	free(sunday)


void test_time_format_utc():
	date_time dt
	time_utc_from_unix(0, &dt)
	char* epoch = time_format_utc(&dt)
	assert_strings_equal(c"1970-01-01 00:00:00", epoch)
	free(epoch)

	time_utc_from_unix(1709251199, &dt)
	char* leap_day = time_format_utc(&dt)
	assert_strings_equal(c"2024-02-29 23:59:59", leap_day)
	free(leap_day)


void test_time_format_unix_utc():
	char* formatted = time_format_unix_utc(946684800)
	assert_strings_equal(c"2000-01-01 00:00:00", formatted)
	free(formatted)


void test_time_now_syscall():
	int before = time_now()
	int after = time_now()
	asserts(c"time_now should be after 2023-11-14", before >= 1700000000)
	asserts(c"time_now should not move backwards", after >= before)


void test_time_monotonic_ms():
	int before = time_monotonic_ms()
	int after = time_monotonic_ms()
	asserts(c"monotonic clock should not move backwards", after >= before)


void test_sleep_ms():
	int start = time_monotonic_ms()
	sleep_ms(20)
	int elapsed = time_monotonic_ms() - start
	asserts(c"sleep_ms returned too early", elapsed >= 15)


void test_time_days_from_civil_known_dates():
	assert_equal(0, time_days_from_civil(1970, 1, 1))
	assert_equal(1, time_days_from_civil(1970, 1, 2))
	assert_equal(-1, time_days_from_civil(1969, 12, 31))
	assert_equal(10957, time_days_from_civil(2000, 1, 1))
	assert_equal(11016, time_days_from_civil(2000, 2, 29))
	assert_equal(19782, time_days_from_civil(2024, 2, 29))
	assert_equal(24855, time_days_from_civil(2038, 1, 19))


# Before 1970, and before year 0, where truncating division would put
# the era off by one without the floor.
void test_time_days_from_civil_before_the_epoch():
	assert_equal(-365, time_days_from_civil(1969, 1, 1))
	assert_equal(-25567, time_days_from_civil(1900, 1, 1))
	assert_equal(-719468, time_days_from_civil(0, 3, 1))
	assert_equal(-719528, time_days_from_civil(0, 1, 1))
	assert_equal(-719529, time_days_from_civil(-1, 12, 31))
	# 1900 was not a leap year: Feb 28 and Mar 1 are adjacent.
	assert_equal(1, time_days_from_civil(1900, 3, 1) - time_days_from_civil(1900, 2, 28))
	# 2000 was: there is a Feb 29 between them.
	assert_equal(2, time_days_from_civil(2000, 3, 1) - time_days_from_civil(2000, 2, 28))


# Out-of-range days count on linearly across month ends.
void test_time_days_from_civil_overflowing_days():
	assert_equal(time_days_from_civil(2023, 12, 31), time_days_from_civil(2024, 1, 0))
	assert_equal(time_days_from_civil(2024, 2, 1), time_days_from_civil(2024, 1, 32))


void test_time_weekday_from_civil():
	assert_equal(4, time_weekday_from_civil(1970, 1, 1))
	assert_equal(3, time_weekday_from_civil(1969, 12, 31))
	assert_equal(6, time_weekday_from_civil(2000, 1, 1))
	assert_equal(2, time_weekday_from_civil(2000, 2, 29))
	assert_equal(4, time_weekday_from_civil(2024, 2, 29))
	assert_equal(0, time_weekday_from_civil(2023, 12, 31))
	assert_equal(1, time_weekday_from_civil(1900, 1, 1))
	assert_equal(4, time_weekday_from_civil(1776, 7, 4))
	assert_equal(6, time_weekday_from_civil(0, 1, 1))
	# Every weekday in a row, across the epoch.
	int d = -10
	while (d < 10):
		assert_equal((time_weekday_from_days(d) + 1) % 7, time_weekday_from_days(d + 1))
		d = d + 1


# Every day from 1970 to 2038-01-19 (the 32-bit limit) round-trips through
# time_utc_from_unix, weekday and year_day included.
void test_time_days_from_civil_round_trips():
	date_time dt
	int days = 0
	while (days < 24856):
		time_utc_from_unix(days * 86400, &dt)
		assert_equal(days, time_days_from_civil(dt.year, dt.month, dt.day))
		assert_equal(dt.weekday, time_weekday_from_civil(dt.year, dt.month, dt.day))
		assert_equal(dt.year_day, time_days_from_civil(dt.year, dt.month, dt.day) - time_days_from_civil(dt.year, 1, 1) + 1)
		days = days + 1


void test_time_unix_from_utc():
	date_time dt
	time_utc_from_unix(1709251199, &dt)
	assert_equal(1709251199, time_unix_from_utc(&dt))
	time_utc_from_unix(0, &dt)
	assert_equal(0, time_unix_from_utc(&dt))
	time_utc_from_unix(2147483647, &dt)
	assert_equal(2147483647, time_unix_from_utc(&dt))
	int t = 0
	while (t < 2000000000):
		time_utc_from_unix(t, &dt)
		assert_equal(t, time_unix_from_utc(&dt))
		t = t + 12345677

	# Before the epoch: 1969-12-31 23:59:59 is one second short of it.
	dt.year = 1969
	dt.month = 12
	dt.day = 31
	dt.hour = 23
	dt.minute = 59
	dt.second = 59
	assert_equal(-1, time_unix_from_utc(&dt))
	dt.year = 1901
	dt.month = 12
	dt.day = 13
	dt.hour = 20
	dt.minute = 45
	dt.second = 52
	assert_equal(0 - 2147483647 - 1, time_unix_from_utc(&dt))
