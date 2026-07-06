import lib.testing
import libs.standard.time.calendar
import libs.standard.time.datetime
import libs.standard.time.format


void assert_date(date d, int year, int month, int day):
	assert_equal(year, d.year)
	assert_equal(month, d.month)
	assert_equal(day, d.day)


void assert_time(time_of_day t, int hour, int minute, int second, int microsecond):
	assert_equal(hour, t.hour)
	assert_equal(minute, t.minute)
	assert_equal(second, t.second)
	assert_equal(microsecond, t.microsecond)


void assert_datetime(datetime dt, int year, int month, int day, int hour, int minute, int second, int microsecond):
	assert_date(dt.d, year, month, day)
	assert_time(dt.t, hour, minute, second, microsecond)


void assert_round_trip(int timestamp):
	datetime dt = datetime_from_unix_utc(timestamp)
	int got = 0
	assert_equal(1, datetime_to_unix_utc(dt, &got))
	assert_equal(timestamp, got)


void test_calendar_leap_years_and_month_lengths():
	assert_equal(1, calendar_isleap(2000))
	assert_equal(0, calendar_isleap(1900))
	assert_equal(1, calendar_isleap(2024))
	assert_equal(0, calendar_isleap(2023))
	assert_equal(29, calendar_days_in_month(2024, 2))
	assert_equal(28, calendar_days_in_month(2023, 2))
	assert_equal(30, calendar_days_in_month(2024, 11))
	assert_equal(31, calendar_days_in_month(2024, 12))


void test_date_valid_rejects_invalid_dates():
	assert_equal(1, date_valid(2024, 2, 29))
	assert_equal(0, date_valid(2023, 2, 29))
	assert_equal(0, date_valid(0, 1, 1))
	assert_equal(0, date_valid(2024, 0, 1))
	assert_equal(0, date_valid(2024, 13, 1))
	assert_equal(0, date_valid(2024, 4, 31))


void test_weekdays_match_python_numbering():
	assert_equal(0, calendar_weekday(1, 1, 1))
	assert_equal(3, calendar_weekday(1970, 1, 1))
	assert_equal(5, calendar_weekday(2000, 1, 1))
	assert_equal(3, calendar_weekday(2024, 2, 29))
	assert_equal(6, calendar_weekday(2023, 12, 31))


void test_monthrange_and_monthcalendar():
	int weekday = 0
	int days = 0
	assert_equal(1, calendar_monthrange(2024, 2, &weekday, &days))
	assert_equal(3, weekday)
	assert_equal(29, days)
	assert_equal(0, calendar_monthrange(2024, 13, &weekday, &days))

	list[list[int]] weeks = calendar_monthcalendar(2024, 2)
	assert_equal(5, weeks.length)
	assert_equal(0, weeks[0][0])
	assert_equal(1, weeks[0][3])
	assert_equal(29, weeks[4][3])
	assert_equal(0, weeks[4][4])


void test_ordinals_round_trip():
	date first = date_from_ordinal(1)
	assert_date(first, 1, 1, 1)
	assert_equal(1, date_to_ordinal(first))

	date epoch = date_new(1970, 1, 1)
	assert_equal(719163, date_to_ordinal(epoch))
	assert_date(date_from_ordinal(719163), 1970, 1, 1)
	assert_date(date_from_ordinal(738945), 2024, 2, 29)


void test_timestamp_to_datetime_known_values():
	assert_datetime(datetime_from_unix_utc(0), 1970, 1, 1, 0, 0, 0, 0)
	assert_datetime(datetime_from_unix_utc(-1), 1969, 12, 31, 23, 59, 59, 0)
	assert_datetime(datetime_from_unix_utc(-86400), 1969, 12, 31, 0, 0, 0, 0)
	assert_datetime(datetime_from_unix_utc(951782400), 2000, 2, 29, 0, 0, 0, 0)
	assert_datetime(datetime_from_unix_utc(1709251199), 2024, 2, 29, 23, 59, 59, 0)
	assert_datetime(datetime_from_unix_utc(2147483647), 2038, 1, 19, 3, 14, 7, 0)


void test_timestamp_round_trips():
	assert_round_trip(0)
	assert_round_trip(-1)
	assert_round_trip(-86400)
	assert_round_trip(946684800)
	assert_round_trip(951782400)
	assert_round_trip(1709251199)
	assert_round_trip(2147483647)


void test_datetime_to_unix_rejects_out_of_range():
	datetime too_late = datetime_from_unix_utc(2147483647)
	too_late.t.second = too_late.t.second + 1
	int timestamp = 0
	assert_equal(0, datetime_to_unix_utc(too_late, &timestamp))

	datetime has_microseconds = datetime_from_unix_seconds_and_microseconds(0, 1)
	assert_equal(0, datetime_to_unix_utc(has_microseconds, &timestamp))


void test_datetime_to_unix_with_offset():
	datetime dt
	assert_equal(1, datetime_parse_iso(c"1970-01-01T01:00:00+01:00", &dt))
	int timestamp = 99
	assert_equal(1, datetime_to_unix_utc(dt, &timestamp))
	assert_equal(0, timestamp)

	assert_equal(1, datetime_parse_iso(c"1969-12-31T19:00:00-05:00", &dt))
	assert_equal(1, datetime_to_unix_utc(dt, &timestamp))
	assert_equal(0, timestamp)


void test_datetime_add_and_compare():
	datetime dt = datetime_from_unix_seconds_and_microseconds(1709251199, 999999)
	timedelta one_microsecond = timedelta_new(0, 0, 1)
	datetime advanced = datetime_add(dt, one_microsecond)
	assert_datetime(advanced, 2024, 3, 1, 0, 0, 0, 0)
	assert_equal(-1, datetime_compare(dt, advanced))
	assert_equal(1, datetime_compare(advanced, dt))
	assert_equal(0, datetime_compare(dt, dt))


void test_date_iso_format_parse():
	date leap = date_new(2024, 2, 29)
	char* formatted = date_isoformat(leap)
	assert_strings_equal(c"2024-02-29", formatted)
	free(formatted)

	date parsed
	assert_equal(1, date_parse_iso(c"2024-02-29", &parsed))
	assert_date(parsed, 2024, 2, 29)
	assert_equal(0, date_parse_iso(c"2023-02-29", &parsed))
	assert_equal(0, date_parse_iso(c"2024-2-29", &parsed))

	date too_large = date_new(10000, 1, 1)
	formatted = date_isoformat(too_large)
	assert_strings_equal(c"", formatted)
	free(formatted)


void test_datetime_iso_format_parse():
	datetime dt = datetime_from_unix_utc(1709251199)
	char* formatted = datetime_isoformat(dt)
	assert_strings_equal(c"2024-02-29T23:59:59Z", formatted)
	free(formatted)

	dt.t.microsecond = 42
	dt.tz_offset_seconds = -18000
	formatted = datetime_isoformat(dt)
	assert_strings_equal(c"2024-02-29T23:59:59.000042-05:00", formatted)
	free(formatted)

	datetime parsed
	assert_equal(1, datetime_parse_iso(c"2024-02-29T23:59:59Z", &parsed))
	assert_datetime(parsed, 2024, 2, 29, 23, 59, 59, 0)
	assert_equal(1, parsed.has_tz)
	assert_equal(0, parsed.tz_offset_seconds)

	assert_equal(1, datetime_parse_iso(c"2024-02-29T23:59:59.123+05:30", &parsed))
	assert_datetime(parsed, 2024, 2, 29, 23, 59, 59, 123000)
	assert_equal(1, parsed.has_tz)
	assert_equal(19800, parsed.tz_offset_seconds)


void test_datetime_iso_parse_rejects_invalid_inputs():
	datetime parsed
	assert_equal(0, datetime_parse_iso(c"2023-02-29T00:00:00", &parsed))
	assert_equal(0, datetime_parse_iso(c"2024-02-29 00:00:00", &parsed))
	assert_equal(0, datetime_parse_iso(c"2024-02-29T24:00:00", &parsed))
	assert_equal(0, datetime_parse_iso(c"2024-02-29T23:59:60", &parsed))
	assert_equal(0, datetime_parse_iso(c"2024-02-29T23:59:59.1234567", &parsed))
	assert_equal(0, datetime_parse_iso(c"2024-02-29T23:59:59+24:00", &parsed))
