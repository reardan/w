import libs.standard.time.calendar


struct date:
	int year
	int month
	int day


struct time_of_day:
	int hour
	int minute
	int second
	int microsecond


struct datetime:
	date d
	time_of_day t
	int tz_offset_seconds
	int has_tz


struct timedelta:
	int days
	int seconds
	int microseconds


int datetime_epoch_ordinal():
	return 719163


int datetime_seconds_per_day():
	return 86400


int date_valid(int year, int month, int day):
	return calendar_date_valid(year, month, day)


int time_of_day_valid(time_of_day t):
	if ((t.hour < 0) | (t.hour > 23)):
		return 0
	if ((t.minute < 0) | (t.minute > 59)):
		return 0
	if ((t.second < 0) | (t.second > 59)):
		return 0
	if ((t.microsecond < 0) | (t.microsecond > 999999)):
		return 0
	return 1


date date_new(int year, int month, int day):
	date d
	d.year = year
	d.month = month
	d.day = day
	return d


time_of_day time_of_day_new(int hour, int minute, int second, int microsecond):
	time_of_day t
	t.hour = hour
	t.minute = minute
	t.second = second
	t.microsecond = microsecond
	return t


datetime datetime_new(date d, time_of_day t):
	datetime dt
	dt.d = d
	dt.t = t
	dt.tz_offset_seconds = 0
	dt.has_tz = 0
	return dt


datetime datetime_new_utc(date d, time_of_day t):
	datetime dt = datetime_new(d, t)
	dt.has_tz = 1
	dt.tz_offset_seconds = 0
	return dt


timedelta timedelta_new(int days, int seconds, int microseconds):
	timedelta delta
	delta.days = days
	delta.seconds = seconds
	delta.microseconds = microseconds
	return delta


int date_to_ordinal(date d):
	return calendar_ordinal(d.year, d.month, d.day)


date date_from_ordinal(int ordinal):
	date d
	d.year = 0
	d.month = 0
	d.day = 0
	if (ordinal < 1):
		return d

	int year = 1
	int days = ordinal
	int year_days = 365
	while (1):
		year_days = 365 + calendar_isleap(year)
		if (days <= year_days):
			break
		days = days - year_days
		year = year + 1

	int month = 1
	int month_days = calendar_days_in_month(year, month)
	while (days > month_days):
		days = days - month_days
		month = month + 1
		month_days = calendar_days_in_month(year, month)

	d.year = year
	d.month = month
	d.day = days
	return d


int datetime_floor_div(int n, int d):
	int q = n / d
	int r = n % d
	if ((r != 0) & (n < 0)):
		return q - 1
	return q


int datetime_floor_mod(int n, int d):
	int r = n % d
	if (r < 0):
		return r + d
	return r


datetime datetime_from_unix_utc(int timestamp):
	int days = datetime_floor_div(timestamp, datetime_seconds_per_day())
	int seconds = datetime_floor_mod(timestamp, datetime_seconds_per_day())
	date d = date_from_ordinal(datetime_epoch_ordinal() + days)
	time_of_day t
	t.hour = seconds / 3600
	seconds = seconds % 3600
	t.minute = seconds / 60
	t.second = seconds % 60
	t.microsecond = 0
	return datetime_new_utc(d, t)


int datetime_seconds_of_day(time_of_day t):
	return t.hour * 3600 + t.minute * 60 + t.second


int datetime_normalized_unix_days(datetime dt, int* days, int* seconds):
	if (date_valid(dt.d.year, dt.d.month, dt.d.day) == 0):
		return 0
	if (time_of_day_valid(dt.t) == 0):
		return 0

	int offset = 0
	if (dt.has_tz):
		offset = dt.tz_offset_seconds
		if ((offset <= -datetime_seconds_per_day()) | (offset >= datetime_seconds_per_day())):
			return 0

	int raw_seconds = datetime_seconds_of_day(dt.t) - offset
	int day_adjust = datetime_floor_div(raw_seconds, datetime_seconds_per_day())
	days[0] = date_to_ordinal(dt.d) - datetime_epoch_ordinal() + day_adjust
	seconds[0] = datetime_floor_mod(raw_seconds, datetime_seconds_per_day())
	return 1


int datetime_to_unix_utc(datetime dt, int* out_timestamp):
	if (dt.t.microsecond != 0):
		return 0
	int days = 0
	int seconds = 0
	if (datetime_normalized_unix_days(dt, &days, &seconds) == 0):
		return 0
	if ((days < -24855) | (days > 24855)):
		return 0
	if ((days == 24855) & (seconds > 11647)):
		return 0
	out_timestamp[0] = days * datetime_seconds_per_day() + seconds
	return 1


datetime datetime_from_unix_seconds_and_microseconds(int seconds, int microseconds):
	datetime dt = datetime_from_unix_utc(seconds)
	dt.t.microsecond = microseconds
	return dt


datetime datetime_add(datetime dt, timedelta delta):
	int days = 0
	int seconds = 0
	if (datetime_normalized_unix_days(dt, &days, &seconds) == 0):
		return dt
	int microseconds = dt.t.microsecond + delta.microseconds
	while (microseconds >= 1000000):
		microseconds = microseconds - 1000000
		seconds = seconds + 1
	while (microseconds < 0):
		microseconds = microseconds + 1000000
		seconds = seconds - 1

	int total_seconds = seconds + delta.seconds
	int day_adjust = datetime_floor_div(total_seconds, datetime_seconds_per_day())
	days = days + delta.days + day_adjust
	seconds = datetime_floor_mod(total_seconds, datetime_seconds_per_day())

	date d = date_from_ordinal(datetime_epoch_ordinal() + days)
	time_of_day t
	t.hour = seconds / 3600
	seconds = seconds % 3600
	t.minute = seconds / 60
	t.second = seconds % 60
	t.microsecond = microseconds
	datetime result = datetime_new(d, t)
	result.has_tz = dt.has_tz
	result.tz_offset_seconds = dt.tz_offset_seconds
	return result


int datetime_compare(datetime a, datetime b):
	int a_days = 0
	int a_seconds = 0
	int b_days = 0
	int b_seconds = 0
	if (datetime_normalized_unix_days(a, &a_days, &a_seconds) == 0):
		return 0
	if (datetime_normalized_unix_days(b, &b_days, &b_seconds) == 0):
		return 0
	if (a_days < b_days):
		return -1
	if (a_days > b_days):
		return 1
	if (a_seconds < b_seconds):
		return -1
	if (a_seconds > b_seconds):
		return 1
	if (a.t.microsecond < b.t.microsecond):
		return -1
	if (a.t.microsecond > b.t.microsecond):
		return 1
	return 0
