# UTC date/time helpers.
#
# On the 32-bit x86 target, time_now() uses Linux time(2), whose i386 time_t is
# 32 bits. It will report negative values after 2038-01-19 03:14:07 UTC. The
# future fix is to use clock_gettime64 (syscall 403) on x86.
import lib.lib
import lib.assert


struct date_time:
	int year
	int month
	int day
	int hour
	int minute
	int second
	int weekday
	int year_day


# Seconds since 1970-01-01 00:00:00 UTC, as reported by Linux time(2).
int time_now():
	int* out = 0
	return linux_time(out)


# Matches the kernel timespec on both targets: two words (long seconds,
# long nanoseconds).
struct timespec:
	int seconds
	int nanoseconds


int clock_monotonic():
	return 1


# Milliseconds from the monotonic clock (time since boot). The product
# wraps a 32-bit int after ~24.8 days on x86, so only use it for relative
# measurements such as timeouts.
int time_monotonic_ms():
	timespec ts
	int err = sys_clock_gettime(clock_monotonic(), cast(int, &ts))
	if (err < 0):
		return err
	return ts.seconds * 1000 + ts.nanoseconds / 1000000


# Sleeps for at least ms milliseconds.
void sleep_ms(int ms):
	timespec ts
	ts.seconds = ms / 1000
	ts.nanoseconds = (ms % 1000) * 1000000
	sys_nanosleep(cast(int, &ts), 0)


int time_is_leap_year(int year):
	if ((year % 4) != 0):
		return 0
	if ((year % 100) != 0):
		return 1
	if ((year % 400) == 0):
		return 1
	return 0


int time_days_in_year(int year):
	if (time_is_leap_year(year)):
		return 366
	return 365


int time_days_in_month(int year, int month):
	if (month == 2):
		if (time_is_leap_year(year)):
			return 29
		return 28
	if ((month == 4) || (month == 6) || (month == 9) || (month == 11)):
		return 30
	return 31


# English month name for 1..12 ("January"); the first three letters are
# the RFC 5322 / HTTP-date abbreviation.
char* time_month_name(int month):
	switch (month):
		case 1: return c"January"
		case 2: return c"February"
		case 3: return c"March"
		case 4: return c"April"
		case 5: return c"May"
		case 6: return c"June"
		case 7: return c"July"
		case 8: return c"August"
		case 9: return c"September"
		case 10: return c"October"
		case 11: return c"November"
		default: return c"December"


# English weekday name, 0 = Sunday through 6 = Saturday (date_time.weekday
# numbering); the first three letters are the RFC 5322 abbreviation.
char* time_weekday_name(int weekday):
	switch (weekday):
		case 0: return c"Sunday"
		case 1: return c"Monday"
		case 2: return c"Tuesday"
		case 3: return c"Wednesday"
		case 4: return c"Thursday"
		case 5: return c"Friday"
		default: return c"Saturday"


# Month 1..12 whose English name starts with the three letters at s
# (any case), or -1.
int time_month_from_abbrev(char* s):
	for m in range(1, 12 + 1):
		char* name = time_month_name(m)
		int i = 0
		while ((i < 3) && (((s[i] | 32) & 255) == (name[i] | 32))):
			i = i + 1
		if (i == 3):
			return m
	return 0 - 1


# Converts non-negative Unix timestamps to UTC; negative inputs assert loudly.
# weekday is 0=Sunday..6=Saturday; year_day is 1-based.
void time_utc_from_unix(int timestamp, date_time* out):
	asserts(c"time_utc_from_unix requires a non-negative Unix timestamp", timestamp >= 0)
	int days = timestamp / 86400
	int remaining = timestamp % 86400

	out.hour = remaining / 3600
	remaining = remaining % 3600
	out.minute = remaining / 60
	out.second = remaining % 60
	out.weekday = (days + 4) % 7

	int year = 1970
	int days_in_year = time_days_in_year(year)
	while (days >= days_in_year):
		days = days - days_in_year
		year = year + 1
		days_in_year = time_days_in_year(year)

	out.year = year
	out.year_day = days + 1

	int month = 1
	int days_in_month = time_days_in_month(year, month)
	while (days >= days_in_month):
		days = days - days_in_month
		month = month + 1
		days_in_month = time_days_in_month(year, month)

	out.month = month
	out.day = days + 1


date_time* time_utc_new(int timestamp):
	date_time* result = new date_time()
	time_utc_from_unix(timestamp, result)
	return result


void time_write_2_digits(char* out, int value):
	out[0] = (value / 10) + '0'
	out[1] = (value % 10) + '0'


# Truncates years >= 10000 to their low four decimal digits.
void time_write_4_digits(char* out, int value):
	out[0] = (value / 1000) % 10 + '0'
	out[1] = (value / 100) % 10 + '0'
	out[2] = (value / 10) % 10 + '0'
	out[3] = value % 10 + '0'


# Returns a malloc'd "YYYY-MM-DD HH:MM:SS" UTC string.
char* time_format_utc(date_time* dt):
	char* result = malloc(20)
	time_write_4_digits(result, dt.year)
	result[4] = '-'
	time_write_2_digits(result + 5, dt.month)
	result[7] = '-'
	time_write_2_digits(result + 8, dt.day)
	result[10] = ' '
	time_write_2_digits(result + 11, dt.hour)
	result[13] = ':'
	time_write_2_digits(result + 14, dt.minute)
	result[16] = ':'
	time_write_2_digits(result + 17, dt.second)
	result[19] = 0
	return result


char* time_format_unix_utc(int timestamp):
	date_time* dt = time_utc_new(timestamp)
	char* result = time_format_utc(dt)
	free(dt)
	return result


# Civil-date math, the inverse of time_utc_from_unix
# (docs/projects/ui_widgets.md §4.7). Howard Hinnant's days_from_civil:
# shifting the year to start on March 1st puts the leap day last, so a
# day-of-year is a closed formula and a 400-year era is a fixed 146097
# days. Division here truncates toward zero, so the era is floored by
# hand for years before 0; everything else stays non-negative.
#
# Proleptic Gregorian. month is 1..12; day is not range-checked, and
# out-of-range days count on linearly (day 0 is the last day of the
# previous month, day 32 of January is February 1st).


# Days since 1970-01-01 (negative before it) of year-month-day.
int time_days_from_civil(int year, int month, int day):
	int y = year
	if (month <= 2):
		y = y - 1
	int era = y / 400
	if (y < 0):
		era = (y - 399) / 400
	int yoe = y - era * 400
	int mp = month - 3
	if (month <= 2):
		mp = month + 9
	int doy = (153 * mp + 2) / 5 + day - 1
	int doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468


# Weekday of a day count from time_days_from_civil: 0 = Sunday through
# 6 = Saturday, the same numbering as date_time.weekday. 1970-01-01 was
# a Thursday; the remainder is floored so days before 1970 work too.
int time_weekday_from_days(int days):
	return ((days % 7) + 11) % 7


# Weekday of year-month-day: 0 = Sunday through 6 = Saturday.
int time_weekday_from_civil(int year, int month, int day):
	return time_weekday_from_days(time_days_from_civil(year, month, day))


# Unix timestamp of a UTC date_time (reads year..second; weekday and
# year_day are ignored). Negative before 1970. On the 32-bit target the
# result overflows past 2038-01-19 03:14:07, like time_now.
int time_unix_from_utc(date_time* dt):
	int days = time_days_from_civil(dt.year, dt.month, dt.day)
	return days * 86400 + dt.hour * 3600 + dt.minute * 60 + dt.second
