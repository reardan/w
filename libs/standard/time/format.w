/*
Datetime formatting and parsing (docs/projects/stdlib_python_parity.md
P1.6, area plan libs/standard/plans/04_time_calendar.md phase 3) over
libs/standard/time/datetime.w's value types. C locale only: English
day and month names, AM/PM.

  strftime / strptime     datetime_strftime, date_strftime, datetime_strptime
  ISO 8601                datetime_isoformat[_ex], date_isoformat,
                          time_of_day_isoformat, and the matching
                          *_fromisoformat parsers (Python 3.13 rules)
  RFC 3339                datetime_format_rfc3339, datetime_parse_rfc3339
  RFC 2822 / 5322         datetime_format_rfc2822, datetime_parse_rfc2822
                          (email.utils.format_datetime / parsedate_to_datetime)
  RFC 7231 HTTP-date      datetime_format_http, datetime_parse_http

Formatters return a malloc'd string the caller frees. Parsers return 1
(or 2, see time_of_day_fromisoformat) on success and write *out; on
failure (Python's ValueError) they return 0 and leave *out untouched.

strftime directives (Python's documented, portable set):
  %a %A %w %u   weekday: Mon / Monday / Sunday=0..6 / Monday=1..7
  %d %m %y %Y   day, month, 2-digit year, 4-digit year (zero-padded to
                4 digits for years < 1000, as on macOS/BSD; glibc
                prints "1" for year 1)
  %b %B         month: Jan / January
  %H %I %p      24-hour, 12-hour, AM/PM
  %M %S %f      minute, second, microsecond (6 digits)
  %j %U %W      day of year, Sunday- and Monday-based week of year
  %G %V         ISO 8601 year and week
  %z %:z %Z     +HHMM[SS], +HH:MM[:SS], "UTC" / "UTC+HH:MM"; all empty
                for a naive datetime
  %c %x %X      C locale: "%a %b %e %H:%M:%S %Y", "%m/%d/%y", "%H:%M:%S"
  %%            a literal %
Any other directive is copied through unchanged (glibc's behavior).
Not supported: %e %k %l %T %R %r %P %C %D and flag/width forms such as
%-d, which are platform extensions Python does not document.

strptime follows Python's _strptime: the format becomes a regex-like
pattern matched case-insensitively from the start of the text with
backtracking; a run of whitespace in the format matches one or more
whitespace characters; the whole text must be consumed. Numeric fields
accept the same digit counts Python does (%d takes "5", "05" or " 5").
%Z accepts UTC or GMT and is otherwise ignored, %z accepts Z, +HH:MM,
+HHMM, +HH:MM:SS and +HHMMSS (a non-zero fractional-second offset is
rejected because datetime offsets are whole seconds). Missing fields
default to 1900-01-01 00:00:00. A directive used twice (Python's "redefinition
of group name") or an unknown directive fails.

Precision: datetime carries nanoseconds. %f and strptime stop at
microseconds, like Python. The ISO parsers keep up to 9 fraction digits
(Python truncates to 6) and DATETIME_TIMESPEC_AUTO prints 9 digits when
the value has sub-microsecond nanoseconds (Python never has them), so
every datetime round-trips through isoformat/fromisoformat.
*/
import lib.lib
import lib.assert
import lib.time
import structures.string
import libs.standard.time.datetime


const int DATETIME_TIMESPEC_AUTO = 0
const int DATETIME_TIMESPEC_HOURS = 1
const int DATETIME_TIMESPEC_MINUTES = 2
const int DATETIME_TIMESPEC_SECONDS = 3
const int DATETIME_TIMESPEC_MILLISECONDS = 4
const int DATETIME_TIMESPEC_MICROSECONDS = 5
const int DATETIME_TIMESPEC_NANOSECONDS = 6


# ---- shared helpers --------------------------------------------------------------

char* dtfmt_finish(string_builder* sb):
	char* result = sb.data
	free(cast(char*, sb))
	return result


# value (>= 0) in at least width decimal digits, zero-padded.
void dtfmt_pad(string_builder* sb, int value, int width):
	char[24] digits
	int n = 0
	while ((value > 0) || (n == 0)):
		digits[n] = '0' + value % 10
		value = value / 10
		n = n + 1
	while (width > n):
		string_append_char(sb, '0')
		width = width - 1
	while (n > 0):
		n = n - 1
		string_append_char(sb, digits[n])


int dtfmt_lower(int c):
	if ((c >= 'A') && (c <= 'Z')): return c + 32
	return c


int dtfmt_is_digit(int c):
	return (c >= '0') && (c <= '9')


# Python's str.split() / regex \s whitespace, ASCII part.
int dtfmt_is_space(int c):
	if ((c == ' ') || ((c >= 9) && (c <= 13))): return 1
	return (c >= 28) && (c <= 31)


# Weekday names, Monday = 0 (datetime.w numbering).
char* dtfmt_weekday_name(int weekday):
	return time_weekday_name((weekday + 1) % 7)


# Does text[pos..] start with the first n bytes of name, ignoring case?
int dtfmt_match_name(char* text, int pos, char* name, int n):
	int i = 0
	while (i < n):
		if (dtfmt_lower(text[pos + i] & 255) != dtfmt_lower(name[i] & 255)): return 0
		i = i + 1
	return 1


# +HH<sep>MM[<sep>SS] for an offset in seconds (Python's _format_offset).
void dtfmt_append_offset(string_builder* sb, int offset, char* sep):
	if (offset < 0):
		string_append_char(sb, '-')
		offset = 0 - offset
	else:
		string_append_char(sb, '+')
	dtfmt_pad(sb, offset / 3600, 2)
	string_append(sb, sep)
	dtfmt_pad(sb, (offset / 60) % 60, 2)
	if (offset % 60 != 0):
		string_append(sb, sep)
		dtfmt_pad(sb, offset % 60, 2)


# ---- ISO 8601 formatting ---------------------------------------------------------

void dtfmt_append_date(string_builder* sb, date d):
	dtfmt_pad(sb, d.year, 4)
	string_append_char(sb, '-')
	dtfmt_pad(sb, d.month, 2)
	string_append_char(sb, '-')
	dtfmt_pad(sb, d.day, 2)


void dtfmt_append_time(string_builder* sb, time_of_day t, int spec):
	asserts(c"isoformat: unknown timespec", (spec >= DATETIME_TIMESPEC_AUTO) && (spec <= DATETIME_TIMESPEC_NANOSECONDS))
	if (spec == DATETIME_TIMESPEC_AUTO):
		if (t.nanosecond == 0): spec = DATETIME_TIMESPEC_SECONDS
		else if (t.nanosecond % 1000 == 0): spec = DATETIME_TIMESPEC_MICROSECONDS
		else: spec = DATETIME_TIMESPEC_NANOSECONDS
	dtfmt_pad(sb, t.hour, 2)
	if (spec == DATETIME_TIMESPEC_HOURS): return
	string_append_char(sb, ':')
	dtfmt_pad(sb, t.minute, 2)
	if (spec == DATETIME_TIMESPEC_MINUTES): return
	string_append_char(sb, ':')
	dtfmt_pad(sb, t.second, 2)
	if (spec == DATETIME_TIMESPEC_MILLISECONDS):
		string_append_char(sb, '.')
		dtfmt_pad(sb, t.nanosecond / 1000000, 3)
	else if (spec == DATETIME_TIMESPEC_MICROSECONDS):
		string_append_char(sb, '.')
		dtfmt_pad(sb, t.nanosecond / 1000, 6)
	else if (spec == DATETIME_TIMESPEC_NANOSECONDS):
		string_append_char(sb, '.')
		dtfmt_pad(sb, t.nanosecond, 9)


# "YYYY-MM-DD" (Python's date.isoformat()).
char* date_isoformat(date d):
	string_builder* sb = string_new()
	dtfmt_append_date(sb, d)
	return dtfmt_finish(sb)


# "HH:MM:SS[.ffffff]" (Python's time.isoformat(spec)).
char* time_of_day_isoformat(time_of_day t, int spec):
	string_builder* sb = string_new()
	dtfmt_append_time(sb, t, spec)
	return dtfmt_finish(sb)


# Python's datetime.isoformat(sep, spec): "YYYY-MM-DD<sep>HH:MM:SS",
# then ".fff", ".ffffff" or ".fffffffff" per timespec, then "+HH:MM[:SS]"
# when aware. sep is a single ASCII character.
char* datetime_isoformat_ex(datetime dt, int sep, int spec):
	string_builder* sb = string_new()
	dtfmt_append_date(sb, dt.d)
	string_append_char(sb, sep)
	dtfmt_append_time(sb, dt.t, spec)
	if (dt.has_offset): dtfmt_append_offset(sb, dt.utc_offset, c":")
	return dtfmt_finish(sb)


# Python's datetime.isoformat(): sep "T", spec auto.
char* datetime_isoformat(datetime dt):
	return datetime_isoformat_ex(dt, 'T', DATETIME_TIMESPEC_AUTO)


# ---- strftime ------------------------------------------------------------------

void dtfmt_append_tzname(string_builder* sb, datetime dt):
	if (!dt.has_offset): return
	string_append(sb, c"UTC")
	if (dt.utc_offset != 0): dtfmt_append_offset(sb, dt.utc_offset, c":")


void dtfmt_strftime_into(string_builder* sb, datetime dt, char* fmt):
	int weekday = date_weekday(dt.d)
	int yday0 = date_day_of_year(dt.d) - 1
	int i = 0
	while (fmt[i] != 0):
		int c = fmt[i] & 255
		if ((c != '%') || (fmt[i + 1] == 0)):
			string_append_char(sb, c)
			i = i + 1
			continue
		int k = fmt[i + 1] & 255
		i = i + 2
		if (k == 'a'): string_append_bytes(sb, dtfmt_weekday_name(weekday), 3)
		else if (k == 'A'): string_append(sb, dtfmt_weekday_name(weekday))
		else if (k == 'w'): dtfmt_pad(sb, (weekday + 1) % 7, 1)
		else if (k == 'u'): dtfmt_pad(sb, weekday + 1, 1)
		else if (k == 'd'): dtfmt_pad(sb, dt.d.day, 2)
		else if (k == 'b'): string_append_bytes(sb, time_month_name(dt.d.month), 3)
		else if (k == 'B'): string_append(sb, time_month_name(dt.d.month))
		else if (k == 'm'): dtfmt_pad(sb, dt.d.month, 2)
		else if (k == 'y'): dtfmt_pad(sb, dt.d.year % 100, 2)
		else if (k == 'Y'): dtfmt_pad(sb, dt.d.year, 4)
		else if (k == 'H'): dtfmt_pad(sb, dt.t.hour, 2)
		else if (k == 'I'):
			int h12 = dt.t.hour % 12
			if (h12 == 0): h12 = 12
			dtfmt_pad(sb, h12, 2)
		else if (k == 'p'):
			if (dt.t.hour < 12): string_append(sb, c"AM")
			else: string_append(sb, c"PM")
		else if (k == 'M'): dtfmt_pad(sb, dt.t.minute, 2)
		else if (k == 'S'): dtfmt_pad(sb, dt.t.second, 2)
		else if (k == 'f'): dtfmt_pad(sb, dt.t.nanosecond / 1000, 6)
		else if (k == 'j'): dtfmt_pad(sb, yday0 + 1, 3)
		else if (k == 'U'): dtfmt_pad(sb, (yday0 + 7 - (weekday + 1) % 7) / 7, 2)
		else if (k == 'W'): dtfmt_pad(sb, (yday0 + 7 - weekday) / 7, 2)
		else if (k == 'G'): dtfmt_pad(sb, date_isocalendar(dt.d).year, 4)
		else if (k == 'V'): dtfmt_pad(sb, date_isocalendar(dt.d).week, 2)
		else if (k == 'z'):
			if (dt.has_offset): dtfmt_append_offset(sb, dt.utc_offset, c"")
		else if ((k == ':') && (fmt[i] == 'z')):
			i = i + 1
			if (dt.has_offset): dtfmt_append_offset(sb, dt.utc_offset, c":")
		else if (k == 'Z'): dtfmt_append_tzname(sb, dt)
		else if (k == 'c'):
			dtfmt_strftime_into(sb, dt, c"%a %b ")
			if (dt.d.day < 10): string_append_char(sb, ' ')
			dtfmt_pad(sb, dt.d.day, 1)
			dtfmt_strftime_into(sb, dt, c" %H:%M:%S %Y")
		else if (k == 'x'): dtfmt_strftime_into(sb, dt, c"%m/%d/%y")
		else if (k == 'X'): dtfmt_strftime_into(sb, dt, c"%H:%M:%S")
		else if (k == '%'): string_append_char(sb, '%')
		else:
			string_append_char(sb, '%')
			string_append_char(sb, k)


# Python's datetime.strftime(fmt) in the C locale (directives above).
char* datetime_strftime(datetime dt, char* fmt):
	string_builder* sb = string_new()
	dtfmt_strftime_into(sb, dt, fmt)
	return dtfmt_finish(sb)


# Python's date.strftime(fmt): time fields are zero, %z/%Z empty.
char* date_strftime(date d, char* fmt):
	return datetime_strftime(datetime_combine(d, time_of_day_new(0, 0, 0, 0)), fmt)


# ---- strptime ------------------------------------------------------------------

const int DTP_UNSET = -2147483647
const int DTP_YEAR = 0
const int DTP_ISO_YEAR = 1
const int DTP_MONTH = 2
const int DTP_DAY = 3
const int DTP_HOUR = 4
const int DTP_HOUR_IS_I = 5
const int DTP_AMPM = 6
const int DTP_MINUTE = 7
const int DTP_SECOND = 8
const int DTP_FRACTION = 9
const int DTP_WEEKDAY = 10
const int DTP_JULIAN = 11
const int DTP_WEEK = 12
const int DTP_WEEK_STARTS_MONDAY = 13
const int DTP_ISO_WEEK = 14
const int DTP_GMTOFF = 15
const int DTP_SLOTS = 16


struct dtp_state:
	char* text
	char* fmt
	int[16] slots


# The k-th alternative of a numeric directive's regex, in Python's
# order: ndigits digits whose value is lo..hi, preceded by one space
# when space is set. Returns 0 past the last alternative.
int dtp_numeric_alt(int dir, int k, int* ndigits, int* lo, int* hi, int* space):
	*space = 0
	*lo = 0
	int two_hi = 0
	int two_lo = 0
	int one_lo = 0
	int one_hi = 9
	int has_space = 0
	if (dir == 'f'):
		if (k >= 6): return 0
		*ndigits = 6 - k
		*hi = 999999
		return 1
	if ((dir == 'Y') || (dir == 'G')):
		if (k > 0): return 0
		*ndigits = 4
		*hi = 9999
		return 1
	if ((dir == 'y') || (dir == 'w') || (dir == 'u')):
		if (k > 0): return 0
		*ndigits = 1
		if (dir == 'y'):
			*ndigits = 2
			*hi = 99
		else if (dir == 'w'): *hi = 6
		else:
			*lo = 1
			*hi = 7
		return 1
	if (dir == 'j'):
		if (k > 2): return 0
		*ndigits = 3 - k
		*lo = 1
		if (k == 0): *hi = 366
		else if (k == 1): *hi = 99
		else: *hi = 9
		return 1
	if (dir == 'd'):
		two_lo = 1
		two_hi = 31
		one_lo = 1
		has_space = 1
	else if (dir == 'H'):
		two_hi = 23
		has_space = 1
	else if (dir == 'I'):
		two_lo = 1
		two_hi = 12
		one_lo = 1
		has_space = 1
	else if (dir == 'm'):
		two_lo = 1
		two_hi = 12
		one_lo = 1
	else if (dir == 'M'): two_hi = 59
	else if (dir == 'S'): two_hi = 61
	else if ((dir == 'U') || (dir == 'W')): two_hi = 53
	else if (dir == 'V'):
		two_lo = 1
		two_hi = 53
	else:
		return 0
	if (k == 0):
		*ndigits = 2
		*lo = two_lo
		*hi = two_hi
		return 1
	if ((k == 1) || ((k == 2) && has_space)):
		*ndigits = 1
		*lo = one_lo
		*hi = one_hi
		*space = k == 2
		return 1
	return 0


# Python's lowercase C-locale name tables. Returns the matched length
# (0 when nothing matches) and the index through *index.
int dtp_match_names(char* text, int pos, int dir, int* index):
	if ((dir == 'a') || (dir == 'A')):
		for wd in range(7):
			char* name = dtfmt_weekday_name(wd)
			int n = 3
			if (dir == 'A'): n = strlen(name)
			if (dtfmt_match_name(text, pos, name, n)):
				*index = wd
				return n
		return 0
	if ((dir == 'b') || (dir == 'B')):
		for m in range(1, 13):
			char* name = time_month_name(m)
			int n = 3
			if (dir == 'B'): n = strlen(name)
			if (dtfmt_match_name(text, pos, name, n)):
				*index = m
				return n
		return 0
	if (dir == 'p'):
		if (dtfmt_match_name(text, pos, c"am", 2)):
			*index = 1
			return 2
		if (dtfmt_match_name(text, pos, c"pm", 2)):
			*index = 2
			return 2
		return 0
	# dir == 'Z'
	if (dtfmt_match_name(text, pos, c"utc", 3) || dtfmt_match_name(text, pos, c"gmt", 3)): return 3
	return 0


int dtp_two_digits(char* text, int pos, int max_first):
	int a = text[pos] & 255
	if (!dtfmt_is_digit(a) || !dtfmt_is_digit(text[pos + 1] & 255)): return 0 - 1
	if (a - '0' > max_first): return 0 - 1
	return (a - '0') * 10 + (text[pos + 1] & 255) - '0'


# Candidate lengths of Python's %z regex
# [+-]\d\d:?[0-5]\d(:?[0-5]\d(\.\d{1,6})?)?|(?-i:Z) at pos, longest
# (greedy) first; returns how many were written to lens (up to 8).
int dtp_z_candidates(char* text, int pos, int* lens):
	int c = text[pos] & 255
	if (c == 'Z'):
		lens[0] = 1
		return 1
	if ((c != '+') && (c != '-')): return 0
	if (dtp_two_digits(text, pos + 1, 9) < 0): return 0
	int p = pos + 3
	if (text[p] == ':'): p = p + 1
	if (dtp_two_digits(text, p, 5) < 0): return 0
	p = p + 2
	int base = p
	int count = 0
	if (text[p] == ':'): p = p + 1
	if (dtp_two_digits(text, p, 5) >= 0):
		p = p + 2
		if ((text[p] == '.') && dtfmt_is_digit(text[p + 1] & 255)):
			int digits = 0
			while ((digits < 6) && dtfmt_is_digit(text[p + 1 + digits] & 255)): digits = digits + 1
			while (digits > 0):
				lens[count] = p + 1 + digits - pos
				count = count + 1
				digits = digits - 1
		lens[count] = p - pos
		count = count + 1
	lens[count] = base - pos
	return count + 1


int dtp_parse_digits(char* s, int pos, int n):
	int v = 0
	for i in range(n): v = v * 10 + (s[pos + i] & 255) - '0'
	return v


# Converts a matched %z (text[pos..pos+len)) to seconds in *out; 0 on
# Python's "Inconsistent use of :" or a non-zero fractional second.
int dtp_z_value(char* text, int pos, int len, int* out):
	if (text[pos] == 'Z'):
		*out = 0
		return 1
	int p = pos + 1
	int hours = dtp_parse_digits(text, p, 2)
	p = p + 2
	int colon = text[p] == ':'
	if (colon): p = p + 1
	int minutes = dtp_parse_digits(text, p, 2)
	p = p + 2
	int seconds = 0
	int end = pos + len
	if (p < end):
		if ((text[p] == ':') != colon): return 0
		if (colon): p = p + 1
		seconds = dtp_parse_digits(text, p, 2)
		p = p + 2
		if (p < end):
			p = p + 1
			while (p < end):
				if (text[p] != '0'): return 0
				p = p + 1
	int value = hours * 3600 + minutes * 60 + seconds
	if (text[pos] == '-'): value = 0 - value
	*out = value
	return 1


int dtp_match(dtp_state* st, int fi, int ti);


# Stores value in slot, tries the rest of the pattern, and restores the
# slot when that fails.
int dtp_try(dtp_state* st, int slot, int value, int slot2, int value2, int fi, int ti):
	int old = st.slots[slot]
	int old2 = st.slots[slot2]
	st.slots[slot] = value
	st.slots[slot2] = value2
	if (dtp_match(st, fi, ti)): return 1
	st.slots[slot] = old
	st.slots[slot2] = old2
	return 0


# Applies a numeric directive's value to the capture slots and continues.
int dtp_numeric(dtp_state* st, int dir, int value, int fi, int ti):
	if (dir == 'Y'): return dtp_try(st, DTP_YEAR, value, DTP_YEAR, value, fi, ti)
	if (dir == 'y'):
		if (value <= 68): return dtp_try(st, DTP_YEAR, value + 2000, DTP_YEAR, value + 2000, fi, ti)
		return dtp_try(st, DTP_YEAR, value + 1900, DTP_YEAR, value + 1900, fi, ti)
	if (dir == 'G'): return dtp_try(st, DTP_ISO_YEAR, value, DTP_ISO_YEAR, value, fi, ti)
	if (dir == 'm'): return dtp_try(st, DTP_MONTH, value, DTP_MONTH, value, fi, ti)
	if (dir == 'd'): return dtp_try(st, DTP_DAY, value, DTP_DAY, value, fi, ti)
	if (dir == 'H'): return dtp_try(st, DTP_HOUR, value, DTP_HOUR_IS_I, 0, fi, ti)
	if (dir == 'I'): return dtp_try(st, DTP_HOUR, value, DTP_HOUR_IS_I, 1, fi, ti)
	if (dir == 'M'): return dtp_try(st, DTP_MINUTE, value, DTP_MINUTE, value, fi, ti)
	if (dir == 'S'): return dtp_try(st, DTP_SECOND, value, DTP_SECOND, value, fi, ti)
	if (dir == 'f'): return dtp_try(st, DTP_FRACTION, value, DTP_FRACTION, value, fi, ti)
	if (dir == 'j'): return dtp_try(st, DTP_JULIAN, value, DTP_JULIAN, value, fi, ti)
	if (dir == 'w'): return dtp_try(st, DTP_WEEKDAY, (value + 6) % 7, DTP_WEEKDAY, (value + 6) % 7, fi, ti)
	if (dir == 'u'): return dtp_try(st, DTP_WEEKDAY, value - 1, DTP_WEEKDAY, value - 1, fi, ti)
	if (dir == 'U'): return dtp_try(st, DTP_WEEK, value, DTP_WEEK_STARTS_MONDAY, 0, fi, ti)
	if (dir == 'W'): return dtp_try(st, DTP_WEEK, value, DTP_WEEK_STARTS_MONDAY, 1, fi, ti)
	return dtp_try(st, DTP_ISO_WEEK, value, DTP_ISO_WEEK, value, fi, ti)


# Backtracking match of st.fmt[fi..] against st.text[ti..]; 1 when both
# are consumed exactly. The format was validated and %c/%x/%X expanded.
int dtp_match(dtp_state* st, int fi, int ti):
	char* fmt = st.fmt
	char* text = st.text
	int c = fmt[fi] & 255
	if (c == 0): return text[ti] == 0
	if (dtfmt_is_space(c)):
		while (dtfmt_is_space(fmt[fi] & 255)): fi = fi + 1
		int n = 0
		while (dtfmt_is_space(text[ti + n] & 255)): n = n + 1
		while (n > 0):
			if (dtp_match(st, fi, ti + n)): return 1
			n = n - 1
		return 0
	if (c != '%'):
		if (dtfmt_lower(text[ti] & 255) != dtfmt_lower(c)): return 0
		return dtp_match(st, fi + 1, ti + 1)
	int dir = fmt[fi + 1] & 255
	fi = fi + 2
	if (dir == '%'):
		if (text[ti] != '%'): return 0
		return dtp_match(st, fi, ti + 1)
	int index = 0
	if ((dir == 'a') || (dir == 'A') || (dir == 'b') || (dir == 'B') || (dir == 'p') || (dir == 'Z')):
		int n = dtp_match_names(text, ti, dir, &index)
		if (n == 0): return 0
		if ((dir == 'a') || (dir == 'A')): return dtp_try(st, DTP_WEEKDAY, index, DTP_WEEKDAY, index, fi, ti + n)
		if ((dir == 'b') || (dir == 'B')): return dtp_try(st, DTP_MONTH, index, DTP_MONTH, index, fi, ti + n)
		if (dir == 'p'): return dtp_try(st, DTP_AMPM, index, DTP_AMPM, index, fi, ti + n)
		return dtp_match(st, fi, ti + n)
	if (dir == 'z'):
		int[8] lens
		int count = dtp_z_candidates(text, ti, &lens[0])
		for k in range(count):
			int offset = 0
			# A rejected value is a ValueError in Python, not a backtrack.
			if (!dtp_z_value(text, ti, lens[k], &offset)): return 0
			if (dtp_try(st, DTP_GMTOFF, offset, DTP_GMTOFF, offset, fi, ti + lens[k])): return 1
		return 0
	int k = 0
	int ndigits = 0
	int lo = 0
	int hi = 0
	int space = 0
	while (dtp_numeric_alt(dir, k, &ndigits, &lo, &hi, &space)):
		k = k + 1
		int p = ti
		if (space):
			if (text[p] != ' '): continue
			p = p + 1
		int ok = 1
		for i in range(ndigits):
			if (!dtfmt_is_digit(text[p + i] & 255)):
				ok = 0
				break
		if (!ok): continue
		int value = dtp_parse_digits(text, p, ndigits)
		if ((value < lo) || (value > hi)): continue
		if (dir == 'f'):
			for i in range(6 - ndigits): value = value * 10
		if (dtp_numeric(st, dir, value, fi, p + ndigits)): return 1
	return 0


int dtfmt_index_of_char(char* s, int c):
	int i = 0
	while (s[i] != 0):
		if ((s[i] & 255) == c): return i
		i = i + 1
	return 0 - 1


# Validates fmt (unknown directive, stray %, a group defined twice) and
# returns a malloc'd copy with %c, %x and %X expanded, or 0.
char* dtp_prepare(char* fmt):
	string_builder* sb = string_new()
	char[128] seen
	for i in range(128): seen[i] = 0
	int i = 0
	while (fmt[i] != 0):
		int c = fmt[i] & 255
		if (c != '%'):
			string_append_char(sb, c)
			i = i + 1
			continue
		int dir = fmt[i + 1] & 255
		i = i + 2
		char* expansion = 0
		if (dir == 'c'): expansion = c"%a %b %d %H:%M:%S %Y"
		else if (dir == 'x'): expansion = c"%m/%d/%y"
		else if (dir == 'X'): expansion = c"%H:%M:%S"
		else if (dir == '%'):
			string_append(sb, c"%%")
			continue
		else if ((dir == 0) || (dtfmt_index_of_char(c"aAwudbBmyYHIpMSfjUWGVzZ", dir) < 0)):
			free(dtfmt_finish(sb))
			return 0
		if (expansion == 0):
			if (seen[dir]):
				free(dtfmt_finish(sb))
				return 0
			seen[dir] = 1
			string_append_char(sb, '%')
			string_append_char(sb, dir)
			continue
		int j = 1
		while (expansion[j] != 0):
			if (expansion[j - 1] == '%'):
				int e = expansion[j] & 255
				if (seen[e]):
					free(dtfmt_finish(sb))
					return 0
				seen[e] = 1
			j = j + 1
		string_append(sb, expansion)
	return dtfmt_finish(sb)


# Python's _calc_julian_from_U_or_W.
int dtp_julian_from_week(int year, int week, int weekday, int starts_monday):
	int first_weekday = date_weekday(date_new(year, 1, 1))
	if (!starts_monday):
		first_weekday = (first_weekday + 1) % 7
		weekday = (weekday + 1) % 7
	int week0_length = (7 - first_weekday) % 7
	if (week == 0): return 1 + weekday - first_weekday
	return 1 + week0_length + 7 * (week - 1) + weekday


# Turns the captured fields into a datetime the way Python's _strptime
# and _strptime_datetime do.
int dtp_resolve(dtp_state* st, datetime* out):
	int* s = &st.slots[0]
	int year = s[DTP_YEAR]
	int month = s[DTP_MONTH]
	int day = s[DTP_DAY]
	int weekday = s[DTP_WEEKDAY]
	int julian = s[DTP_JULIAN]
	if (s[DTP_ISO_YEAR] != DTP_UNSET):
		if (julian != DTP_UNSET): return 0
		if ((s[DTP_ISO_WEEK] == DTP_UNSET) || (weekday == DTP_UNSET)): return 0
	else if (s[DTP_ISO_WEEK] != DTP_UNSET):
		return 0
	if (year == DTP_UNSET):
		# Python computes Feb 29 in 1904 and then restores 1900, which
		# makes datetime() reject it.
		if ((month == 2) && (day == 29)): return 0
		year = 1900
	if ((julian == DTP_UNSET) && (weekday != DTP_UNSET)):
		if (s[DTP_WEEK] != DTP_UNSET):
			julian = dtp_julian_from_week(year, s[DTP_WEEK], weekday, s[DTP_WEEK_STARTS_MONDAY])
		else if (s[DTP_ISO_YEAR] != DTP_UNSET):
			date iso = date_new(1, 1, 1)
			if (!date_from_isocalendar(s[DTP_ISO_YEAR], s[DTP_ISO_WEEK], weekday + 1, &iso)): return 0
			year = iso.year
			month = iso.month
			day = iso.day
		if ((julian != DTP_UNSET) && (julian <= 0)):
			year = year - 1
			if (year < DATE_MIN_YEAR): return 0
			julian = julian + time_days_in_year(year)
	if (julian != DTP_UNSET):
		if ((year < DATE_MIN_YEAR) || (year > DATE_MAX_YEAR)): return 0
		int ordinal = julian - 1 + date_to_ordinal(date_new(year, 1, 1))
		if (!date_ordinal_is_valid(ordinal)): return 0
		date d = date_from_ordinal(ordinal)
		year = d.year
		month = d.month
		day = d.day
	int hour = s[DTP_HOUR]
	if (s[DTP_HOUR_IS_I]):
		if (s[DTP_AMPM] == 2):
			if (hour != 12): hour = hour + 12
		else if (hour == 12):
			hour = 0
	if (!datetime_is_valid(year, month, day, hour, s[DTP_MINUTE], s[DTP_SECOND], s[DTP_FRACTION] * 1000)): return 0
	datetime dt = datetime_new(year, month, day, hour, s[DTP_MINUTE], s[DTP_SECOND], s[DTP_FRACTION] * 1000)
	if (s[DTP_GMTOFF] != DTP_UNSET):
		if (!datetime_utc_offset_is_valid(s[DTP_GMTOFF])): return 0
		dt = datetime_with_offset(dt, s[DTP_GMTOFF])
	*out = dt
	return 1


# Python's datetime.strptime(text, fmt) in the C locale. 1 and *out on
# success; 0 when fmt is invalid, the text does not match, or the
# fields do not form a valid datetime. A %z makes the result aware.
int datetime_strptime(char* text, char* fmt, datetime* out):
	char* prepared = dtp_prepare(fmt)
	if (prepared == 0): return 0
	dtp_state st
	st.text = text
	st.fmt = prepared
	for i in range(DTP_SLOTS): st.slots[i] = 0
	st.slots[DTP_YEAR] = DTP_UNSET
	st.slots[DTP_ISO_YEAR] = DTP_UNSET
	st.slots[DTP_MONTH] = 1
	st.slots[DTP_DAY] = 1
	st.slots[DTP_WEEKDAY] = DTP_UNSET
	st.slots[DTP_JULIAN] = DTP_UNSET
	st.slots[DTP_WEEK] = DTP_UNSET
	st.slots[DTP_ISO_WEEK] = DTP_UNSET
	st.slots[DTP_GMTOFF] = DTP_UNSET
	int ok = dtp_match(&st, 0, 0)
	free(prepared)
	if (!ok): return 0
	return dtp_resolve(&st, out)


# ---- ISO 8601 parsing (Python 3.13's fromisoformat) -------------------------------

# Exactly n ASCII digits at s[pos..]; 1 and *out on success.
int dtiso_component(char* s, int pos, int end, int n, int* out):
	if (pos + n > end): return 0
	for i in range(n):
		if (!dtfmt_is_digit(s[pos + i] & 255)): return 0
	*out = dtp_parse_digits(s, pos, n)
	return 1


# Python's _parse_isoformat_date over s[0..len): YYYY-MM-DD, YYYYMMDD,
# YYYY-Www, YYYYWww, YYYY-Www-D, YYYYWwwD.
int dtiso_parse_date(char* s, int len, date* out):
	if ((len != 7) && (len != 8) && (len != 10)): return 0
	int year = 0
	if (!dtiso_component(s, 0, len, 4, &year)): return 0
	int has_sep = s[4] == '-'
	int pos = 4 + has_sep
	if ((pos < len) && (s[pos] == 'W')):
		pos = pos + 1
		int week = 0
		if (!dtiso_component(s, pos, len, 2, &week)): return 0
		pos = pos + 2
		int weekday = 1
		if (len > pos):
			if ((s[pos] == '-') != has_sep): return 0
			pos = pos + has_sep
			if (!dtiso_component(s, pos, len, 1, &weekday)): return 0
			if (pos + 1 != len): return 0
		return date_from_isocalendar(year, week, weekday, out)
	int month = 0
	int day = 0
	if (!dtiso_component(s, pos, len, 2, &month)): return 0
	pos = pos + 2
	if (((pos < len) && (s[pos] == '-')) != has_sep): return 0
	pos = pos + has_sep
	if (!dtiso_component(s, pos, len, 2, &day)): return 0
	if (pos + 2 != len): return 0
	if (!date_is_valid(year, month, day)): return 0
	*out = date_new(year, month, day)
	return 1


# Python's _find_isoformat_datetime_separator: where the date part of a
# datetime string of len bytes (>= 7) ends; -1 when invalid.
int dtiso_find_separator(char* s, int len):
	if (len == 7): return 7
	if (s[4] == '-'):
		if (s[5] == 'W'):
			if ((len > 8) && (s[8] == '-')):
				if (len == 9): return 0 - 1
				if ((len > 10) && dtfmt_is_digit(s[10] & 255)): return 8
				return 10
			return 8
		return 10
	if (s[4] == 'W'):
		int idx = 7
		while ((idx < len) && dtfmt_is_digit(s[idx] & 255)): idx = idx + 1
		if (idx < 9): return idx
		if (idx % 2 == 0): return 7
		return 8
	return 8


# CPython's C parse_hh_mm_ss_ff over s[pos..end): HH[:?MM[:?SS[{.,}f+]]]
# with its quirks (one stray character may end the time, "HH:MM:SS:ff"
# reads ff as a fraction). comps gets hour, minute, second and
# nanoseconds (up to 9 fraction digits kept, the rest dropped). Returns
# -1 on error, 0 when the text ended cleanly, 1 when something follows.
# s[end] is the byte after the field (a zone sign or the terminator).
int dtiso_parse_hms(char* s, int pos, int end, int* comps):
	for i in range(4): comps[i] = 0
	int has_sep = 1
	int p = pos
	for i in range(3):
		if (!dtiso_component(s, p, p + 2, 2, &comps[i])): return 0 - 1
		p = p + 2
		int c = s[p] & 255
		p = p + 1
		if (i == 0): has_sep = c == ':'
		if (p >= end):
			if (c != 0): return 1
			return 0
		if (has_sep && (c == ':')): continue
		if ((c == '.') || (c == ',')):
			if (i < 2): return 0 - 1
			break
		if (has_sep): return 0 - 1
		p = p - 1
	# Python requires min(remaining, 6) digits here; W then keeps up to
	# three more for nanoseconds.
	int digits = end - p
	if (digits > 6): digits = 6
	int ns = 0
	if (!dtiso_component(s, p, p + digits, digits, &ns)): return 0 - 1
	p = p + digits
	while ((digits >= 6) && (digits < 9) && dtfmt_is_digit(s[p] & 255)):
		ns = ns * 10 + (s[p] & 255) - '0'
		digits = digits + 1
		p = p + 1
	while (digits < 9):
		ns = ns * 10
		digits = digits + 1
	comps[3] = ns
	while (dtfmt_is_digit(s[p] & 255)): p = p + 1
	if (s[p] != 0): return 1
	return 0


# CPython's C parse_isoformat_time over s[pos..end) (end is the
# terminator): a time, then an optional Z or [+-]HH[:MM[:SS[.f]]]
# offset. Returns 0 on failure, 1 when naive, 2 when aware (*offset).
int dtiso_parse_time(char* s, int pos, int end, time_of_day* t, int* offset):
	int tz = pos
	while (tz < end):
		if ((s[tz] == 'Z') || (s[tz] == '+') || (s[tz] == '-')): break
		tz = tz + 1
	int[4] comps
	int rv = dtiso_parse_hms(s, pos, tz, &comps[0])
	if (rv < 0): return 0
	if ((tz == end) && (rv == 1)): return 0
	if (!time_of_day_is_valid(comps[0], comps[1], comps[2], comps[3])): return 0
	if (tz == end):
		*t = time_of_day_new(comps[0], comps[1], comps[2], comps[3])
		return 1
	int value = 0
	if (s[tz] == 'Z'):
		if (tz + 1 != end): return 0
	else:
		int[4] tzc
		if (dtiso_parse_hms(s, tz + 1, end, &tzc[0]) != 0): return 0
		# Offsets are whole seconds here (Python allows microseconds).
		if (tzc[3] != 0): return 0
		# Like Python, minutes and seconds may exceed 59 (+05:60 is
		# +06:00); only the total must stay within 24 hours.
		value = tzc[0] * 3600 + tzc[1] * 60 + tzc[2]
		if (value >= DATETIME_SECONDS_PER_DAY): return 0
		if (s[tz] == '-'): value = 0 - value
	*t = time_of_day_new(comps[0], comps[1], comps[2], comps[3])
	*offset = value
	return 2


# Python's date.fromisoformat.
int date_fromisoformat(char* text, date* out):
	return dtiso_parse_date(text, strlen(text), out)


# Python's time.fromisoformat: an optional leading T, then the time and
# an optional offset. Returns 0 on failure, 1 for a naive time and 2
# when an offset was given (written to *offset unless offset is 0).
int time_of_day_fromisoformat(char* text, time_of_day* out, int* offset):
	int pos = 0
	if (text[0] == 'T'): pos = 1
	time_of_day t = time_of_day_new(0, 0, 0, 0)
	int off = 0
	int r = dtiso_parse_time(text, pos, strlen(text), &t, &off)
	if (r == 0): return 0
	*out = t
	if ((r == 2) && (offset != 0)): *offset = off
	return r


int dtfmt_utf8_length(int lead):
	if (lead >= 0xF0): return 4
	if (lead >= 0xE0): return 3
	if (lead >= 0xC0): return 2
	return 1


# Python's datetime.fromisoformat: a date in any of date_fromisoformat's
# forms, then optionally any single character (UTF-8 sequence) and a
# time with an optional Z / +HH:MM[:SS] offset.
int datetime_fromisoformat(char* text, datetime* out):
	int len = strlen(text)
	if (len < 7): return 0
	int sep = dtiso_find_separator(text, len)
	if (sep < 0): return 0
	if (sep > len): return 0
	date d = date_new(1, 1, 1)
	if (!dtiso_parse_date(text, sep, &d)): return 0
	time_of_day t = time_of_day_new(0, 0, 0, 0)
	int offset = 0
	int r = 1
	if (sep < len):
		int start = sep + dtfmt_utf8_length(text[sep] & 255)
		if (start > len): return 0
		# A separator needs a time after it ("2024-01-01T" is invalid).
		r = dtiso_parse_time(text, start, len, &t, &offset)
	if (r == 0): return 0
	datetime dt = datetime_combine(d, t)
	if (r == 2): dt = datetime_with_offset(dt, offset)
	*out = dt
	return 1


# ---- RFC 3339 ------------------------------------------------------------------

# RFC 3339 date-time: isoformat with sep "T", "Z" for a zero offset.
# dt must be aware with an offset of whole minutes.
char* datetime_format_rfc3339(datetime dt):
	asserts(c"datetime_format_rfc3339: datetime must be aware", dt.has_offset)
	asserts(c"datetime_format_rfc3339: offset must be whole minutes", dt.utc_offset % 60 == 0)
	string_builder* sb = string_new()
	dtfmt_append_date(sb, dt.d)
	string_append_char(sb, 'T')
	dtfmt_append_time(sb, dt.t, DATETIME_TIMESPEC_AUTO)
	if (dt.utc_offset == 0): string_append_char(sb, 'Z')
	else: dtfmt_append_offset(sb, dt.utc_offset, c":")
	return dtfmt_finish(sb)


# Strict RFC 3339 date-time: YYYY-MM-DD, T/t/space, HH:MM:SS, optional
# fraction (any digits, 9 kept), then Z/z or +HH:MM / -HH:MM (-00:00 is
# read as UTC). A leap second (:60) is rejected.
int datetime_parse_rfc3339(char* text, datetime* out):
	int len = strlen(text)
	if (len < 20): return 0
	if ((text[4] != '-') || (text[7] != '-')): return 0
	if ((text[10] != 'T') && (text[10] != 't') && (text[10] != ' ')): return 0
	if ((text[13] != ':') || (text[16] != ':')): return 0
	int year = 0
	int month = 0
	int day = 0
	int[4] c
	if (!dtiso_component(text, 0, len, 4, &year)): return 0
	if (!dtiso_component(text, 5, len, 2, &month)): return 0
	if (!dtiso_component(text, 8, len, 2, &day)): return 0
	int pos = 19
	if (text[pos] == '.'):
		pos = pos + 1
		if (!dtfmt_is_digit(text[pos] & 255)): return 0
		while (dtfmt_is_digit(text[pos] & 255)): pos = pos + 1
	if (!dtiso_component(text, 11, len, 2, &c[0])): return 0
	if (!dtiso_component(text, 14, len, 2, &c[1])): return 0
	if (!dtiso_component(text, 17, len, 2, &c[2])): return 0
	c[3] = 0
	int digits = 0
	for k in range(20, pos):
		if (digits < 9):
			c[3] = c[3] * 10 + (text[k] & 255) - '0'
			digits = digits + 1
	if (pos > 19):
		while (digits < 9):
			c[3] = c[3] * 10
			digits = digits + 1
	if (!datetime_is_valid(year, month, day, c[0], c[1], c[2], c[3])): return 0
	int offset = 0
	if ((text[pos] == 'Z') || (text[pos] == 'z')):
		if (pos + 1 != len): return 0
	else:
		if ((text[pos] != '+') && (text[pos] != '-')): return 0
		if (pos + 6 != len): return 0
		if (text[pos + 3] != ':'): return 0
		int oh = 0
		int om = 0
		if (!dtiso_component(text, pos + 1, len, 2, &oh)): return 0
		if (!dtiso_component(text, pos + 4, len, 2, &om)): return 0
		if ((oh > 23) || (om > 59)): return 0
		offset = oh * 3600 + om * 60
		if (text[pos] == '-'): offset = 0 - offset
	*out = datetime_with_offset(datetime_new(year, month, day, c[0], c[1], c[2], c[3]), offset)
	return 1


# ---- RFC 2822 / HTTP dates -------------------------------------------------------

void dtfmt_append_mail_date(string_builder* sb, datetime dt):
	string_append_bytes(sb, dtfmt_weekday_name(date_weekday(dt.d)), 3)
	string_append(sb, c", ")
	dtfmt_pad(sb, dt.d.day, 2)
	string_append_char(sb, ' ')
	string_append_bytes(sb, time_month_name(dt.d.month), 3)
	string_append_char(sb, ' ')
	dtfmt_pad(sb, dt.d.year, 4)
	string_append_char(sb, ' ')
	dtfmt_pad(sb, dt.t.hour, 2)
	string_append_char(sb, ':')
	dtfmt_pad(sb, dt.t.minute, 2)
	string_append_char(sb, ':')
	dtfmt_pad(sb, dt.t.second, 2)
	string_append_char(sb, ' ')


# Python's email.utils.format_datetime(dt): "Fri, 09 Nov 2001 01:08:47
# -0500"; a naive datetime gets "-0000" (offset unknown).
char* datetime_format_rfc2822(datetime dt):
	string_builder* sb = string_new()
	dtfmt_append_mail_date(sb, dt)
	if (dt.has_offset): dtfmt_append_offset(sb, dt.utc_offset, c"")
	else: string_append(sb, c"-0000")
	return dtfmt_finish(sb)


# RFC 7231 IMF-fixdate, "Sun, 06 Nov 1994 08:49:37 GMT" (Python's
# format_datetime(dt, usegmt=True)). An aware datetime is converted to
# UTC first; a naive one is taken as UTC.
char* datetime_format_http(datetime dt):
	if (dt.has_offset): dt = datetime_to_utc(dt)
	string_builder* sb = string_new()
	dtfmt_append_mail_date(sb, dt)
	string_append(sb, c"GMT")
	return dtfmt_finish(sb)


# A token of _parsedate_tz's word list: text[start..start+len).
struct dtmail_tok:
	int start
	int len


int dtmail_char(char* text, dtmail_tok t, int i):
	return text[t.start + i] & 255


int dtmail_last(char* text, dtmail_tok t):
	return dtmail_char(text, t, t.len - 1)


int dtmail_find(char* text, dtmail_tok t, int c):
	for i in range(t.len):
		if (dtmail_char(text, t, i) == c): return i
	return 0 - 1


dtmail_tok dtmail_slice(dtmail_tok t, int from, int to):
	dtmail_tok r
	r.start = t.start + from
	r.len = to - from
	return r


# Lowercase-equal to name?
int dtmail_is(char* text, dtmail_tok t, char* name):
	if (t.len != strlen(name)): return 0
	return dtfmt_match_name(text, t.start, name, t.len)


# _monthnames lookup: 1..12, or 0.
int dtmail_month(char* text, dtmail_tok t):
	for m in range(1, 13):
		char* name = time_month_name(m)
		if ((t.len == 3) && dtfmt_match_name(text, t.start, name, 3)): return m
		if (dtmail_is(text, t, name)): return m
	return 0


# Python's int() of an ASCII token: optional sign, digits with single
# underscores between them. Saturates at 999999999 (every caller rejects
# such values anyway).
int dtmail_int(char* text, dtmail_tok t, int* out):
	int i = 0
	int negative = 0
	if ((t.len > 0) && ((dtmail_char(text, t, 0) == '+') || (dtmail_char(text, t, 0) == '-'))):
		negative = dtmail_char(text, t, 0) == '-'
		i = 1
	if (i >= t.len): return 0
	int v = 0
	int prev_digit = 0
	while (i < t.len):
		int c = dtmail_char(text, t, i)
		if (c == '_'):
			if (!prev_digit || (i + 1 >= t.len)): return 0
			prev_digit = 0
		else if (dtfmt_is_digit(c)):
			if (v < 99999999): v = v * 10 + c - '0'
			else: v = 999999999
			prev_digit = 1
		else:
			return 0
		i = i + 1
	if (negative): v = 0 - v
	*out = v
	return 1


# The time zone names _parsedate_tz knows, as +-HHMM; 1 when found.
int dtmail_zone(char* text, dtmail_tok t, int* out):
	if (dtmail_is(text, t, c"ut") || dtmail_is(text, t, c"utc") || dtmail_is(text, t, c"gmt") || dtmail_is(text, t, c"z")):
		*out = 0
		return 1
	# AST ADT EST EDT CST CDT MST MDT PST PDT: -400 -300 -500 -400 ...
	char* zones = c"ASTADTESTEDTCSTCDTMSTMDTPSTPDT"
	char* hours = c"4354657687"
	for k in range(10):
		if ((t.len == 3) && dtfmt_match_name(text, t.start, zones + k * 3, 3)):
			*out = 0 - (hours[k] - '0') * 100
			return 1
	return 0


# Python's email.utils.parsedate_to_datetime (a port of _parsedate_tz):
# lenient RFC 2822 / RFC 822 / RFC 850 / asctime parsing. The result is
# aware when a zone was given, naive for "-0000", no zone or an unknown
# zone name. Two-digit years 69..99 are 19xx, 00..68 are 20xx.
int datetime_parse_rfc2822(char* text, datetime* out):
	dtmail_tok[8] toks
	int n = 0
	int i = 0
	while (text[i] != 0):
		while (dtfmt_is_space(text[i] & 255)): i = i + 1
		if (text[i] == 0): break
		int start = i
		while ((text[i] != 0) && !dtfmt_is_space(text[i] & 255)): i = i + 1
		if (n < 8):
			toks[n].start = start
			toks[n].len = i - start
		n = n + 1
	if (n == 0): return 0
	if (n > 7): n = 7
	# A leading day name (or anything ending in a comma) is dropped.
	dtmail_tok first = toks[0]
	int drop = dtmail_last(text, first) == ','
	for wd in range(7):
		if (dtmail_is(text, first, dtfmt_weekday_name(wd))): drop = 1
		char* name = dtfmt_weekday_name(wd)
		if ((first.len == 3) && dtfmt_match_name(text, first.start, name, 3)): drop = 1
	if (drop):
		for k in range(n - 1): toks[k] = toks[k + 1]
		n = n - 1
	else:
		int comma = 0 - 1
		for k in range(first.len):
			if (dtmail_char(text, first, k) == ','): comma = k
		if (comma >= 0): toks[0] = dtmail_slice(first, comma + 1, first.len)
	if (n == 3):
		# RFC 850 "06-Nov-94": exactly three dash-separated parts.
		dtmail_tok t = toks[0]
		int d1 = dtmail_find(text, t, '-')
		if (d1 >= 0):
			dtmail_tok rest = dtmail_slice(t, d1 + 1, t.len)
			int d2 = dtmail_find(text, rest, '-')
			if ((d2 >= 0) && (dtmail_find(text, dtmail_slice(rest, d2 + 1, rest.len), '-') < 0)):
				toks[4] = toks[2]
				toks[3] = toks[1]
				toks[0] = dtmail_slice(t, 0, d1)
				toks[1] = dtmail_slice(rest, 0, d2)
				toks[2] = dtmail_slice(rest, d2 + 1, rest.len)
				n = 5
	if (n == 4):
		dtmail_tok s = toks[3]
		int k = dtmail_find(text, s, '+')
		if (k < 0): k = dtmail_find(text, s, '-')
		if (k > 0):
			toks[3] = dtmail_slice(s, 0, k)
			toks[4] = dtmail_slice(s, k, s.len)
		else:
			toks[4] = dtmail_slice(s, s.len, s.len)
		n = 5
	if (n < 5): return 0
	dtmail_tok dd = toks[0]
	dtmail_tok mm = toks[1]
	dtmail_tok yy = toks[2]
	dtmail_tok tm = toks[3]
	dtmail_tok tz = toks[4]
	if ((dd.len == 0) || (mm.len == 0) || (yy.len == 0)): return 0
	int month = dtmail_month(text, mm)
	if (month == 0):
		dtmail_tok swap = dd
		dd = mm
		mm = swap
		month = dtmail_month(text, mm)
		if (month == 0): return 0
	if (dtmail_last(text, dd) == ','): dd.len = dd.len - 1
	if (dtmail_find(text, yy, ':') > 0):
		dtmail_tok swap = yy
		yy = tm
		tm = swap
	if (dtmail_last(text, yy) == ','):
		yy.len = yy.len - 1
		if (yy.len == 0): return 0
	if (!dtfmt_is_digit(dtmail_char(text, yy, 0))):
		dtmail_tok swap = yy
		yy = tz
		tz = swap
	if (tm.len == 0): return 0
	if (dtmail_last(text, tm) == ','): tm.len = tm.len - 1
	# Time: H:M, H:M:S, or the same with '.' (non-compliant mailers).
	dtmail_tok[3] parts
	int nparts = 0
	int sep = ':'
	if ((dtmail_find(text, tm, ':') < 0) && (dtmail_find(text, tm, '.') >= 0)): sep = '.'
	int from = 0
	for k in range(tm.len + 1):
		if ((k == tm.len) || (dtmail_char(text, tm, k) == sep)):
			if (nparts >= 3): return 0
			parts[nparts] = dtmail_slice(tm, from, k)
			nparts = nparts + 1
			from = k + 1
	if ((nparts != 2) && (nparts != 3)): return 0
	int year = 0
	int day = 0
	int hour = 0
	int minute = 0
	int second = 0
	if (!dtmail_int(text, yy, &year)): return 0
	if (!dtmail_int(text, dd, &day)): return 0
	if (!dtmail_int(text, parts[0], &hour)): return 0
	if (!dtmail_int(text, parts[1], &minute)): return 0
	if ((nparts == 3) && !dtmail_int(text, parts[2], &second)): return 0
	if (year < 100):
		if (year > 68): year = year + 1900
		else: year = year + 2000
	int has_zone = 0
	int zone = 0
	if (dtmail_zone(text, tz, &zone)): has_zone = 1
	else if (dtmail_int(text, tz, &zone)):
		has_zone = !((zone == 0) && (dtmail_char(text, tz, 0) == '-'))
	if (!datetime_is_valid(year, month, day, hour, minute, second, 0)): return 0
	datetime dt = datetime_new(year, month, day, hour, minute, second, 0)
	if (has_zone):
		int sign = 1
		if (zone < 0):
			sign = 0 - 1
			zone = 0 - zone
		if (zone / 100 > 24): return 0
		int offset = sign * ((zone / 100) * 3600 + (zone % 100) * 60)
		if (!datetime_utc_offset_is_valid(offset)): return 0
		dt = datetime_with_offset(dt, offset)
	*out = dt
	return 1


# An RFC 7231 HTTP-date (IMF-fixdate, RFC 850 or asctime; parsed with
# datetime_parse_rfc2822's rules) as an aware UTC datetime. A date with
# no zone (asctime) or "-0000" is taken as UTC.
int datetime_parse_http(char* text, datetime* out):
	datetime dt = datetime_new(1970, 1, 1, 0, 0, 0, 0)
	if (!datetime_parse_rfc2822(text, &dt)): return 0
	if (!dt.has_offset):
		*out = datetime_with_offset(dt, 0)
		return 1
	if (dt.utc_offset != 0):
		duration at = datetime_instant(dt)
		if (!date_ordinal_is_valid(at.days)): return 0
	*out = datetime_to_utc(dt)
	return 1
