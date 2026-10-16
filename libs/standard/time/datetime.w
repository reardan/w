/*
Datetime core: calendar dates, times of day, datetimes and durations
(docs/projects/stdlib_python_parity.md P1.5, area plan
libs/standard/plans/04_time_calendar.md phases 1-2). A port of the
semantics of Python's datetime module without tzinfo objects.

Every type is a small struct passed and returned by value; nothing here
allocates, so there is nothing to free.

  date          proleptic Gregorian year-month-day, year 1..9999
  time_of_day   hour, minute, second, nanosecond
  datetime      a date plus a time_of_day, naive or with a fixed UTC
                offset in seconds (has_offset = 1; |offset| < 24h)
  duration      a signed span normalized like Python's timedelta:
                days (any sign), 0 <= seconds < 86400,
                0 <= nanoseconds < 1000000000

Precision is nanoseconds (Python stops at microseconds).

WORD SIZE. int is 32 bits on x86. Nothing that only involves dates,
times of day, datetimes and durations multiplies days by 86400: dates
travel as ordinals (0001-01-01 is 1, 9999-12-31 is 3652059) and every
duration keeps whole days apart from its seconds, so years 1 and 9999
and the full span between them work on every target. Only the
conversions that produce or accept a single word of seconds are
limited by the word: datetime_to_unix / duration_total_seconds overflow
on x86 past 2038-01-19 03:14:07 UTC (about +-68 years of seconds), and
the _checked variants report that instead of wrapping. datetime_now_utc
reads CLOCK_REALTIME, whose i386 timespec has the same 2038 limit.

Out-of-range construction or arithmetic (Python's ValueError /
OverflowError) fails an assertion; the *_is_valid predicates and the
_checked variants let callers test first.

Weekdays follow Python: date_weekday is Monday = 0 .. Sunday = 6 and
date_isoweekday is Monday = 1 .. Sunday = 7. (lib/time.w's date_time
uses Sunday = 0.) Civil-date math is lib/time.w's
time_days_from_civil; this file adds only its inverse.
*/
import lib.lib
import lib.assert
import lib.time


const int DATE_MIN_YEAR = 1
const int DATE_MAX_YEAR = 9999
const int DATE_MAX_ORDINAL = 3652059
# Ordinal of 1970-01-01 (time_days_from_civil's day 0).
const int DATE_UNIX_EPOCH_ORDINAL = 719163
const int DATETIME_NANOS_PER_SECOND = 1000000000
const int DATETIME_SECONDS_PER_DAY = 86400


struct date:
	int year
	int month
	int day


struct time_of_day:
	int hour
	int minute
	int second
	int nanosecond


struct datetime:
	date d
	time_of_day t
	int has_offset        # 0 = naive, 1 = aware with a fixed UTC offset
	int utc_offset        # seconds east of UTC; 0 when naive


struct duration:
	int days
	int seconds           # 0 .. 86399
	int nanoseconds       # 0 .. 999999999


# ISO 8601 calendar date (Python's date.isocalendar()).
struct iso_calendar_date:
	int year
	int week              # 1 .. 53
	int weekday           # Monday = 1 .. Sunday = 7


# ---- integer helpers ---------------------------------------------------------

# Floored division and modulo (W's / and % truncate toward zero).
int datetime_floor_div(int a, int b):
	int q = a / b
	if ((a % b != 0) && ((a < 0) != (b < 0))): q = q - 1
	return q


int datetime_floor_mod(int a, int b):
	return a - datetime_floor_div(a, b) * b


# Could a day offset keep some date in range? Bounding it first keeps
# ordinal + days from overflowing before the range check.
int datetime_day_span_is_valid(int days):
	return (days <= DATE_MAX_ORDINAL) && (days >= 0 - DATE_MAX_ORDINAL)


int datetime_int_max():
	return ~(1 << (__word_size__ * 8 - 1))


# ---- duration ------------------------------------------------------------------

# days + seconds + nanoseconds, each of any sign, normalized so seconds
# is 0..86399 and nanoseconds 0..999999999 (Python's timedelta
# constructor). duration_new(0, 0 - 1, 0) is -1 day + 86399 seconds.
duration duration_new(int days, int seconds, int nanoseconds):
	duration d
	d.nanoseconds = datetime_floor_mod(nanoseconds, DATETIME_NANOS_PER_SECOND)
	int carry_seconds = datetime_floor_div(nanoseconds, DATETIME_NANOS_PER_SECOND)
	# Fold seconds into days before adding the carry so neither sum can
	# overflow a 32-bit word.
	int s = datetime_floor_mod(seconds, DATETIME_SECONDS_PER_DAY)
	int carry_days = datetime_floor_div(seconds, DATETIME_SECONDS_PER_DAY)
	s = s + datetime_floor_mod(carry_seconds, DATETIME_SECONDS_PER_DAY)
	carry_days = carry_days + datetime_floor_div(carry_seconds, DATETIME_SECONDS_PER_DAY)
	if (s >= DATETIME_SECONDS_PER_DAY):
		s = s - DATETIME_SECONDS_PER_DAY
		carry_days = carry_days + 1
	d.seconds = s
	d.days = days + carry_days
	return d


duration duration_zero():
	return duration_new(0, 0, 0)


# A span of whole seconds (negative for a backward span).
duration duration_from_seconds(int seconds):
	return duration_new(0, seconds, 0)


duration duration_from_millis(int ms):
	return duration_new(0, datetime_floor_div(ms, 1000), datetime_floor_mod(ms, 1000) * 1000000)


duration duration_from_micros(int us):
	return duration_new(0, datetime_floor_div(us, 1000000), datetime_floor_mod(us, 1000000) * 1000)


duration duration_add(duration a, duration b):
	int ns = a.nanoseconds + b.nanoseconds
	int s = a.seconds + b.seconds
	int days = a.days + b.days
	if (ns >= DATETIME_NANOS_PER_SECOND):
		ns = ns - DATETIME_NANOS_PER_SECOND
		s = s + 1
	if (s >= DATETIME_SECONDS_PER_DAY):
		s = s - DATETIME_SECONDS_PER_DAY
		days = days + 1
	duration d
	d.days = days
	d.seconds = s
	d.nanoseconds = ns
	return d


# hours/minutes/seconds of any sign; each is folded separately, so on
# x86 each argument only needs to fit a word on its own.
duration duration_from_hms(int hours, int minutes, int seconds):
	duration h = duration_new(datetime_floor_div(hours, 24), datetime_floor_mod(hours, 24) * 3600, 0)
	duration m = duration_new(datetime_floor_div(minutes, 1440), datetime_floor_mod(minutes, 1440) * 60, 0)
	return duration_add(duration_add(h, m), duration_from_seconds(seconds))


duration duration_neg(duration a):
	return duration_new(0 - a.days, 0 - a.seconds, 0 - a.nanoseconds)


duration duration_sub(duration a, duration b):
	return duration_add(a, duration_neg(b))


int duration_is_negative(duration a):
	return a.days < 0


int duration_is_zero(duration a):
	return (a.days == 0) && (a.seconds == 0) && (a.nanoseconds == 0)


duration duration_abs(duration a):
	if (duration_is_negative(a)): return duration_neg(a)
	return a


int duration_compare(duration a, duration b):
	if (a.days != b.days): return a.days - b.days
	if (a.seconds != b.seconds): return a.seconds - b.seconds
	if (a.nanoseconds < b.nanoseconds): return 0 - 1
	if (a.nanoseconds > b.nanoseconds): return 1
	return 0


int duration_equal(duration a, duration b):
	return duration_compare(a, b) == 0


# a * k for an integer factor k of any sign. Uses repeated doubling so no
# intermediate leaves the normalized (days, seconds, ns) form.
duration duration_mul(duration a, int k):
	int negative = k < 0
	int n = k
	if (negative): n = 0 - k
	duration result = duration_zero()
	duration power = a
	while (n > 0):
		if (n & 1): result = duration_add(result, power)
		n = n >> 1
		if (n > 0): power = duration_add(power, power)
	if (negative): return duration_neg(result)
	return result


# Whole seconds, floored (Python's total_seconds() rounded down): 1.5s is
# 1 and -0.5s is -1. 1 and *out on success; 0 when the result does not
# fit a word (spans beyond about 68 years on x86).
int duration_total_seconds_checked(duration a, int* out):
	int q = datetime_int_max() / DATETIME_SECONDS_PER_DAY
	int r = datetime_int_max() % DATETIME_SECONDS_PER_DAY
	if (a.days > q): return 0
	if ((a.days == q) && (a.seconds > r)): return 0
	if (a.days < 0 - q - 1): return 0
	if ((a.days == 0 - q - 1) && (a.seconds < DATETIME_SECONDS_PER_DAY - r - 1)): return 0
	*out = a.days * DATETIME_SECONDS_PER_DAY + a.seconds
	return 1


# As duration_total_seconds_checked, asserting that the result fits.
int duration_total_seconds(duration a):
	int s = 0
	asserts(c"duration_total_seconds: overflows int", duration_total_seconds_checked(a, &s))
	return s


# Whole milliseconds, floored; assert when it does not fit a word
# (beyond about 24.8 days on x86).
int duration_total_millis(duration a):
	int max_days = datetime_int_max() / (DATETIME_SECONDS_PER_DAY * 1000) - 1
	asserts(c"duration_total_millis: overflows int", (a.days <= max_days) && (a.days >= 0 - max_days))
	return (a.days * DATETIME_SECONDS_PER_DAY + a.seconds) * 1000 + a.nanoseconds / 1000000


# ---- date ----------------------------------------------------------------------

int date_is_valid(int year, int month, int day):
	if ((year < DATE_MIN_YEAR) || (year > DATE_MAX_YEAR)): return 0
	if ((month < 1) || (month > 12)): return 0
	if ((day < 1) || (day > time_days_in_month(year, month))): return 0
	return 1


date date_new(int year, int month, int day):
	asserts(c"date_new: year, month or day out of range", date_is_valid(year, month, day))
	date d
	d.year = year
	d.month = month
	d.day = day
	return d


# Proleptic Gregorian ordinal: 0001-01-01 is day 1 (Python's toordinal).
int date_to_ordinal(date d):
	return time_days_from_civil(d.year, d.month, d.day) + DATE_UNIX_EPOCH_ORDINAL


int date_ordinal_is_valid(int ordinal):
	return (ordinal >= 1) && (ordinal <= DATE_MAX_ORDINAL)


# Inverse of date_to_ordinal (Python's date.fromordinal), via Howard
# Hinnant's civil_from_days, the inverse of time_days_from_civil. The
# ordinal range keeps every intermediate non-negative.
date date_from_ordinal(int ordinal):
	asserts(c"date_from_ordinal: ordinal out of range 1..3652059", date_ordinal_is_valid(ordinal))
	# Days since 0000-03-01, the start of the 400-year era containing year 1.
	int z = ordinal + 305
	int era = z / 146097
	int doe = z - era * 146097
	int yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	int doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
	int mp = (5 * doy + 2) / 153
	date d
	d.day = doy - (153 * mp + 2) / 5 + 1
	if (mp < 10):
		d.month = mp + 3
	else:
		d.month = mp - 9
	d.year = yoe + era * 400
	if (d.month <= 2): d.year = d.year + 1
	return d


# Monday = 0 .. Sunday = 6 (Python's weekday()).
int date_weekday(date d):
	return (date_to_ordinal(d) + 6) % 7


# Monday = 1 .. Sunday = 7 (Python's isoweekday()).
int date_isoweekday(date d):
	return date_weekday(d) + 1


# 1-based day of the year (tm_yday + 1, strftime %j).
int date_day_of_year(date d):
	return time_days_from_civil(d.year, d.month, d.day) - time_days_from_civil(d.year, 1, 1) + 1


int date_is_leap_year(int year):
	return time_is_leap_year(year)


int date_days_in_month(int year, int month):
	return time_days_in_month(year, month)


# Negative, zero or positive as a is before, equal to or after b.
int date_compare(date a, date b):
	if (a.year != b.year): return a.year - b.year
	if (a.month != b.month): return a.month - b.month
	return a.day - b.day


int date_equal(date a, date b):
	return date_compare(a, b) == 0


# d + n days (n may be negative); the result must stay in years 1..9999.
date date_add_days(date d, int days):
	int ordinal = date_to_ordinal(d)
	asserts(c"date_add_days: result out of range", datetime_day_span_is_valid(days))
	return date_from_ordinal(ordinal + days)


# Python's date + timedelta: only the whole days of delta count.
date date_add(date d, duration delta):
	return date_add_days(d, delta.days)


date date_sub(date d, duration delta):
	return date_add_days(d, 0 - delta.days)


# a - b in days.
int date_diff_days(date a, date b):
	return date_to_ordinal(a) - date_to_ordinal(b)


# Python's date - date: a duration of whole days.
duration date_diff(date a, date b):
	return duration_new(date_diff_days(a, b), 0, 0)


# Ordinal of the Monday that starts ISO week 1 of year.
int date_iso_week1_monday(int year):
	int first = time_days_from_civil(year, 1, 1) + DATE_UNIX_EPOCH_ORDINAL
	int first_weekday = (first + 6) % 7
	int monday = first - first_weekday
	if (first_weekday > 3): monday = monday + 7
	return monday


# ISO year, week and weekday (Python's isocalendar()). The ISO year can
# differ from d.year in the first and last days of a year.
iso_calendar_date date_isocalendar(date d):
	int year = d.year
	int today = date_to_ordinal(d)
	int monday = date_iso_week1_monday(year)
	int offset = today - monday
	int week = datetime_floor_div(offset, 7)
	int day = datetime_floor_mod(offset, 7)
	if (week < 0):
		year = year - 1
		monday = date_iso_week1_monday(year)
		week = (today - monday) / 7
		day = (today - monday) % 7
	else if (week >= 52):
		if (today >= date_iso_week1_monday(year + 1)):
			year = year + 1
			week = 0
	iso_calendar_date result
	result.year = year
	result.week = week + 1
	result.weekday = day + 1
	return result


# Does the ISO year have 53 weeks? (It starts on a Thursday, or on a
# Wednesday in a leap year.)
int date_iso_year_has_53_weeks(int year):
	int first_weekday = (time_days_from_civil(year, 1, 1) + DATE_UNIX_EPOCH_ORDINAL + 6) % 7
	if (first_weekday == 3): return 1
	if ((first_weekday == 2) && time_is_leap_year(year)): return 1
	return 0


# Python's date.fromisocalendar: 1 and *out on success, 0 (out untouched)
# when year/week/weekday are out of range or the date leaves 1..9999.
int date_from_isocalendar(int year, int week, int weekday, date* out):
	if ((year < DATE_MIN_YEAR) || (year > DATE_MAX_YEAR)): return 0
	if ((weekday < 1) || (weekday > 7)): return 0
	if (week < 1): return 0
	if (week > 53): return 0
	if ((week == 53) && !date_iso_year_has_53_weeks(year)): return 0
	int ordinal = date_iso_week1_monday(year) + (week - 1) * 7 + weekday - 1
	if (!date_ordinal_is_valid(ordinal)): return 0
	*out = date_from_ordinal(ordinal)
	return 1


# ---- time_of_day ---------------------------------------------------------------

int time_of_day_is_valid(int hour, int minute, int second, int nanosecond):
	if ((hour < 0) || (hour > 23)): return 0
	if ((minute < 0) || (minute > 59)): return 0
	if ((second < 0) || (second > 59)): return 0
	if ((nanosecond < 0) || (nanosecond >= DATETIME_NANOS_PER_SECOND)): return 0
	return 1


time_of_day time_of_day_new(int hour, int minute, int second, int nanosecond):
	asserts(c"time_of_day_new: field out of range", time_of_day_is_valid(hour, minute, second, nanosecond))
	time_of_day t
	t.hour = hour
	t.minute = minute
	t.second = second
	t.nanosecond = nanosecond
	return t


# Whole seconds since midnight, 0 .. 86399.
int time_of_day_seconds(time_of_day t):
	return t.hour * 3600 + t.minute * 60 + t.second


# seconds is 0 .. 86399.
time_of_day time_of_day_from_seconds(int seconds, int nanosecond):
	asserts(c"time_of_day_from_seconds: out of range", (seconds >= 0) && (seconds < DATETIME_SECONDS_PER_DAY))
	return time_of_day_new(seconds / 3600, (seconds / 60) % 60, seconds % 60, nanosecond)


int time_of_day_compare(time_of_day a, time_of_day b):
	int c = time_of_day_seconds(a) - time_of_day_seconds(b)
	if (c != 0): return c
	if (a.nanosecond < b.nanosecond): return 0 - 1
	if (a.nanosecond > b.nanosecond): return 1
	return 0


# ---- datetime ------------------------------------------------------------------

int datetime_is_valid(int year, int month, int day, int hour, int minute, int second, int nanosecond):
	return date_is_valid(year, month, day) && time_of_day_is_valid(hour, minute, second, nanosecond)


datetime datetime_combine(date d, time_of_day t):
	datetime dt
	dt.d = d
	dt.t = t
	dt.has_offset = 0
	dt.utc_offset = 0
	return dt


# A naive datetime.
datetime datetime_new(int year, int month, int day, int hour, int minute, int second, int nanosecond):
	return datetime_combine(date_new(year, month, day), time_of_day_new(hour, minute, second, nanosecond))


int datetime_utc_offset_is_valid(int offset_seconds):
	return (offset_seconds > 0 - DATETIME_SECONDS_PER_DAY) && (offset_seconds < DATETIME_SECONDS_PER_DAY)


# The same wall-clock fields labeled with a UTC offset (Python's
# replace(tzinfo=timezone(timedelta(seconds=offset)))); no conversion.
datetime datetime_with_offset(datetime dt, int offset_seconds):
	asserts(c"datetime_with_offset: offset must be strictly within +-24h", datetime_utc_offset_is_valid(offset_seconds))
	dt.has_offset = 1
	dt.utc_offset = offset_seconds
	return dt


# The same wall-clock fields with the offset dropped (replace(tzinfo=None)).
datetime datetime_naive(datetime dt):
	dt.has_offset = 0
	dt.utc_offset = 0
	return dt


date datetime_date(datetime dt):
	return dt.d


time_of_day datetime_time(datetime dt):
	return dt.t


int datetime_weekday(datetime dt):
	return date_weekday(dt.d)


int datetime_isoweekday(datetime dt):
	return date_isoweekday(dt.d)


int datetime_day_of_year(datetime dt):
	return date_day_of_year(dt.d)


iso_calendar_date datetime_isocalendar(datetime dt):
	return date_isocalendar(dt.d)


# Builds dt's fields from an ordinal day count plus seconds-of-day and
# nanoseconds already normalized, keeping dt's offset; asserts that the
# ordinal stays in 1..9999.
datetime datetime_from_parts(int ordinal, int seconds, int nanosecond, int has_offset, int utc_offset):
	asserts(c"datetime: result out of range (years 1..9999)", date_ordinal_is_valid(ordinal))
	datetime dt = datetime_combine(date_from_ordinal(ordinal), time_of_day_from_seconds(seconds, nanosecond))
	dt.has_offset = has_offset
	dt.utc_offset = utc_offset
	return dt


# dt + delta (Python's datetime + timedelta): wall-clock arithmetic that
# keeps dt's offset.
datetime datetime_add(datetime dt, duration delta):
	asserts(c"datetime_add: result out of range", datetime_day_span_is_valid(delta.days))
	duration at = duration_new(date_to_ordinal(dt.d), time_of_day_seconds(dt.t), dt.t.nanosecond)
	at = duration_add(at, delta)
	return datetime_from_parts(at.days, at.seconds, at.nanoseconds, dt.has_offset, dt.utc_offset)


datetime datetime_sub(datetime dt, duration delta):
	return datetime_add(dt, duration_neg(delta))


# The instant as a duration since 0001-01-01T00:00 (UTC when aware). An
# aware datetime near year 1 or 9999 may fall just outside the range;
# the duration form needs no range check.
duration datetime_instant(datetime dt):
	return duration_new(date_to_ordinal(dt.d), time_of_day_seconds(dt.t) - dt.utc_offset, dt.t.nanosecond)


# a - b (Python's datetime - datetime). Both naive or both aware: aware
# operands are compared as UTC instants.
duration datetime_diff(datetime a, datetime b):
	asserts(c"datetime_diff: cannot mix naive and aware datetimes", a.has_offset == b.has_offset)
	return duration_sub(datetime_instant(a), datetime_instant(b))


# Ordering: negative, zero or positive. Both naive or both aware (aware
# datetimes compare as UTC instants, so equal instants with different
# offsets compare equal, as in Python).
int datetime_compare(datetime a, datetime b):
	asserts(c"datetime_compare: cannot compare naive and aware datetimes", a.has_offset == b.has_offset)
	return duration_compare(datetime_instant(a), datetime_instant(b))


# Python's ==: naive and aware datetimes are never equal.
int datetime_equal(datetime a, datetime b):
	if (a.has_offset != b.has_offset): return 0
	return datetime_compare(a, b) == 0


# The same instant expressed at another UTC offset (Python's
# astimezone(timezone(timedelta(seconds=offset)))). dt must be aware.
datetime datetime_to_offset(datetime dt, int offset_seconds):
	asserts(c"datetime_to_offset: datetime must be aware", dt.has_offset)
	asserts(c"datetime_to_offset: offset must be strictly within +-24h", datetime_utc_offset_is_valid(offset_seconds))
	duration at = duration_add(datetime_instant(dt), duration_from_seconds(offset_seconds))
	return datetime_from_parts(at.days, at.seconds, at.nanoseconds, 1, offset_seconds)


datetime datetime_to_utc(datetime dt):
	return datetime_to_offset(dt, 0)


# ---- Unix timestamps -------------------------------------------------------------

# The aware UTC datetime of a Unix timestamp plus nanoseconds (Python's
# datetime.fromtimestamp(ts, timezone.utc)). Negative timestamps are
# before 1970. Every word-sized timestamp is in range on x86; on x64 the
# result must stay in years 1..9999.
datetime datetime_from_unix_ns(int timestamp, int nanosecond):
	duration since = duration_new(0, timestamp, nanosecond)
	asserts(c"datetime_from_unix: timestamp out of range", datetime_day_span_is_valid(since.days))
	return datetime_from_parts(since.days + DATE_UNIX_EPOCH_ORDINAL, since.seconds, since.nanoseconds, 1, 0)


datetime datetime_from_unix(int timestamp):
	return datetime_from_unix_ns(timestamp, 0)


# Whole seconds since 1970-01-01T00:00:00Z, floored (sub-second
# nanoseconds are dropped). A naive datetime is read as UTC (W has no
# local time zone yet). 1 and *out on success; 0 when the result does not
# fit a word, which on x86 means after 2038-01-19T03:14:07Z or before
# 1901-12-13T20:45:52Z.
int datetime_to_unix_checked(datetime dt, int* out):
	duration since = duration_sub(datetime_instant(dt), duration_new(DATE_UNIX_EPOCH_ORDINAL, 0, 0))
	return duration_total_seconds_checked(since, out)


# As datetime_to_unix_checked, asserting that the result fits.
int datetime_to_unix(datetime dt):
	int s = 0
	asserts(c"datetime_to_unix: timestamp overflows int (2038 limit on x86)", datetime_to_unix_checked(dt, &s))
	return s


# The current time as an aware UTC datetime with nanoseconds, from
# CLOCK_REALTIME (falling back to time_now() where that clock is
# unavailable). On x86 the kernel's 32-bit timespec wraps in 2038.
datetime datetime_now_utc():
	timespec ts
	int err = sys_clock_gettime(0, cast(int, &ts))
	if (err < 0):
		return datetime_from_unix(time_now())
	return datetime_from_unix_ns(ts.seconds, ts.nanoseconds)


date date_today_utc():
	return datetime_now_utc().d
