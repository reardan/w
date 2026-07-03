import lib.lib


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
	return linux_time(0)


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
	if ((month == 4) | (month == 6) | (month == 9) | (month == 11)):
		return 30
	return 31


# Converts non-negative Unix timestamps to UTC. weekday is 0=Sunday..6=Saturday;
# year_day is 1-based.
void time_utc_from_unix(int timestamp, date_time* out):
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
