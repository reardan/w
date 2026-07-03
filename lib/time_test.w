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


void test_time_format_utc():
	date_time dt
	time_utc_from_unix(0, &dt)
	char* epoch = time_format_utc(&dt)
	assert_strings_equal("1970-01-01 00:00:00", epoch)
	free(epoch)

	time_utc_from_unix(1709251199, &dt)
	char* leap_day = time_format_utc(&dt)
	assert_strings_equal("2024-02-29 23:59:59", leap_day)
	free(leap_day)


void test_time_format_unix_utc():
	char* formatted = time_format_unix_utc(946684800)
	assert_strings_equal("2000-01-01 00:00:00", formatted)
	free(formatted)


void test_time_now_syscall():
	int before = time_now()
	int after = time_now()
	asserts("time_now should be after 2023-11-14", before >= 1700000000)
	asserts("time_now should not move backwards", after >= before)
