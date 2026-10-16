# wbuild: name=time_format_test x64
# wbuild: step="bin/time_format_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# The test_*_table functions at the end are generated from CPython 3.13
# (datetime.strftime / strptime / isoformat / fromisoformat and
# email.utils.format_datetime / parsedate_to_datetime) by the script in
# the comment at the bottom of this file.
import lib.testing
import libs.standard.time.format


datetime make_dt(int year, int month, int day, int hour, int minute, int second, int us, int has_offset, int offset):
	datetime dt = datetime_new(year, month, day, hour, minute, second, us * 1000)
	if (has_offset): dt = datetime_with_offset(dt, offset)
	return dt


void assert_dt(int year, int month, int day, int hour, int minute, int second, int us, int has_offset, int offset, datetime got):
	assert_equal(year, got.d.year)
	assert_equal(month, got.d.month)
	assert_equal(day, got.d.day)
	assert_equal(hour, got.t.hour)
	assert_equal(minute, got.t.minute)
	assert_equal(second, got.t.second)
	assert_equal(us * 1000, got.t.nanosecond)
	assert_equal(has_offset, got.has_offset)
	assert_equal(offset, got.utc_offset)


void assert_owned_text(char* want, char* got):
	assert_strings_equal(want, got)
	free(got)


# Parse result ok (0/1) and, when ok, the expected fields.
void assert_parsed(char* what, int ok, int got_ok, int y, int mo, int d, int h, int mi, int s, int us, int has, int off, datetime got):
	if (ok != got_ok):
		print2(c"parse mismatch for: ")
		println2(what)
	assert_equal(ok, got_ok)
	if (ok): assert_dt(y, mo, d, h, mi, s, us, has, off, got)


void check_round_trip(int year, int month, int day, int hour, int minute, int second, int us, int has_offset, int offset, char* fmt, char* want, int ok, int y, int mo, int d, int h, int mi, int s, int pus, int has, int off):
	datetime dt = make_dt(year, month, day, hour, minute, second, us, has_offset, offset)
	assert_owned_text(want, datetime_strftime(dt, fmt))
	datetime got = datetime_new(1, 1, 1, 0, 0, 0, 0)
	assert_parsed(want, ok, datetime_strptime(want, fmt, &got), y, mo, d, h, mi, s, pus, has, off, got)


void check_strptime(char* text, char* fmt, int ok, int y, int mo, int d, int h, int mi, int s, int us, int has, int off):
	datetime got = datetime_new(1, 1, 1, 0, 0, 0, 0)
	assert_parsed(text, ok, datetime_strptime(text, fmt, &got), y, mo, d, h, mi, s, us, has, off, got)


void check_isoformat(int year, int month, int day, int hour, int minute, int second, int us, int has_offset, int offset, int sep, int spec, char* want):
	datetime dt = make_dt(year, month, day, hour, minute, second, us, has_offset, offset)
	assert_owned_text(want, datetime_isoformat_ex(dt, sep, spec))
	if (spec == DATETIME_TIMESPEC_AUTO):
		datetime got = datetime_new(1, 1, 1, 0, 0, 0, 0)
		assert_equal(1, datetime_fromisoformat(want, &got))
		assert_equal(1, datetime_equal(dt, got))
		assert_equal(dt.utc_offset, got.utc_offset)
		if (sep == 'T'): assert_owned_text(want, datetime_isoformat(dt))


void check_fromisoformat(char* text, int ok, int y, int mo, int d, int h, int mi, int s, int us, int has, int off):
	datetime got = datetime_new(1, 1, 1, 0, 0, 0, 0)
	int got_ok = datetime_fromisoformat(text, &got)
	# W keeps nanoseconds; Python stops at microseconds.
	got.t.nanosecond = got.t.nanosecond / 1000 * 1000
	assert_parsed(text, ok, got_ok, y, mo, d, h, mi, s, us, has, off, got)


void check_rfc2822_format(int year, int month, int day, int hour, int minute, int second, int us, int has_offset, int offset, char* want, char* want_http):
	datetime dt = make_dt(year, month, day, hour, minute, second, us, has_offset, offset)
	assert_owned_text(want, datetime_format_rfc2822(dt))
	if (want_http[0] != 0): assert_owned_text(want_http, datetime_format_http(dt))
	# parsedate reads "+010203" as 102 hours, so only whole-minute
	# offsets round-trip (as in Python).
	if (offset % 60 != 0): return
	datetime got = datetime_new(1, 1, 1, 0, 0, 0, 0)
	assert_equal(1, datetime_parse_rfc2822(want, &got))
	assert_dt(year, month, day, hour, minute, second, 0, has_offset, offset, got)


void check_rfc2822_parse(char* text, int ok, int y, int mo, int d, int h, int mi, int s, int us, int has, int off):
	datetime got = datetime_new(1, 1, 1, 0, 0, 0, 0)
	assert_parsed(text, ok, datetime_parse_rfc2822(text, &got), y, mo, d, h, mi, s, us, has, off, got)


void test_strftime_extras():
	datetime dt = datetime_new(7, 3, 4, 0, 5, 6, 7000)
	# Years below 1000 are zero-padded to 4 digits (macOS/BSD; glibc
	# prints "7"), so %Y always round-trips through strptime.
	assert_owned_text(c"0007-03-04 00:05:06.000007", datetime_strftime(dt, c"%Y-%m-%d %H:%M:%S.%f"))
	assert_owned_text(c"12 AM 07", datetime_strftime(dt, c"%I %p %y"))
	# Unknown directives and a trailing % are copied through.
	assert_owned_text(c"%Q %E %", datetime_strftime(dt, c"%Q %E %"))
	assert_owned_text(c"", datetime_strftime(dt, c""))
	assert_owned_text(c"[][][]", datetime_strftime(dt, c"[%z][%:z][%Z]"))
	date d = date_new(2024, 2, 29)
	assert_owned_text(c"Thursday 29 February 2024 00:00 060", date_strftime(d, c"%A %d %B %Y %H:%M %j"))
	# %f stops at microseconds.
	assert_owned_text(c"999999", datetime_strftime(datetime_new(2024, 1, 1, 0, 0, 0, 999999999), c"%f"))
	datetime west = datetime_with_offset(datetime_new(2024, 1, 1, 0, 0, 0, 0), 0 - 3723)
	assert_owned_text(c"-010203 -01:02:03 UTC-01:02:03", datetime_strftime(west, c"%z %:z %Z"))


void test_strptime_extras():
	datetime got = datetime_new(1, 1, 1, 0, 0, 0, 0)
	assert_equal(1, datetime_strptime(c"0007-03-04", c"%Y-%m-%d", &got))
	assert_dt(7, 3, 4, 0, 0, 0, 0, 0, 0, got)
	# A failed parse leaves *out alone.
	assert_equal(0, datetime_strptime(c"bogus", c"%Y", &got))
	assert_dt(7, 3, 4, 0, 0, 0, 0, 0, 0, got)
	# Backtracking: %d first takes "12", then "1" so %Y gets 4 digits.
	assert_equal(1, datetime_strptime(c"12024", c"%d%Y", &got))
	assert_dt(2024, 1, 1, 0, 0, 0, 0, 0, 0, got)
	assert_equal(1, datetime_strptime(c"Z", c"%z", &got))
	assert_dt(1900, 1, 1, 0, 0, 0, 0, 1, 0, got)
	# Non-zero fractional-second offsets cannot be represented.
	assert_equal(0, datetime_strptime(c"+01:00:00.5", c"%z", &got))
	assert_equal(1, datetime_strptime(c"+01:00:00.000", c"%z", &got))
	assert_dt(1900, 1, 1, 0, 0, 0, 0, 1, 3600, got)


void test_isoformat_extras():
	datetime dt = datetime_new(2024, 5, 6, 7, 8, 9, 123456789)
	assert_owned_text(c"2024-05-06T07:08:09.123456789", datetime_isoformat(dt))
	assert_owned_text(c"2024-05-06 07:08:09.123456789", datetime_isoformat_ex(dt, ' ', DATETIME_TIMESPEC_NANOSECONDS))
	assert_owned_text(c"2024-05-06T07:08:09.123", datetime_isoformat_ex(dt, 'T', DATETIME_TIMESPEC_MILLISECONDS))
	datetime got = datetime_new(1, 1, 1, 0, 0, 0, 0)
	assert_equal(1, datetime_fromisoformat(c"2024-05-06T07:08:09.123456789", &got))
	assert_equal(123456789, got.t.nanosecond)
	assert_equal(1, datetime_fromisoformat(c"2024-05-06T07:08:09.1234567891234", &got))
	assert_equal(123456789, got.t.nanosecond)
	assert_owned_text(c"0001-01-01", date_isoformat(date_new(1, 1, 1)))
	date d = date_new(1, 1, 1)
	assert_equal(1, date_fromisoformat(c"2020-W53-7", &d))
	assert_owned_text(c"2021-01-03", date_isoformat(d))
	assert_equal(1, date_fromisoformat(c"20240229", &d))
	assert_equal(29, d.day)
	assert_equal(0, date_fromisoformat(c"2023-02-29", &d))
	assert_equal(0, date_fromisoformat(c"2024-01-01T00", &d))
	assert_equal(29, d.day)
	time_of_day t = time_of_day_new(0, 0, 0, 0)
	assert_owned_text(c"07:08:09.123457", time_of_day_isoformat(time_of_day_new(7, 8, 9, 123457000), DATETIME_TIMESPEC_AUTO))
	assert_owned_text(c"07", time_of_day_isoformat(time_of_day_new(7, 8, 9, 0), DATETIME_TIMESPEC_HOURS))
	int offset = 0
	assert_equal(1, time_of_day_fromisoformat(c"T10:20", &t, &offset))
	assert_equal(10, t.hour)
	assert_equal(20, t.minute)
	assert_equal(2, time_of_day_fromisoformat(c"10:20:30.5-05:30", &t, &offset))
	assert_equal(0 - 19800, offset)
	assert_equal(500000000, t.nanosecond)
	assert_equal(2, time_of_day_fromisoformat(c"102030Z", &t, 0))
	assert_equal(0, time_of_day_fromisoformat(c"25:00", &t, &offset))
	assert_equal(0, time_of_day_fromisoformat(c"1", &t, &offset))


void test_rfc3339():
	datetime dt = datetime_with_offset(datetime_new(1985, 4, 12, 23, 20, 50, 520000000), 0)
	assert_owned_text(c"1985-04-12T23:20:50.520000Z", datetime_format_rfc3339(dt))
	datetime pst = datetime_with_offset(datetime_new(1996, 12, 19, 16, 39, 57, 0), 0 - 28800)
	assert_owned_text(c"1996-12-19T16:39:57-08:00", datetime_format_rfc3339(pst))
	datetime got = datetime_new(1, 1, 1, 0, 0, 0, 0)
	assert_equal(1, datetime_parse_rfc3339(c"1985-04-12T23:20:50.52Z", &got))
	assert_equal(1, datetime_equal(dt, got))
	assert_equal(1, datetime_parse_rfc3339(c"1996-12-19t16:39:57-08:00", &got))
	assert_dt(1996, 12, 19, 16, 39, 57, 0, 1, 0 - 28800, got)
	assert_equal(1, datetime_parse_rfc3339(c"1937-01-01 12:00:27.87+00:20", &got))
	assert_dt(1937, 1, 1, 12, 0, 27, 870000, 1, 1200, got)
	assert_equal(1, datetime_parse_rfc3339(c"2024-01-01T00:00:00.123456789123z", &got))
	assert_equal(123456789, got.t.nanosecond)
	assert_equal(1, datetime_parse_rfc3339(c"2024-01-01T00:00:00-00:00", &got))
	assert_dt(2024, 1, 1, 0, 0, 0, 0, 1, 0, got)
	# Not RFC 3339: missing offset or seconds, leap second, bad offset.
	assert_equal(0, datetime_parse_rfc3339(c"2024-01-01T00:00:00", &got))
	assert_equal(0, datetime_parse_rfc3339(c"2024-01-01T00:00Z", &got))
	assert_equal(0, datetime_parse_rfc3339(c"1990-12-31T23:59:60Z", &got))
	assert_equal(0, datetime_parse_rfc3339(c"2024-01-01T00:00:00+0100", &got))
	assert_equal(0, datetime_parse_rfc3339(c"2024-01-01T00:00:00+24:00", &got))
	assert_equal(0, datetime_parse_rfc3339(c"2024-01-01T00:00:00.Z", &got))
	assert_equal(0, datetime_parse_rfc3339(c"2024-02-30T00:00:00Z", &got))
	assert_equal(0, datetime_parse_rfc3339(c"2024-01-01T00:00:00Zx", &got))
	assert_equal(0, datetime_parse_rfc3339(c"", &got))
	assert_dt(2024, 1, 1, 0, 0, 0, 0, 1, 0, got)


void test_http_dates():
	datetime got = datetime_new(1, 1, 1, 0, 0, 0, 0)
	# RFC 7231's three forms of the same instant.
	assert_equal(1, datetime_parse_http(c"Sun, 06 Nov 1994 08:49:37 GMT", &got))
	assert_dt(1994, 11, 6, 8, 49, 37, 0, 1, 0, got)
	assert_equal(1, datetime_parse_http(c"Sunday, 06-Nov-94 08:49:37 GMT", &got))
	assert_dt(1994, 11, 6, 8, 49, 37, 0, 1, 0, got)
	assert_equal(1, datetime_parse_http(c"Sun Nov  6 08:49:37 1994", &got))
	assert_dt(1994, 11, 6, 8, 49, 37, 0, 1, 0, got)
	assert_equal(784111777, datetime_to_unix(got))
	# A non-UTC zone is converted.
	assert_equal(1, datetime_parse_http(c"Sun, 06 Nov 1994 03:49:37 -0500", &got))
	assert_dt(1994, 11, 6, 8, 49, 37, 0, 1, 0, got)
	assert_owned_text(c"Sun, 06 Nov 1994 08:49:37 GMT", datetime_format_http(got))
	assert_equal(0, datetime_parse_http(c"not a date", &got))
	# Converting to UTC must not leave year 9999 (Python: OverflowError).
	assert_equal(0, datetime_parse_http(c"Fri, 31 Dec 9999 23:59:59 -0100", &got))
	assert_equal(1, datetime_parse_http(c"Fri, 31 Dec 9999 23:59:59 +0100", &got))
	assert_dt(9999, 12, 31, 22, 59, 59, 0, 1, 0, got)


void test_strftime_strptime_table():
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%Y-%m-%d %H:%M:%S", c"2024-02-29 13:05:09", 1, 2024, 2, 29, 13, 5, 9, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%Y-%m-%dT%H:%M:%S.%f%z", c"2024-02-29T13:05:09.123456", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%a, %d %b %Y %H:%M:%S %z", c"Thu, 29 Feb 2024 13:05:09 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%A %B %d %Y", c"Thursday February 29 2024", 1, 2024, 2, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%I:%M:%S %p", c"01:05:09 PM", 1, 1900, 1, 1, 13, 5, 9, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%y%m%d", c"240229", 1, 2024, 2, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%j", c"060", 1, 1900, 3, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%Y %j", c"2024 060", 1, 2024, 2, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%Y %U %w", c"2024 08 4", 1, 2024, 2, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%Y %W %a", c"2024 09 Thu", 1, 2024, 2, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%G-W%V-%u", c"2024-W09-4", 1, 2024, 2, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%c", c"Thu Feb 29 13:05:09 2024", 1, 2024, 2, 29, 13, 5, 9, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%x", c"02/29/24", 1, 2024, 2, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%X", c"13:05:09", 1, 1900, 1, 1, 13, 5, 9, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%Z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%Y-%m-%d %H:%M %Z", c"2024-02-29 13:05 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%:z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%%Y %Y", c"%Y 2024", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%d/%m/%Y %H:%M:%S.%f", c"29/02/2024 13:05:09.123456", 1, 2024, 2, 29, 13, 5, 9, 123456, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%b %d %Y %I %p", c"Feb 29 2024 01 PM", 1, 2024, 2, 29, 13, 0, 0, 0, 0, 0)
	check_round_trip(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"%w %u %U %W %V %G", c"4 4 08 09 09 2024", 1, 1900, 3, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%Y-%m-%d %H:%M:%S", c"1999-12-31 23:59:59", 1, 1999, 12, 31, 23, 59, 59, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%Y-%m-%dT%H:%M:%S.%f%z", c"1999-12-31T23:59:59.000000+0000", 1, 1999, 12, 31, 23, 59, 59, 0, 1, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%a, %d %b %Y %H:%M:%S %z", c"Fri, 31 Dec 1999 23:59:59 +0000", 1, 1999, 12, 31, 23, 59, 59, 0, 1, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%A %B %d %Y", c"Friday December 31 1999", 1, 1999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%I:%M:%S %p", c"11:59:59 PM", 1, 1900, 1, 1, 23, 59, 59, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%y%m%d", c"991231", 1, 1999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%j", c"365", 1, 1900, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%Y %j", c"1999 365", 1, 1999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%Y %U %w", c"1999 52 5", 1, 1999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%Y %W %a", c"1999 52 Fri", 1, 1999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%G-W%V-%u", c"1999-W52-5", 1, 1999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%c", c"Fri Dec 31 23:59:59 1999", 1, 1999, 12, 31, 23, 59, 59, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%x", c"12/31/99", 1, 1999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%X", c"23:59:59", 1, 1900, 1, 1, 23, 59, 59, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%Z", c"UTC", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%Y-%m-%d %H:%M %Z", c"1999-12-31 23:59 UTC", 1, 1999, 12, 31, 23, 59, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%:z", c"+00:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%%Y %Y", c"%Y 1999", 1, 1999, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%d/%m/%Y %H:%M:%S.%f", c"31/12/1999 23:59:59.000000", 1, 1999, 12, 31, 23, 59, 59, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%b %d %Y %I %p", c"Dec 31 1999 11 PM", 1, 1999, 12, 31, 23, 0, 0, 0, 0, 0)
	check_round_trip(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"%w %u %U %W %V %G", c"5 5 52 52 52 1999", 1, 1900, 12, 28, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%Y-%m-%d %H:%M:%S", c"2000-01-01 00:00:00", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%Y-%m-%dT%H:%M:%S.%f%z", c"2000-01-01T00:00:00.000000+0530", 1, 2000, 1, 1, 0, 0, 0, 0, 1, 19800)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%a, %d %b %Y %H:%M:%S %z", c"Sat, 01 Jan 2000 00:00:00 +0530", 1, 2000, 1, 1, 0, 0, 0, 0, 1, 19800)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%A %B %d %Y", c"Saturday January 01 2000", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%I:%M:%S %p", c"12:00:00 AM", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%y%m%d", c"000101", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%j", c"001", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%Y %j", c"2000 001", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%Y %U %w", c"2000 00 6", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%Y %W %a", c"2000 00 Sat", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%G-W%V-%u", c"1999-W52-6", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%c", c"Sat Jan  1 00:00:00 2000", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%x", c"01/01/00", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%X", c"00:00:00", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%Z", c"UTC+05:30", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%Y-%m-%d %H:%M %Z", c"2000-01-01 00:00 UTC+05:30", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%:z", c"+05:30", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%%Y %Y", c"%Y 2000", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%d/%m/%Y %H:%M:%S.%f", c"01/01/2000 00:00:00.000000", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%b %d %Y %I %p", c"Jan 01 2000 12 AM", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"%w %u %U %W %V %G", c"6 6 00 00 52 1999", 1, 1900, 1, 6, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%Y-%m-%d %H:%M:%S", c"2021-01-03 12:30:00", 1, 2021, 1, 3, 12, 30, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%Y-%m-%dT%H:%M:%S.%f%z", c"2021-01-03T12:30:00.500000-0800", 1, 2021, 1, 3, 12, 30, 0, 500000, 1, -28800)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%a, %d %b %Y %H:%M:%S %z", c"Sun, 03 Jan 2021 12:30:00 -0800", 1, 2021, 1, 3, 12, 30, 0, 0, 1, -28800)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%A %B %d %Y", c"Sunday January 03 2021", 1, 2021, 1, 3, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%I:%M:%S %p", c"12:30:00 PM", 1, 1900, 1, 1, 12, 30, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%y%m%d", c"210103", 1, 2021, 1, 3, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%j", c"003", 1, 1900, 1, 3, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%Y %j", c"2021 003", 1, 2021, 1, 3, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%Y %U %w", c"2021 01 0", 1, 2021, 1, 3, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%Y %W %a", c"2021 00 Sun", 1, 2021, 1, 3, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%G-W%V-%u", c"2020-W53-7", 1, 2021, 1, 3, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%c", c"Sun Jan  3 12:30:00 2021", 1, 2021, 1, 3, 12, 30, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%x", c"01/03/21", 1, 2021, 1, 3, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%X", c"12:30:00", 1, 1900, 1, 1, 12, 30, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%Z", c"UTC-08:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%Y-%m-%d %H:%M %Z", c"2021-01-03 12:30 UTC-08:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%:z", c"-08:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%%Y %Y", c"%Y 2021", 1, 2021, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%d/%m/%Y %H:%M:%S.%f", c"03/01/2021 12:30:00.500000", 1, 2021, 1, 3, 12, 30, 0, 500000, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%b %d %Y %I %p", c"Jan 03 2021 12 PM", 1, 2021, 1, 3, 12, 0, 0, 0, 0, 0)
	check_round_trip(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"%w %u %U %W %V %G", c"0 7 01 00 53 2020", 1, 1900, 1, 7, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%Y-%m-%d %H:%M:%S", c"2020-12-31 00:00:01", 1, 2020, 12, 31, 0, 0, 1, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%Y-%m-%dT%H:%M:%S.%f%z", c"2020-12-31T00:00:01.000000", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%a, %d %b %Y %H:%M:%S %z", c"Thu, 31 Dec 2020 00:00:01 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%A %B %d %Y", c"Thursday December 31 2020", 1, 2020, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%I:%M:%S %p", c"12:00:01 AM", 1, 1900, 1, 1, 0, 0, 1, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%y%m%d", c"201231", 1, 2020, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%j", c"366", 1, 1901, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%Y %j", c"2020 366", 1, 2020, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%Y %U %w", c"2020 52 4", 1, 2020, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%Y %W %a", c"2020 52 Thu", 1, 2020, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%G-W%V-%u", c"2020-W53-4", 1, 2020, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%c", c"Thu Dec 31 00:00:01 2020", 1, 2020, 12, 31, 0, 0, 1, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%x", c"12/31/20", 1, 2020, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%X", c"00:00:01", 1, 1900, 1, 1, 0, 0, 1, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%Z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%Y-%m-%d %H:%M %Z", c"2020-12-31 00:00 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%:z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%%Y %Y", c"%Y 2020", 1, 2020, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%d/%m/%Y %H:%M:%S.%f", c"31/12/2020 00:00:01.000000", 1, 2020, 12, 31, 0, 0, 1, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%b %d %Y %I %p", c"Dec 31 2020 12 AM", 1, 2020, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"%w %u %U %W %V %G", c"4 4 52 52 53 2020", 1, 1900, 12, 27, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%Y-%m-%d %H:%M:%S", c"1970-01-01 00:00:00", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%Y-%m-%dT%H:%M:%S.%f%z", c"1970-01-01T00:00:00.000000+0000", 1, 1970, 1, 1, 0, 0, 0, 0, 1, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%a, %d %b %Y %H:%M:%S %z", c"Thu, 01 Jan 1970 00:00:00 +0000", 1, 1970, 1, 1, 0, 0, 0, 0, 1, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%A %B %d %Y", c"Thursday January 01 1970", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%I:%M:%S %p", c"12:00:00 AM", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%y%m%d", c"700101", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%j", c"001", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%Y %j", c"1970 001", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%Y %U %w", c"1970 00 4", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%Y %W %a", c"1970 00 Thu", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%G-W%V-%u", c"1970-W01-4", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%c", c"Thu Jan  1 00:00:00 1970", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%x", c"01/01/70", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%X", c"00:00:00", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%Z", c"UTC", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%Y-%m-%d %H:%M %Z", c"1970-01-01 00:00 UTC", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%:z", c"+00:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%%Y %Y", c"%Y 1970", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%d/%m/%Y %H:%M:%S.%f", c"01/01/1970 00:00:00.000000", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%b %d %Y %I %p", c"Jan 01 1970 12 AM", 1, 1970, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"%w %u %U %W %V %G", c"4 4 00 00 01 1970", 1, 1900, 1, 4, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%Y-%m-%d %H:%M:%S", c"9999-12-31 23:59:59", 1, 9999, 12, 31, 23, 59, 59, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%Y-%m-%dT%H:%M:%S.%f%z", c"9999-12-31T23:59:59.999999", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%a, %d %b %Y %H:%M:%S %z", c"Fri, 31 Dec 9999 23:59:59 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%A %B %d %Y", c"Friday December 31 9999", 1, 9999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%I:%M:%S %p", c"11:59:59 PM", 1, 1900, 1, 1, 23, 59, 59, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%y%m%d", c"991231", 1, 1999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%j", c"365", 1, 1900, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%Y %j", c"9999 365", 1, 9999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%Y %U %w", c"9999 52 5", 1, 9999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%Y %W %a", c"9999 52 Fri", 1, 9999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%G-W%V-%u", c"9999-W52-5", 1, 9999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%c", c"Fri Dec 31 23:59:59 9999", 1, 9999, 12, 31, 23, 59, 59, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%x", c"12/31/99", 1, 1999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%X", c"23:59:59", 1, 1900, 1, 1, 23, 59, 59, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%Z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%Y-%m-%d %H:%M %Z", c"9999-12-31 23:59 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%:z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%%Y %Y", c"%Y 9999", 1, 9999, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%d/%m/%Y %H:%M:%S.%f", c"31/12/9999 23:59:59.999999", 1, 9999, 12, 31, 23, 59, 59, 999999, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%b %d %Y %I %p", c"Dec 31 9999 11 PM", 1, 9999, 12, 31, 23, 0, 0, 0, 0, 0)
	check_round_trip(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"%w %u %U %W %V %G", c"5 5 52 52 52 9999", 1, 1900, 12, 28, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%Y-%m-%d %H:%M:%S", c"1000-01-01 12:00:00", 1, 1000, 1, 1, 12, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%Y-%m-%dT%H:%M:%S.%f%z", c"1000-01-01T12:00:00.000001", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%a, %d %b %Y %H:%M:%S %z", c"Wed, 01 Jan 1000 12:00:00 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%A %B %d %Y", c"Wednesday January 01 1000", 1, 1000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%I:%M:%S %p", c"12:00:00 PM", 1, 1900, 1, 1, 12, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%y%m%d", c"000101", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%j", c"001", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%Y %j", c"1000 001", 1, 1000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%Y %U %w", c"1000 00 3", 1, 1000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%Y %W %a", c"1000 00 Wed", 1, 1000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%G-W%V-%u", c"1000-W01-3", 1, 1000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%c", c"Wed Jan  1 12:00:00 1000", 1, 1000, 1, 1, 12, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%x", c"01/01/00", 1, 2000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%X", c"12:00:00", 1, 1900, 1, 1, 12, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%Z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%Y-%m-%d %H:%M %Z", c"1000-01-01 12:00 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%:z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%%Y %Y", c"%Y 1000", 1, 1000, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%d/%m/%Y %H:%M:%S.%f", c"01/01/1000 12:00:00.000001", 1, 1000, 1, 1, 12, 0, 0, 1, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%b %d %Y %I %p", c"Jan 01 1000 12 PM", 1, 1000, 1, 1, 12, 0, 0, 0, 0, 0)
	check_round_trip(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"%w %u %U %W %V %G", c"3 3 00 00 01 1000", 1, 1900, 1, 3, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%Y-%m-%d %H:%M:%S", c"2008-12-29 07:07:07", 1, 2008, 12, 29, 7, 7, 7, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%Y-%m-%dT%H:%M:%S.%f%z", c"2008-12-29T07:07:07.000000+010203", 1, 2008, 12, 29, 7, 7, 7, 0, 1, 3723)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%a, %d %b %Y %H:%M:%S %z", c"Mon, 29 Dec 2008 07:07:07 +010203", 1, 2008, 12, 29, 7, 7, 7, 0, 1, 3723)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%A %B %d %Y", c"Monday December 29 2008", 1, 2008, 12, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%I:%M:%S %p", c"07:07:07 AM", 1, 1900, 1, 1, 7, 7, 7, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%y%m%d", c"081229", 1, 2008, 12, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%j", c"364", 1, 1900, 12, 30, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%Y %j", c"2008 364", 1, 2008, 12, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%Y %U %w", c"2008 52 1", 1, 2008, 12, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%Y %W %a", c"2008 52 Mon", 1, 2008, 12, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%G-W%V-%u", c"2009-W01-1", 1, 2008, 12, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%c", c"Mon Dec 29 07:07:07 2008", 1, 2008, 12, 29, 7, 7, 7, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%x", c"12/29/08", 1, 2008, 12, 29, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%X", c"07:07:07", 1, 1900, 1, 1, 7, 7, 7, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%Z", c"UTC+01:02:03", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%Y-%m-%d %H:%M %Z", c"2008-12-29 07:07 UTC+01:02:03", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%:z", c"+01:02:03", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%%Y %Y", c"%Y 2008", 1, 2008, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%d/%m/%Y %H:%M:%S.%f", c"29/12/2008 07:07:07.000000", 1, 2008, 12, 29, 7, 7, 7, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%b %d %Y %I %p", c"Dec 29 2008 07 AM", 1, 2008, 12, 29, 7, 0, 0, 0, 0, 0)
	check_round_trip(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"%w %u %U %W %V %G", c"1 1 52 52 01 2009", 1, 1900, 12, 24, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%Y-%m-%d %H:%M:%S", c"2026-10-16 00:00:00", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%Y-%m-%dT%H:%M:%S.%f%z", c"2026-10-16T00:00:00.000000-0100", 1, 2026, 10, 16, 0, 0, 0, 0, 1, -3600)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%a, %d %b %Y %H:%M:%S %z", c"Fri, 16 Oct 2026 00:00:00 -0100", 1, 2026, 10, 16, 0, 0, 0, 0, 1, -3600)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%A %B %d %Y", c"Friday October 16 2026", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%I:%M:%S %p", c"12:00:00 AM", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%y%m%d", c"261016", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%j", c"289", 1, 1900, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%Y %j", c"2026 289", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%Y %U %w", c"2026 41 5", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%Y %W %a", c"2026 41 Fri", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%G-W%V-%u", c"2026-W42-5", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%c", c"Fri Oct 16 00:00:00 2026", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%x", c"10/16/26", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%X", c"00:00:00", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%Z", c"UTC-01:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%Y-%m-%d %H:%M %Z", c"2026-10-16 00:00 UTC-01:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%:z", c"-01:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%%Y %Y", c"%Y 2026", 1, 2026, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%d/%m/%Y %H:%M:%S.%f", c"16/10/2026 00:00:00.000000", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%b %d %Y %I %p", c"Oct 16 2026 12 AM", 1, 2026, 10, 16, 0, 0, 0, 0, 0, 0)
	check_round_trip(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"%w %u %U %W %V %G", c"5 5 41 41 42 2026", 1, 1900, 10, 12, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%Y-%m-%d %H:%M:%S", c"2023-01-01 11:59:59", 1, 2023, 1, 1, 11, 59, 59, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%Y-%m-%dT%H:%M:%S.%f%z", c"2023-01-01T11:59:59.000000", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%a, %d %b %Y %H:%M:%S %z", c"Sun, 01 Jan 2023 11:59:59 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%A %B %d %Y", c"Sunday January 01 2023", 1, 2023, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%I:%M:%S %p", c"11:59:59 AM", 1, 1900, 1, 1, 11, 59, 59, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%y%m%d", c"230101", 1, 2023, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%j", c"001", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%Y %j", c"2023 001", 1, 2023, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%Y %U %w", c"2023 01 0", 1, 2023, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%Y %W %a", c"2023 00 Sun", 1, 2023, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%G-W%V-%u", c"2022-W52-7", 1, 2023, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%c", c"Sun Jan  1 11:59:59 2023", 1, 2023, 1, 1, 11, 59, 59, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%x", c"01/01/23", 1, 2023, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%X", c"11:59:59", 1, 1900, 1, 1, 11, 59, 59, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%Z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%Y-%m-%d %H:%M %Z", c"2023-01-01 11:59 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%:z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%%Y %Y", c"%Y 2023", 1, 2023, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%d/%m/%Y %H:%M:%S.%f", c"01/01/2023 11:59:59.000000", 1, 2023, 1, 1, 11, 59, 59, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%b %d %Y %I %p", c"Jan 01 2023 11 AM", 1, 2023, 1, 1, 11, 0, 0, 0, 0, 0)
	check_round_trip(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"%w %u %U %W %V %G", c"0 7 01 00 52 2022", 1, 1900, 1, 7, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%Y-%m-%d %H:%M:%S", c"2016-01-04 20:00:00", 1, 2016, 1, 4, 20, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%Y-%m-%dT%H:%M:%S.%f%z", c"2016-01-04T20:00:00.000000", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%a, %d %b %Y %H:%M:%S %z", c"Mon, 04 Jan 2016 20:00:00 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%A %B %d %Y", c"Monday January 04 2016", 1, 2016, 1, 4, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%I:%M:%S %p", c"08:00:00 PM", 1, 1900, 1, 1, 20, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%y%m%d", c"160104", 1, 2016, 1, 4, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%j", c"004", 1, 1900, 1, 4, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%Y %j", c"2016 004", 1, 2016, 1, 4, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%Y %U %w", c"2016 01 1", 1, 2016, 1, 4, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%Y %W %a", c"2016 01 Mon", 1, 2016, 1, 4, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%G-W%V-%u", c"2016-W01-1", 1, 2016, 1, 4, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%c", c"Mon Jan  4 20:00:00 2016", 1, 2016, 1, 4, 20, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%x", c"01/04/16", 1, 2016, 1, 4, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%X", c"20:00:00", 1, 1900, 1, 1, 20, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%Z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%Y-%m-%d %H:%M %Z", c"2016-01-04 20:00 ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%:z", c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%%Y %Y", c"%Y 2016", 1, 2016, 1, 1, 0, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%d/%m/%Y %H:%M:%S.%f", c"04/01/2016 20:00:00.000000", 1, 2016, 1, 4, 20, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%b %d %Y %I %p", c"Jan 04 2016 08 PM", 1, 2016, 1, 4, 20, 0, 0, 0, 0, 0)
	check_round_trip(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"%w %u %U %W %V %G", c"1 1 01 01 01 2016", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)

void test_strptime_python_cases():
	check_strptime(c"5/3/2024", c"%d/%m/%Y", 1, 2024, 3, 5, 0, 0, 0, 0, 0, 0)
	check_strptime(c" 5 Mar 2024", c"%d %b %Y", 1, 2024, 3, 5, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024-03-05   10:00", c"%Y-%m-%d %H:%M", 1, 2024, 3, 5, 10, 0, 0, 0, 0, 0)
	check_strptime(c"MARCH 5 2024", c"%B %d %Y", 1, 2024, 3, 5, 0, 0, 0, 0, 0, 0)
	check_strptime(c"mon 2024 1 1", c"%a %Y %m %d", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"12 AM", c"%I %p", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"12 PM", c"%I %p", 1, 1900, 1, 1, 12, 0, 0, 0, 0, 0)
	check_strptime(c"1 pm", c"%I %p", 1, 1900, 1, 1, 13, 0, 0, 0, 0, 0)
	check_strptime(c"12", c"%I", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024-02-30", c"%Y-%m-%d", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"02-29", c"%m-%d", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024-02-29", c"%Y-%m-%d", 1, 2024, 2, 29, 0, 0, 0, 0, 0, 0)
	check_strptime(c"123", c"%d%m", 1, 1900, 3, 12, 0, 0, 0, 0, 0, 0)
	check_strptime(c"1112024", c"%m%d%Y", 1, 2024, 11, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024 366", c"%Y %j", 1, 2024, 12, 31, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2023 366", c"%Y %j", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024 0 0", c"%Y %U %w", 1, 2023, 12, 31, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024 0 1", c"%Y %W %w", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024 53 6", c"%Y %U %w", 1, 2025, 1, 11, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024-01-01T10:00:00Z", c"%Y-%m-%dT%H:%M:%S%z", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 0)
	check_strptime(c"+05:30", c"%z", 1, 1900, 1, 1, 0, 0, 0, 0, 1, 19800)
	check_strptime(c"+0530", c"%z", 1, 1900, 1, 1, 0, 0, 0, 0, 1, 19800)
	check_strptime(c"-0800", c"%z", 1, 1900, 1, 1, 0, 0, 0, 0, 1, -28800)
	check_strptime(c"+05:3000", c"%z", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"+053000.000000", c"%z", 1, 1900, 1, 1, 0, 0, 0, 0, 1, 19800)
	check_strptime(c"+05:30:15", c"%z", 1, 1900, 1, 1, 0, 0, 0, 0, 1, 19815)
	check_strptime(c"-00:00:01", c"%z", 1, 1900, 1, 1, 0, 0, 0, 0, 1, -1)
	check_strptime(c"+24:00", c"%z", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"+23:59", c"%z", 1, 1900, 1, 1, 0, 0, 0, 0, 1, 86340)
	check_strptime(c"z", c"%z", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"10:00:60", c"%H:%M:%S", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"10:00:61", c"%H:%M:%S", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"1.5", c"%S.%f", 1, 1900, 1, 1, 0, 0, 1, 500000, 0, 0)
	check_strptime(c"1.1234567", c"%S.%f", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024 1 1", c"%G %V %u", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2020 53 7", c"%G %V %u", 1, 2021, 1, 3, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2021 53 1", c"%G %V %u", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024 1", c"%G %V", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024 1 1", c"%Y %V %u", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024 5", c"%Y %j", 1, 2024, 1, 5, 0, 0, 0, 0, 0, 0)
	check_strptime(c"%", c"%%", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"x", c"%Q", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"x", c"%", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"1 1", c"%d %d", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024-01-01 utc", c"%Y-%m-%d %Z", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024-01-01 EST", c"%Y-%m-%d %Z", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"Mon Jan  1 00:00:00 2024", c"%c", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"Tue Feb 13 07:08:09 2024", c"%c", 1, 2024, 2, 13, 7, 8, 9, 0, 0, 0)
	check_strptime(c"12/31/99", c"%x", 1, 1999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_strptime(c"01/01/68", c"%x", 1, 2068, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"01/01/69", c"%x", 1, 1969, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"23:59:59", c"%X", 1, 1900, 1, 1, 23, 59, 59, 0, 0, 0)
	check_strptime(c"abc", c"abc", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"ABC", c"abc", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024-01-01extra", c"%Y-%m-%d", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"", c"", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024\t\n01", c"%Y %m", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024 01", c"%Y\t%m", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"202401", c"%Y %m", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"Wednesday", c"%A", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"wed", c"%a", 1, 1900, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"Wed", c"%A", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"Sept", c"%b", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"Sep", c"%B", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c" 7", c"%H", 1, 1900, 1, 1, 7, 0, 0, 0, 0, 0)
	check_strptime(c"7", c"%H", 1, 1900, 1, 1, 7, 0, 0, 0, 0, 0)
	check_strptime(c"07", c"%H", 1, 1900, 1, 1, 7, 0, 0, 0, 0, 0)
	check_strptime(c"24", c"%H", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024 2 1 13", c"%Y %m %d %I", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"1 1 1 1", c"%y %m %d %H", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"05", c"%y", 1, 2005, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"69", c"%y", 1, 1969, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"99999", c"%Y", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"0001-01-01", c"%Y-%m-%d", 1, 1, 1, 1, 0, 0, 0, 0, 0, 0)
	check_strptime(c"0000-01-01", c"%Y-%m-%d", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024-1-5", c"%Y-%m-%d", 1, 2024, 1, 5, 0, 0, 0, 0, 0, 0)
	check_strptime(c"2024-01-05 1:2:3", c"%Y-%m-%d %H:%M:%S", 1, 2024, 1, 5, 1, 2, 3, 0, 0, 0)
	check_strptime(c"23 pm", c"%H %p", 1, 1900, 1, 1, 23, 0, 0, 0, 0, 0)
	check_strptime(c"3 pm 4", c"%I %p %H", 1, 1900, 1, 1, 4, 0, 0, 0, 0, 0)

void test_isoformat_table():
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, 'T', 0, c"2024-02-29T13:05:09.123456")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, ' ', 0, c"2024-02-29 13:05:09.123456")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, 'T', 1, c"2024-02-29T13")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, ' ', 1, c"2024-02-29 13")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, 'T', 2, c"2024-02-29T13:05")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, ' ', 2, c"2024-02-29 13:05")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, 'T', 3, c"2024-02-29T13:05:09")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, ' ', 3, c"2024-02-29 13:05:09")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, 'T', 4, c"2024-02-29T13:05:09.123")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, ' ', 4, c"2024-02-29 13:05:09.123")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, 'T', 5, c"2024-02-29T13:05:09.123456")
	check_isoformat(2024, 2, 29, 13, 5, 9, 123456, 0, 0, ' ', 5, c"2024-02-29 13:05:09.123456")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, 'T', 0, c"1999-12-31T23:59:59+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, ' ', 0, c"1999-12-31 23:59:59+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, 'T', 1, c"1999-12-31T23+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, ' ', 1, c"1999-12-31 23+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, 'T', 2, c"1999-12-31T23:59+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, ' ', 2, c"1999-12-31 23:59+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, 'T', 3, c"1999-12-31T23:59:59+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, ' ', 3, c"1999-12-31 23:59:59+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, 'T', 4, c"1999-12-31T23:59:59.000+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, ' ', 4, c"1999-12-31 23:59:59.000+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, 'T', 5, c"1999-12-31T23:59:59.000000+00:00")
	check_isoformat(1999, 12, 31, 23, 59, 59, 0, 1, 0, ' ', 5, c"1999-12-31 23:59:59.000000+00:00")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, 'T', 0, c"2000-01-01T00:00:00+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, ' ', 0, c"2000-01-01 00:00:00+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, 'T', 1, c"2000-01-01T00+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, ' ', 1, c"2000-01-01 00+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, 'T', 2, c"2000-01-01T00:00+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, ' ', 2, c"2000-01-01 00:00+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, 'T', 3, c"2000-01-01T00:00:00+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, ' ', 3, c"2000-01-01 00:00:00+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, 'T', 4, c"2000-01-01T00:00:00.000+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, ' ', 4, c"2000-01-01 00:00:00.000+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, 'T', 5, c"2000-01-01T00:00:00.000000+05:30")
	check_isoformat(2000, 1, 1, 0, 0, 0, 0, 1, 19800, ' ', 5, c"2000-01-01 00:00:00.000000+05:30")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, 'T', 0, c"2021-01-03T12:30:00.500000-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, ' ', 0, c"2021-01-03 12:30:00.500000-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, 'T', 1, c"2021-01-03T12-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, ' ', 1, c"2021-01-03 12-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, 'T', 2, c"2021-01-03T12:30-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, ' ', 2, c"2021-01-03 12:30-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, 'T', 3, c"2021-01-03T12:30:00-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, ' ', 3, c"2021-01-03 12:30:00-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, 'T', 4, c"2021-01-03T12:30:00.500-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, ' ', 4, c"2021-01-03 12:30:00.500-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, 'T', 5, c"2021-01-03T12:30:00.500000-08:00")
	check_isoformat(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, ' ', 5, c"2021-01-03 12:30:00.500000-08:00")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, 'T', 0, c"2020-12-31T00:00:01")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, ' ', 0, c"2020-12-31 00:00:01")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, 'T', 1, c"2020-12-31T00")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, ' ', 1, c"2020-12-31 00")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, 'T', 2, c"2020-12-31T00:00")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, ' ', 2, c"2020-12-31 00:00")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, 'T', 3, c"2020-12-31T00:00:01")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, ' ', 3, c"2020-12-31 00:00:01")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, 'T', 4, c"2020-12-31T00:00:01.000")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, ' ', 4, c"2020-12-31 00:00:01.000")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, 'T', 5, c"2020-12-31T00:00:01.000000")
	check_isoformat(2020, 12, 31, 0, 0, 1, 0, 0, 0, ' ', 5, c"2020-12-31 00:00:01.000000")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, 'T', 0, c"1970-01-01T00:00:00+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, ' ', 0, c"1970-01-01 00:00:00+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, 'T', 1, c"1970-01-01T00+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, ' ', 1, c"1970-01-01 00+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, 'T', 2, c"1970-01-01T00:00+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, ' ', 2, c"1970-01-01 00:00+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, 'T', 3, c"1970-01-01T00:00:00+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, ' ', 3, c"1970-01-01 00:00:00+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, 'T', 4, c"1970-01-01T00:00:00.000+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, ' ', 4, c"1970-01-01 00:00:00.000+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, 'T', 5, c"1970-01-01T00:00:00.000000+00:00")
	check_isoformat(1970, 1, 1, 0, 0, 0, 0, 1, 0, ' ', 5, c"1970-01-01 00:00:00.000000+00:00")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, 'T', 0, c"9999-12-31T23:59:59.999999")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, ' ', 0, c"9999-12-31 23:59:59.999999")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, 'T', 1, c"9999-12-31T23")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, ' ', 1, c"9999-12-31 23")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, 'T', 2, c"9999-12-31T23:59")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, ' ', 2, c"9999-12-31 23:59")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, 'T', 3, c"9999-12-31T23:59:59")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, ' ', 3, c"9999-12-31 23:59:59")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, 'T', 4, c"9999-12-31T23:59:59.999")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, ' ', 4, c"9999-12-31 23:59:59.999")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, 'T', 5, c"9999-12-31T23:59:59.999999")
	check_isoformat(9999, 12, 31, 23, 59, 59, 999999, 0, 0, ' ', 5, c"9999-12-31 23:59:59.999999")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, 'T', 0, c"1000-01-01T12:00:00.000001")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, ' ', 0, c"1000-01-01 12:00:00.000001")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, 'T', 1, c"1000-01-01T12")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, ' ', 1, c"1000-01-01 12")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, 'T', 2, c"1000-01-01T12:00")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, ' ', 2, c"1000-01-01 12:00")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, 'T', 3, c"1000-01-01T12:00:00")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, ' ', 3, c"1000-01-01 12:00:00")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, 'T', 4, c"1000-01-01T12:00:00.000")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, ' ', 4, c"1000-01-01 12:00:00.000")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, 'T', 5, c"1000-01-01T12:00:00.000001")
	check_isoformat(1000, 1, 1, 12, 0, 0, 1, 0, 0, ' ', 5, c"1000-01-01 12:00:00.000001")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, 'T', 0, c"2008-12-29T07:07:07+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, ' ', 0, c"2008-12-29 07:07:07+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, 'T', 1, c"2008-12-29T07+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, ' ', 1, c"2008-12-29 07+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, 'T', 2, c"2008-12-29T07:07+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, ' ', 2, c"2008-12-29 07:07+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, 'T', 3, c"2008-12-29T07:07:07+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, ' ', 3, c"2008-12-29 07:07:07+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, 'T', 4, c"2008-12-29T07:07:07.000+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, ' ', 4, c"2008-12-29 07:07:07.000+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, 'T', 5, c"2008-12-29T07:07:07.000000+01:02:03")
	check_isoformat(2008, 12, 29, 7, 7, 7, 0, 1, 3723, ' ', 5, c"2008-12-29 07:07:07.000000+01:02:03")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, 'T', 0, c"2026-10-16T00:00:00-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, ' ', 0, c"2026-10-16 00:00:00-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, 'T', 1, c"2026-10-16T00-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, ' ', 1, c"2026-10-16 00-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, 'T', 2, c"2026-10-16T00:00-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, ' ', 2, c"2026-10-16 00:00-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, 'T', 3, c"2026-10-16T00:00:00-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, ' ', 3, c"2026-10-16 00:00:00-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, 'T', 4, c"2026-10-16T00:00:00.000-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, ' ', 4, c"2026-10-16 00:00:00.000-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, 'T', 5, c"2026-10-16T00:00:00.000000-01:00")
	check_isoformat(2026, 10, 16, 0, 0, 0, 0, 1, -3600, ' ', 5, c"2026-10-16 00:00:00.000000-01:00")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, 'T', 0, c"2023-01-01T11:59:59")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, ' ', 0, c"2023-01-01 11:59:59")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, 'T', 1, c"2023-01-01T11")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, ' ', 1, c"2023-01-01 11")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, 'T', 2, c"2023-01-01T11:59")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, ' ', 2, c"2023-01-01 11:59")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, 'T', 3, c"2023-01-01T11:59:59")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, ' ', 3, c"2023-01-01 11:59:59")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, 'T', 4, c"2023-01-01T11:59:59.000")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, ' ', 4, c"2023-01-01 11:59:59.000")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, 'T', 5, c"2023-01-01T11:59:59.000000")
	check_isoformat(2023, 1, 1, 11, 59, 59, 0, 0, 0, ' ', 5, c"2023-01-01 11:59:59.000000")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, 'T', 0, c"2016-01-04T20:00:00")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, ' ', 0, c"2016-01-04 20:00:00")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, 'T', 1, c"2016-01-04T20")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, ' ', 1, c"2016-01-04 20")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, 'T', 2, c"2016-01-04T20:00")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, ' ', 2, c"2016-01-04 20:00")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, 'T', 3, c"2016-01-04T20:00:00")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, ' ', 3, c"2016-01-04 20:00:00")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, 'T', 4, c"2016-01-04T20:00:00.000")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, ' ', 4, c"2016-01-04 20:00:00.000")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, 'T', 5, c"2016-01-04T20:00:00.000000")
	check_isoformat(2016, 1, 4, 20, 0, 0, 0, 0, 0, ' ', 5, c"2016-01-04 20:00:00.000000")

void test_fromisoformat_table():
	check_fromisoformat(c"2024-01-01", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"20240101", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-W01", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024W01", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-W01-1", 1, 2024, 1, 1, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024W017", 1, 2024, 1, 7, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2020-W53-7", 1, 2021, 1, 3, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2021-W53", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-001", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-1-01", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-1", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"202401-01", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-0101", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-13-01", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-02-30", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"0000-01-01", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"9999-12-31", 1, 9999, 12, 31, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10", 1, 2024, 1, 1, 10, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T1030", 1, 2024, 1, 1, 10, 30, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:30", 1, 2024, 1, 1, 10, 30, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:30:15", 1, 2024, 1, 1, 10, 30, 15, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T103015", 1, 2024, 1, 1, 10, 30, 15, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:30:15.5", 1, 2024, 1, 1, 10, 30, 15, 500000, 0, 0)
	check_fromisoformat(c"2024-01-01T10:30:15,25", 1, 2024, 1, 1, 10, 30, 15, 250000, 0, 0)
	check_fromisoformat(c"2024-01-01T10:30:15.1234567", 1, 2024, 1, 1, 10, 30, 15, 123456, 0, 0)
	check_fromisoformat(c"2024-01-01T10:30:15.123456789", 1, 2024, 1, 1, 10, 30, 15, 123456, 0, 0)
	check_fromisoformat(c"2024-01-01T10:30:15.", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:3015", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T1030:15", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01 10:30Z", 1, 2024, 1, 1, 10, 30, 0, 0, 1, 0)
	check_fromisoformat(c"2024-01-01T10:30:15+05:30", 1, 2024, 1, 1, 10, 30, 15, 0, 1, 19800)
	check_fromisoformat(c"2024-01-01T10:30:15-0800", 1, 2024, 1, 1, 10, 30, 15, 0, 1, -28800)
	check_fromisoformat(c"2024-01-01T10+05", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 18000)
	check_fromisoformat(c"2024-01-01T10:00:00+05:30:15", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 19815)
	check_fromisoformat(c"2024-01-01T10:00:00+053015", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 19815)
	check_fromisoformat(c"2024-01-01T10:00:00+05:30:15.5", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:00:00+05:30:15.000000", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 19815)
	check_fromisoformat(c"2024-01-01T10:00:00+00:00", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 0)
	check_fromisoformat(c"2024-01-01T10:00:00-00:00", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 0)
	check_fromisoformat(c"2024-01-01T10:00:00+24:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:00:00+23:59", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 86340)
	check_fromisoformat(c"2024-01-01T10:00:00+05:60", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 21600)
	check_fromisoformat(c"2024-01-01T10:00:00+0", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:00:00+050", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:00:00Z", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 0)
	check_fromisoformat(c"2024-01-01T10:00:00z", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:00:00Zx", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01x10", 1, 2024, 1, 1, 10, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01é10:00", 1, 2024, 1, 1, 10, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01TT", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T1", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T24:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T23:60", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T23:59:60", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"20240101T103015", 1, 2024, 1, 1, 10, 30, 15, 0, 0, 0)
	check_fromisoformat(c"2024W01T10", 1, 2024, 1, 1, 10, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-W01T10", 1, 2024, 1, 1, 10, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-W01-2T10", 1, 2024, 1, 2, 10, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024W012T10", 1, 2024, 1, 2, 10, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024W0110", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024W01210", 1, 2024, 1, 1, 10, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:00:00.000001+01:00", 1, 2024, 1, 1, 10, 0, 0, 1, 1, 3600)
	check_fromisoformat(c"2024-01-01T10:00:00 +01:00", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 3600)
	check_fromisoformat(c"2024", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-W5", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-W01-8", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-W00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"20241301", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:00:00+01:00:00", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 3600)
	check_fromisoformat(c"2024-01-01T10:00:00+01:00:0", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10203012", 1, 2024, 1, 1, 10, 20, 30, 120000, 0, 0)
	check_fromisoformat(c"2024-01-01T10:20:30:5", 1, 2024, 1, 1, 10, 20, 30, 500000, 0, 0)
	check_fromisoformat(c"2024-01-01T10:20:30:00", 1, 2024, 1, 1, 10, 20, 30, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:20:30.1234567x+01:00", 1, 2024, 1, 1, 10, 20, 30, 123456, 1, 3600)
	check_fromisoformat(c"2024-01-01T10:20:30.5x+01:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10 +01:00", 1, 2024, 1, 1, 10, 0, 0, 0, 1, 3600)
	check_fromisoformat(c"2024-01-01T10:00:00  +01:00", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:00:00x", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:20:30.,5", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_fromisoformat(c"2024-01-01T10:20:30,", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

void test_rfc2822_format_table():
	check_rfc2822_format(2024, 2, 29, 13, 5, 9, 123456, 0, 0, c"Thu, 29 Feb 2024 13:05:09 -0000", c"Thu, 29 Feb 2024 13:05:09 GMT")
	check_rfc2822_format(1999, 12, 31, 23, 59, 59, 0, 1, 0, c"Fri, 31 Dec 1999 23:59:59 +0000", c"Fri, 31 Dec 1999 23:59:59 GMT")
	check_rfc2822_format(2000, 1, 1, 0, 0, 0, 0, 1, 19800, c"Sat, 01 Jan 2000 00:00:00 +0530", c"Fri, 31 Dec 1999 18:30:00 GMT")
	check_rfc2822_format(2021, 1, 3, 12, 30, 0, 500000, 1, -28800, c"Sun, 03 Jan 2021 12:30:00 -0800", c"Sun, 03 Jan 2021 20:30:00 GMT")
	check_rfc2822_format(2020, 12, 31, 0, 0, 1, 0, 0, 0, c"Thu, 31 Dec 2020 00:00:01 -0000", c"Thu, 31 Dec 2020 00:00:01 GMT")
	check_rfc2822_format(1970, 1, 1, 0, 0, 0, 0, 1, 0, c"Thu, 01 Jan 1970 00:00:00 +0000", c"Thu, 01 Jan 1970 00:00:00 GMT")
	check_rfc2822_format(9999, 12, 31, 23, 59, 59, 999999, 0, 0, c"Fri, 31 Dec 9999 23:59:59 -0000", c"Fri, 31 Dec 9999 23:59:59 GMT")
	check_rfc2822_format(1000, 1, 1, 12, 0, 0, 1, 0, 0, c"Wed, 01 Jan 1000 12:00:00 -0000", c"Wed, 01 Jan 1000 12:00:00 GMT")
	check_rfc2822_format(2008, 12, 29, 7, 7, 7, 0, 1, 3723, c"Mon, 29 Dec 2008 07:07:07 +010203", c"Mon, 29 Dec 2008 06:05:04 GMT")
	check_rfc2822_format(2026, 10, 16, 0, 0, 0, 0, 1, -3600, c"Fri, 16 Oct 2026 00:00:00 -0100", c"Fri, 16 Oct 2026 01:00:00 GMT")
	check_rfc2822_format(2023, 1, 1, 11, 59, 59, 0, 0, 0, c"Sun, 01 Jan 2023 11:59:59 -0000", c"Sun, 01 Jan 2023 11:59:59 GMT")
	check_rfc2822_format(2016, 1, 4, 20, 0, 0, 0, 0, 0, c"Mon, 04 Jan 2016 20:00:00 -0000", c"Mon, 04 Jan 2016 20:00:00 GMT")

void test_rfc2822_parse_table():
	check_rfc2822_parse(c"Sun, 06 Nov 1994 08:49:37 GMT", 1, 1994, 11, 6, 8, 49, 37, 0, 1, 0)
	check_rfc2822_parse(c"Sunday, 06-Nov-94 08:49:37 GMT", 1, 1994, 11, 6, 8, 49, 37, 0, 1, 0)
	check_rfc2822_parse(c"Sun Nov  6 08:49:37 1994", 1, 1994, 11, 6, 8, 49, 37, 0, 0, 0)
	check_rfc2822_parse(c"Fri, 09 Nov 2001 01:08:47 -0500", 1, 2001, 11, 9, 1, 8, 47, 0, 1, -18000)
	check_rfc2822_parse(c"Fri, 9 Nov 2001 01:08:47 -0000", 1, 2001, 11, 9, 1, 8, 47, 0, 0, 0)
	check_rfc2822_parse(c"9 Nov 2001 01:08:47 +0000", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 0)
	check_rfc2822_parse(c"Fri,9 Nov 2001 01:08:47 EST", 1, 2001, 11, 9, 1, 8, 47, 0, 1, -18000)
	check_rfc2822_parse(c"Fri, 09 Nov 2001 01:08 PDT", 1, 2001, 11, 9, 1, 8, 0, 0, 1, -25200)
	check_rfc2822_parse(c"Fri, 09 Nov 2001 01.08.47 +0100", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"Fri, 09 Nov 2001 01.08 +0100", 1, 2001, 11, 9, 1, 8, 0, 0, 1, 3600)
	check_rfc2822_parse(c"Fri, 09 Nov 01 01:08:47 +0100", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"Fri, 09 Nov 69 01:08:47 +0100", 1, 1969, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"Fri, 09 Nov 68 01:08:47 +0100", 1, 2068, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"Fri, 09 November 2001 01:08:47 +0100", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"Fri, Nov 09 2001 01:08:47 +0100", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"Fri, 09 Nov 2001 01:08:47+0100", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"Fri, 09 Nov 2001 01:08:47-0100", 1, 2001, 11, 9, 1, 8, 47, 0, 1, -3600)
	check_rfc2822_parse(c"Fri, 09 Nov 2001 01:08:47", 1, 2001, 11, 9, 1, 8, 47, 0, 0, 0)
	check_rfc2822_parse(c"09 Nov 2001 01:08:47 XYZ", 1, 2001, 11, 9, 1, 8, 47, 0, 0, 0)
	check_rfc2822_parse(c"09 Nov 2001 01:08:47 +2400", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"09 Nov 2001 01:08:47 +2359", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 86340)
	check_rfc2822_parse(c"09 Nov 2001 01:08:47 +0099", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 5940)
	check_rfc2822_parse(c"09 Nov 2001 25:08:47 +0000", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"09 Nov 2001 01:08:60 +0000", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"31 Feb 2001 01:08:47 +0000", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"   ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"Fri, 09 Nov", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"foo bar baz qux quux", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"09 Foo 2001 01:08:47 +0000", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"Fri, 09 Nov 2001 01:08:47 +0100 (CET)", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"Fri, 09 Nov 2001, 01:08:47 +0100", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"Fri 09 Nov 2001 01:08:47 +0100", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"Friday, 09 Nov 2001 01:08:47 +0100", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 3600)
	check_rfc2822_parse(c"fri, 09 nov 2001 01:08:47 gmt", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 0)
	check_rfc2822_parse(c"09 Nov 2001 01:08:47 Z", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 0)
	check_rfc2822_parse(c"Mon, 01 Jan 0001 00:00:00 +0000", 1, 2001, 1, 1, 0, 0, 0, 0, 1, 0)
	check_rfc2822_parse(c"Fri, 31 Dec 9999 23:59:59 -0100", 1, 9999, 12, 31, 23, 59, 59, 0, 1, -3600)
	check_rfc2822_parse(c"x,09 Nov 2001 01:08:47 +0000", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 0)
	check_rfc2822_parse(c"09 Nov 2001 01:08:47:00 +0000", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"09 Nov 2001 1:2 +0000", 1, 2001, 11, 9, 1, 2, 0, 0, 1, 0)
	check_rfc2822_parse(c"09 Nov 2_001 01:08:47 +0000", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 0)
	check_rfc2822_parse(c"Fri, 09 Nov 2001 01:08:47 -0", 1, 2001, 11, 9, 1, 8, 47, 0, 0, 0)
	check_rfc2822_parse(c"Fri, 09 Nov 2001 01:08:47 +5", 1, 2001, 11, 9, 1, 8, 47, 0, 1, 300)
	check_rfc2822_parse(c"09-Nov-2001 01:08:47", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	check_rfc2822_parse(c"09-Nov- 01:08:47 GMT", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)


/*
Generator for the test_*_table functions above (python3 -I gen.py), CPython 3.13:

# Generates the embedded tables of libs/standard/time/format_test.w.
import datetime as D, email.utils as E, warnings
warnings.simplefilter("ignore")
UTC = D.timezone.utc
def tz(s): return D.timezone(D.timedelta(seconds=s))

def q(s):
    return 'c"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\t', '\\t').replace('\n', '\\n') + '"'

def fields(dt):
    if dt is None:
        return "0, 0, 0, 0, 0, 0, 0, 0, 0, 0"
    off = dt.utcoffset()
    if off is not None and off.microseconds:
        return "0, 0, 0, 0, 0, 0, 0, 0, 0, 0"  # W offsets are whole seconds
    has = 0 if off is None else 1
    o = 0 if off is None else int(off.total_seconds())
    return f"1, {dt.year}, {dt.month}, {dt.day}, {dt.hour}, {dt.minute}, {dt.second}, {dt.microsecond}, {has}, {o}"

def dtargs(dt):
    off = dt.utcoffset()
    has = 0 if off is None else 1
    o = 0 if off is None else int(off.total_seconds())
    return f"{dt.year}, {dt.month}, {dt.day}, {dt.hour}, {dt.minute}, {dt.second}, {dt.microsecond}, {has}, {o}"

def attempt(f):
    try: return f()
    except Exception: return None

dts = [
    D.datetime(2024, 2, 29, 13, 5, 9, 123456),
    D.datetime(1999, 12, 31, 23, 59, 59, tzinfo=UTC),
    D.datetime(2000, 1, 1, 0, 0, 0, tzinfo=tz(19800)),
    D.datetime(2021, 1, 3, 12, 30, 0, 500000, tzinfo=tz(-28800)),
    D.datetime(2020, 12, 31, 0, 0, 1),
    D.datetime(1970, 1, 1, 0, 0, 0, tzinfo=UTC),
    D.datetime(9999, 12, 31, 23, 59, 59, 999999),
    D.datetime(1000, 1, 1, 12, 0, 0, 1),
    D.datetime(2008, 12, 29, 7, 7, 7, tzinfo=tz(3723)),
    D.datetime(2026, 10, 16, 0, 0, 0, tzinfo=tz(-3600)),
    D.datetime(2023, 1, 1, 11, 59, 59),
    D.datetime(2016, 1, 4, 20, 0, 0),
]
fmts = ["%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f%z", "%a, %d %b %Y %H:%M:%S %z",
        "%A %B %d %Y", "%I:%M:%S %p", "%y%m%d", "%j", "%Y %j", "%Y %U %w", "%Y %W %a",
        "%G-W%V-%u", "%c", "%x", "%X", "%Z", "%Y-%m-%d %H:%M %Z", "%:z", "%%Y %Y", "%d/%m/%Y %H:%M:%S.%f",
        "%b %d %Y %I %p", "%w %u %U %W %V %G"]
print("void test_strftime_strptime_table():")
for dt in dts:
    for f in fmts:
        s = dt.strftime(f)
        p = attempt(lambda: D.datetime.strptime(s, f))
        print(f"\tcheck_round_trip({dtargs(dt)}, {q(f)}, {q(s)}, {fields(p)})")
print()

inputs = [
    ("5/3/2024", "%d/%m/%Y"), (" 5 Mar 2024", "%d %b %Y"), ("2024-03-05   10:00", "%Y-%m-%d %H:%M"),
    ("MARCH 5 2024", "%B %d %Y"), ("mon 2024 1 1", "%a %Y %m %d"), ("12 AM", "%I %p"), ("12 PM", "%I %p"),
    ("1 pm", "%I %p"), ("12", "%I"), ("2024-02-30", "%Y-%m-%d"), ("02-29", "%m-%d"), ("2024-02-29", "%Y-%m-%d"),
    ("123", "%d%m"), ("1112024", "%m%d%Y"), ("2024 366", "%Y %j"), ("2023 366", "%Y %j"), ("2024 0 0", "%Y %U %w"),
    ("2024 0 1", "%Y %W %w"), ("2024 53 6", "%Y %U %w"), ("2024-01-01T10:00:00Z", "%Y-%m-%dT%H:%M:%S%z"),
    ("+05:30", "%z"), ("+0530", "%z"), ("-0800", "%z"), ("+05:3000", "%z"), ("+053000.000000", "%z"),
    ("+05:30:15", "%z"), ("-00:00:01", "%z"), ("+24:00", "%z"), ("+23:59", "%z"), ("z", "%z"),
    ("10:00:60", "%H:%M:%S"), ("10:00:61", "%H:%M:%S"), ("1.5", "%S.%f"), ("1.1234567", "%S.%f"),
    ("2024 1 1", "%G %V %u"), ("2020 53 7", "%G %V %u"), ("2021 53 1", "%G %V %u"), ("2024 1", "%G %V"),
    ("2024 1 1", "%Y %V %u"), ("2024 5", "%Y %j"),
    ("%", "%%"), ("x", "%Q"), ("x", "%"), ("1 1", "%d %d"), ("2024-01-01 utc", "%Y-%m-%d %Z"),
    ("2024-01-01 EST", "%Y-%m-%d %Z"), ("Mon Jan  1 00:00:00 2024", "%c"), ("Tue Feb 13 07:08:09 2024", "%c"),
    ("12/31/99", "%x"), ("01/01/68", "%x"), ("01/01/69", "%x"), ("23:59:59", "%X"), ("abc", "abc"), ("ABC", "abc"),
    ("2024-01-01extra", "%Y-%m-%d"), ("", ""), ("2024\t\n01", "%Y %m"), ("2024 01", "%Y\t%m"), ("202401", "%Y %m"),
    ("Wednesday", "%A"), ("wed", "%a"), ("Wed", "%A"), ("Sept", "%b"), ("Sep", "%B"), (" 7", "%H"), ("7", "%H"),
    ("07", "%H"), ("24", "%H"), ("2024 2 1 13", "%Y %m %d %I"), ("1 1 1 1", "%y %m %d %H"),
    ("05", "%y"), ("69", "%y"), ("99999", "%Y"), ("0001-01-01", "%Y-%m-%d"), ("0000-01-01", "%Y-%m-%d"),
    ("2024-1-5", "%Y-%m-%d"), ("2024-01-05 1:2:3", "%Y-%m-%d %H:%M:%S"), ("23 pm", "%H %p"), ("3 pm 4", "%I %p %H"),
]
print("void test_strptime_python_cases():")
for s, f in inputs:
    p = attempt(lambda: D.datetime.strptime(s, f))
    print(f"\tcheck_strptime({q(s)}, {q(f)}, {fields(p)})")
print()

print("void test_isoformat_table():")
specs = ["auto", "hours", "minutes", "seconds", "milliseconds", "microseconds"]
for dt in dts:
    for i, sp in enumerate(specs):
        for sep in ["T", " "]:
            s = dt.isoformat(sep, sp)
            print(f"\tcheck_isoformat({dtargs(dt)}, '{sep}', {i}, {q(s)})")
print()

isos = ["2024-01-01", "20240101", "2024-W01", "2024W01", "2024-W01-1", "2024W017", "2020-W53-7", "2021-W53",
    "2024-001", "2024-01", "2024-1-01", "2024-01-1", "202401-01", "2024-0101", "2024-13-01", "2024-02-30",
    "0000-01-01", "9999-12-31", "2024-01-01T10", "2024-01-01T1030", "2024-01-01T10:30", "2024-01-01T10:30:15",
    "2024-01-01T103015", "2024-01-01T10:30:15.5", "2024-01-01T10:30:15,25", "2024-01-01T10:30:15.1234567",
    "2024-01-01T10:30:15.123456789", "2024-01-01T10:30:15.", "2024-01-01T10:3015", "2024-01-01T1030:15",
    "2024-01-01 10:30Z", "2024-01-01T10:30:15+05:30", "2024-01-01T10:30:15-0800", "2024-01-01T10+05",
    "2024-01-01T10:00:00+05:30:15", "2024-01-01T10:00:00+053015", "2024-01-01T10:00:00+05:30:15.5",
    "2024-01-01T10:00:00+05:30:15.000000", "2024-01-01T10:00:00+00:00", "2024-01-01T10:00:00-00:00",
    "2024-01-01T10:00:00+24:00", "2024-01-01T10:00:00+23:59", "2024-01-01T10:00:00+05:60", "2024-01-01T10:00:00+0",
    "2024-01-01T10:00:00+050", "2024-01-01T10:00:00Z", "2024-01-01T10:00:00z", "2024-01-01T10:00:00Zx",
    "2024-01-01x10", "2024-01-01\u00e910:00", "2024-01-01T", "2024-01-01TT", "2024-01-01T1", "2024-01-01T24:00",
    "2024-01-01T23:60", "2024-01-01T23:59:60", "20240101T103015", "2024W01T10", "2024-W01T10", "2024-W01-2T10",
    "2024W012T10", "2024W0110", "2024W01210", "2024-01-01T10:00:00.000001+01:00", "2024-01-01T10:00:00 +01:00",
    "2024", "2024-W5", "2024-W01-8", "2024-W00", "20241301", "2024-01-01T10:00:00+01:00:00",
    "2024-01-01T10:00:00+01:00:0", "2024-01-01T10203012", "2024-01-01T10:20:30:5", "2024-01-01T10:20:30:00",
    "2024-01-01T10:20:30.1234567x+01:00", "2024-01-01T10:20:30.5x+01:00", "2024-01-01T10 +01:00",
    "2024-01-01T10:00:00  +01:00", "2024-01-01T10:00:00x", "2024-01-01T10:20:30.,5", "2024-01-01T10:20:30,",
]
print("void test_fromisoformat_table():")
for s in isos:
    p = attempt(lambda: D.datetime.fromisoformat(s))
    print(f"\tcheck_fromisoformat({q(s)}, {fields(p)})")
print()

print("void test_rfc2822_format_table():")
for dt in dts:
    s = E.format_datetime(dt)
    if dt.utcoffset() is None: g = E.format_datetime(dt.replace(tzinfo=UTC), usegmt=True)
    else: g = E.format_datetime(dt.astimezone(UTC), usegmt=True) if dt.year < 9999 else ""
    print(f"\tcheck_rfc2822_format({dtargs(dt)}, {q(s)}, {q(g)})")
print()

mails = ["Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994",
    "Fri, 09 Nov 2001 01:08:47 -0500", "Fri, 9 Nov 2001 01:08:47 -0000", "9 Nov 2001 01:08:47 +0000",
    "Fri,9 Nov 2001 01:08:47 EST", "Fri, 09 Nov 2001 01:08 PDT", "Fri, 09 Nov 2001 01.08.47 +0100",
    "Fri, 09 Nov 2001 01.08 +0100", "Fri, 09 Nov 01 01:08:47 +0100", "Fri, 09 Nov 69 01:08:47 +0100",
    "Fri, 09 Nov 68 01:08:47 +0100", "Fri, 09 November 2001 01:08:47 +0100", "Fri, Nov 09 2001 01:08:47 +0100",
    "Fri, 09 Nov 2001 01:08:47+0100", "Fri, 09 Nov 2001 01:08:47-0100", "Fri, 09 Nov 2001 01:08:47",
    "09 Nov 2001 01:08:47 XYZ", "09 Nov 2001 01:08:47 +2400", "09 Nov 2001 01:08:47 +2359",
    "09 Nov 2001 01:08:47 +0099", "09 Nov 2001 25:08:47 +0000", "09 Nov 2001 01:08:60 +0000",
    "31 Feb 2001 01:08:47 +0000", "", "   ", "Fri, 09 Nov", "foo bar baz qux quux", "09 Foo 2001 01:08:47 +0000",
    "Fri, 09 Nov 2001 01:08:47 +0100 (CET)", "Fri, 09 Nov 2001, 01:08:47 +0100", "Fri 09 Nov 2001 01:08:47 +0100",
    "Friday, 09 Nov 2001 01:08:47 +0100", "fri, 09 nov 2001 01:08:47 gmt", "09 Nov 2001 01:08:47 Z",
    "Mon, 01 Jan 0001 00:00:00 +0000", "Fri, 31 Dec 9999 23:59:59 -0100", "x,09 Nov 2001 01:08:47 +0000",
    "09 Nov 2001 01:08:47:00 +0000", "09 Nov 2001 1:2 +0000", "09 Nov 2_001 01:08:47 +0000",
    "Fri, 09 Nov 2001 01:08:47 -0", "Fri, 09 Nov 2001 01:08:47 +5", "09-Nov-2001 01:08:47", "09-Nov- 01:08:47 GMT",
]
print("void test_rfc2822_parse_table():")
for s in mails:
    p = attempt(lambda: E.parsedate_to_datetime(s))
    print(f"\tcheck_rfc2822_parse({q(s)}, {fields(p)})")
*/
