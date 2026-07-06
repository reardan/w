import lib.lib
import libs.standard.time.datetime


int time_format_is_digit(int c):
	return (c >= '0') & (c <= '9')


void time_format_write_2_digits(char* out, int value):
	out[0] = (value / 10) + '0'
	out[1] = (value % 10) + '0'


void time_format_write_4_digits(char* out, int value):
	out[0] = (value / 1000) % 10 + '0'
	out[1] = (value / 100) % 10 + '0'
	out[2] = (value / 10) % 10 + '0'
	out[3] = value % 10 + '0'


void time_format_write_6_digits(char* out, int value):
	out[0] = (value / 100000) % 10 + '0'
	out[1] = (value / 10000) % 10 + '0'
	out[2] = (value / 1000) % 10 + '0'
	out[3] = (value / 100) % 10 + '0'
	out[4] = (value / 10) % 10 + '0'
	out[5] = value % 10 + '0'


int time_format_parse_2(char* text, int pos):
	if ((time_format_is_digit(text[pos]) == 0) | (time_format_is_digit(text[pos + 1]) == 0)):
		return -1
	return (text[pos] - '0') * 10 + text[pos + 1] - '0'


int time_format_parse_4(char* text, int pos):
	int a = time_format_parse_2(text, pos)
	int b = time_format_parse_2(text, pos + 2)
	if ((a < 0) | (b < 0)):
		return -1
	return a * 100 + b


char* date_isoformat(date d):
	if ((date_valid(d.year, d.month, d.day) == 0) | (d.year > 9999)):
		return strclone(c"")
	char* result = malloc(11)
	time_format_write_4_digits(result, d.year)
	result[4] = '-'
	time_format_write_2_digits(result + 5, d.month)
	result[7] = '-'
	time_format_write_2_digits(result + 8, d.day)
	result[10] = 0
	return result


int date_parse_iso(char* text, date* out):
	if (strlen(text) != 10):
		return 0
	if ((text[4] != '-') | (text[7] != '-')):
		return 0
	int year = time_format_parse_4(text, 0)
	int month = time_format_parse_2(text, 5)
	int day = time_format_parse_2(text, 8)
	if (date_valid(year, month, day) == 0):
		return 0
	out.year = year
	out.month = month
	out.day = day
	return 1


char* datetime_isoformat(datetime dt):
	if ((date_valid(dt.d.year, dt.d.month, dt.d.day) == 0) | (dt.d.year > 9999) | (time_of_day_valid(dt.t) == 0)):
		return strclone(c"")
	char* result = malloc(33)
	time_format_write_4_digits(result, dt.d.year)
	result[4] = '-'
	time_format_write_2_digits(result + 5, dt.d.month)
	result[7] = '-'
	time_format_write_2_digits(result + 8, dt.d.day)
	result[10] = 'T'
	time_format_write_2_digits(result + 11, dt.t.hour)
	result[13] = ':'
	time_format_write_2_digits(result + 14, dt.t.minute)
	result[16] = ':'
	time_format_write_2_digits(result + 17, dt.t.second)
	int pos = 19
	if (dt.t.microsecond != 0):
		result[pos] = '.'
		pos = pos + 1
		time_format_write_6_digits(result + pos, dt.t.microsecond)
		pos = pos + 6
	if (dt.has_tz):
		if (dt.tz_offset_seconds == 0):
			result[pos] = 'Z'
			pos = pos + 1
		else:
			int offset = dt.tz_offset_seconds
			if (offset < 0):
				result[pos] = '-'
				offset = 0 - offset
			else:
				result[pos] = '+'
			pos = pos + 1
			time_format_write_2_digits(result + pos, offset / 3600)
			pos = pos + 2
			result[pos] = ':'
			pos = pos + 1
			time_format_write_2_digits(result + pos, (offset % 3600) / 60)
			pos = pos + 2
	result[pos] = 0
	return result


int datetime_parse_iso_timezone(char* text, int pos, datetime* out):
	int length = strlen(text)
	if (pos == length):
		out.has_tz = 0
		out.tz_offset_seconds = 0
		return 1
	if ((pos + 1 == length) & (text[pos] == 'Z')):
		out.has_tz = 1
		out.tz_offset_seconds = 0
		return 1
	if ((text[pos] != '+') & (text[pos] != '-')):
		return 0
	if (pos + 6 != length):
		return 0
	if (text[pos + 3] != ':'):
		return 0
	int hour = time_format_parse_2(text, pos + 1)
	int minute = time_format_parse_2(text, pos + 4)
	if ((hour < 0) | (hour > 23) | (minute < 0) | (minute > 59)):
		return 0
	int offset = hour * 3600 + minute * 60
	if (text[pos] == '-'):
		offset = 0 - offset
	out.has_tz = 1
	out.tz_offset_seconds = offset
	return 1


int datetime_parse_iso(char* text, datetime* out):
	if (strlen(text) < 19):
		return 0
	if ((text[4] != '-') | (text[7] != '-') | (text[10] != 'T') | (text[13] != ':') | (text[16] != ':')):
		return 0
	int year = time_format_parse_4(text, 0)
	int month = time_format_parse_2(text, 5)
	int day = time_format_parse_2(text, 8)
	int hour = time_format_parse_2(text, 11)
	int minute = time_format_parse_2(text, 14)
	int second = time_format_parse_2(text, 17)
	if (date_valid(year, month, day) == 0):
		return 0
	time_of_day t = time_of_day_new(hour, minute, second, 0)
	if (time_of_day_valid(t) == 0):
		return 0

	int pos = 19
	if (text[pos] == '.'):
		pos = pos + 1
		int digits = 0
		int microsecond = 0
		while ((time_format_is_digit(text[pos]) != 0) & (digits < 6)):
			microsecond = microsecond * 10 + text[pos] - '0'
			pos = pos + 1
			digits = digits + 1
		if (digits == 0):
			return 0
		if (time_format_is_digit(text[pos]) != 0):
			return 0
		while (digits < 6):
			microsecond = microsecond * 10
			digits = digits + 1
		t.microsecond = microsecond

	out.d.year = year
	out.d.month = month
	out.d.day = day
	out.t.hour = t.hour
	out.t.minute = t.minute
	out.t.second = t.second
	out.t.microsecond = t.microsecond
	if (datetime_parse_iso_timezone(text, pos, out) == 0):
		return 0
	return 1
