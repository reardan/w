/*
IANA time zones (docs/projects/stdlib_python_parity.md P1.7, area plan
libs/standard/plans/04_time_calendar.md phase 5): a port of the
semantics of Python's zoneinfo module (PEP 615) on top of the P1.5
datetime core (libs/standard/time/datetime.w).

A zoneinfo is loaded from a compiled TZif file (RFC 8536, versions 1,
2 and 3) or built from a POSIX TZ string, and answers the questions a
Python tzinfo answers:

  zoneinfo_lookup_local / _utcoffset / _dst / _tzname
      the UTC offset, DST adjustment and abbreviation in force at a
      naive local wall time (Python's utcoffset/dst/tzname)
  zoneinfo_fromutc / datetime_from_unix_zone / zoneinfo_offset_at
      the local time of an instant (Python's fromutc / astimezone)
  zoneinfo_localize
      a naive wall time made aware (Python's replace(tzinfo=zone))

FOLD (PEP 495). datetime.w's datetime has no fold attribute, so fold is
an extra argument (0 or 1) and an out-parameter here. A local time that
occurs twice (the clock goes back: ambiguous) means the first
occurrence with fold = 0 and the second with fold = 1. A local time that
never occurs (the clock jumps forward: nonexistent, "in the gap") is
read with the offset in force before the transition when fold = 0 and
the one after it when fold = 1, so it maps to an instant on either side
of the gap, exactly as in Python. zoneinfo_fromutc reports fold = 1 for
the second occurrence of an ambiguous wall time. zoneinfo_local_kind
classifies a wall time as unique, ambiguous or nonexistent.

Dates past the transition table follow the TZ string footer of v2+
files (std offset dst [offset],start[/time],end[/time] with Mm.w.d, Jn
and n rule dates and v3's hours up to +-167 and negative times). Jn and
n follow POSIX (as glibc does): Jn counts 1..365 and never Feb 29, n
counts 0..365 from Jan 1. Python 3.13's zoneinfo is off by one day for
n rules and for J59 in leap years; that is the one place this module
deliberately differs from Python. Like Python, a footer is evaluated
one year at a time (the UTC year for fromutc), so a DST period that
runs across New Year in UTC terms (v3 all-year DST) reads as standard
time for the hours of January 1 before the year's own switch, where
glibc says DST. A v1 file (no footer) keeps its last
offset forever, as in Python.

FINDING ZONES. zoneinfo_load(key) searches $TZDIR when it is set and
non-empty, otherwise /usr/share/zoneinfo, /usr/lib/zoneinfo,
/usr/share/lib/zoneinfo and /etc/zoneinfo (Python's default TZPATH);
zoneinfo_load_from(key, dir) searches one explicit directory (hermetic
tests). Keys are relative paths such as "America/New_York"; absolute
keys and "." / ".." components are rejected. zoneinfo_local() is the
process's local zone, resolved like glibc: $TZ unset -> /etc/localtime;
$TZ empty -> UTC; ":"-prefix stripped; an absolute path -> that file; a
key -> the search path; otherwise a POSIX TZ string ("EST5EDT,M3.2.0,
M11.1.0"). No zone database is bundled: when nothing resolves (and on
targets with no zoneinfo files, such as wasm and win64) local time is
UTC.

WORD SIZE. Timestamps are word-sized ints. On x86 (32-bit int)
transitions after 2038-01-19 are dropped from the table (the footer
rule covers them) and earlier ones before 1901-12-13 are clamped to the
smallest int, so instants and wall times before 1901-12-14 use the
zone's pre-table offset (usually local mean time) instead of the
table's; years after 2038 work everywhere through the footer, because
footer rules are evaluated in seconds since the start of the year.
Seconds are floored: sub-second nanoseconds never move a lookup.

Every zoneinfo is malloc'd; release it with zoneinfo_free. Abbreviations
and keys returned by the accessors point into the zone (do not free).
*/
import lib.lib
import lib.assert
import lib.env
import lib.path
import lib.stream
import structures.string
import libs.standard.time.datetime


const int ZONEINFO_LOCAL_UNIQUE = 0
const int ZONEINFO_LOCAL_AMBIGUOUS = 1      # occurs twice (fold picks one)
const int ZONEINFO_LOCAL_NONEXISTENT = 2    # skipped by a forward jump

# POSIX rule-date kinds.
const int ZONEINFO_RULE_MONTH = 0    # Mm.w.d
const int ZONEINFO_RULE_JULIAN = 1   # Jn, 1..365, Feb 29 never counted
const int ZONEINFO_RULE_DAY = 2      # n, 0..365


# One local time type (Python's _ttinfo).
struct zoneinfo_period:
	int utc_offset    # seconds east of UTC
	int dst           # DST adjustment in seconds (0 for standard time)
	char* abbr        # e.g. "EST"; points into the zone


# When a POSIX rule switches: a date and a local wall time of day.
struct zoneinfo_rule_date:
	int kind
	int month
	int week
	int weekday       # 0 = Sunday
	int day           # Jn / n
	int time          # seconds after local midnight, may be negative or > 24h


struct zoneinfo:
	char* key
	int transition_count
	int* trans_utc        # transition instants, Unix seconds, ascending
	int* trans_local0     # the same as local wall seconds for fold = 0
	int* trans_local1     # ... and for fold = 1
	int* trans_type       # local time type in force from each transition
	int type_count
	int* type_offset
	int* type_dst
	int* type_isdst
	int* type_abbr        # offsets into abbr_chars
	char* abbr_chars      # NUL-separated designations (NUL-terminated)
	int before_type       # type before the first transition (-1: none)
	# After the table: a POSIX rule (has_rule = 1) or one fixed period.
	int has_rule
	zoneinfo_period after
	zoneinfo_period rule_std
	zoneinfo_period rule_dst
	int dst_diff
	zoneinfo_rule_date rule_start
	zoneinfo_rule_date rule_end
	char* std_abbr        # owned footer abbreviations (or 0)
	char* dst_abbr


# ---- allocation ---------------------------------------------------------------

int* zoneinfo_int_array(int count):
	int n = count
	if (n < 1): n = 1
	return cast(int*, malloc(n * __word_size__))


zoneinfo* zoneinfo_new_empty():
	zoneinfo* z = cast(zoneinfo*, malloc(sizeof(zoneinfo)))
	z.key = 0
	z.transition_count = 0
	z.trans_utc = 0
	z.trans_local0 = 0
	z.trans_local1 = 0
	z.trans_type = 0
	z.type_count = 0
	z.type_offset = 0
	z.type_dst = 0
	z.type_isdst = 0
	z.type_abbr = 0
	z.abbr_chars = 0
	z.before_type = 0 - 1
	z.has_rule = 0
	z.after.utc_offset = 0
	z.after.dst = 0
	z.after.abbr = c""
	z.rule_std = z.after
	z.rule_dst = z.after
	z.dst_diff = 0
	z.std_abbr = 0
	z.dst_abbr = 0
	return z


void zoneinfo_free_if(void* p):
	if (p != 0): free(p)


void zoneinfo_free(zoneinfo* z):
	if (z == 0): return
	zoneinfo_free_if(z.key)
	zoneinfo_free_if(z.trans_utc)
	zoneinfo_free_if(z.trans_local0)
	zoneinfo_free_if(z.trans_local1)
	zoneinfo_free_if(z.trans_type)
	zoneinfo_free_if(z.type_offset)
	zoneinfo_free_if(z.type_dst)
	zoneinfo_free_if(z.type_isdst)
	zoneinfo_free_if(z.type_abbr)
	zoneinfo_free_if(z.abbr_chars)
	zoneinfo_free_if(z.std_abbr)
	zoneinfo_free_if(z.dst_abbr)
	free(z)


# The zone's key ("America/New_York", the TZ string, "localtime"), or 0.
char* zoneinfo_key(zoneinfo* z):
	return z.key


void zoneinfo_set_key(zoneinfo* z, char* key):
	zoneinfo_free_if(z.key)
	z.key = 0
	if (key != 0): z.key = strclone(key)


# ---- word arithmetic --------------------------------------------------------------

int zoneinfo_int_min():
	return 1 << (__word_size__ * 8 - 1)


# a + b, saturating at the word's limits (only matters on x86 for
# clamped transitions).
int zoneinfo_add_sat(int a, int b):
	int max = datetime_int_max()
	if ((b > 0) && (a > max - b)): return max
	if ((b < 0) && (a < zoneinfo_int_min() - b)): return zoneinfo_int_min()
	return a + b


# Seconds of dt's wall-clock fields since 1970-01-01T00:00 (offset
# ignored, sub-seconds dropped). 1 and *out when it fits a word.
int zoneinfo_wall_seconds(datetime dt, int* out):
	duration since = duration_new(date_to_ordinal(dt.d) - DATE_UNIX_EPOCH_ORDINAL, time_of_day_seconds(dt.t), 0)
	return duration_total_seconds_checked(since, out)


# Seconds of dt's wall-clock fields since Jan 1 00:00 of dt's year.
int zoneinfo_year_seconds(datetime dt):
	int day = date_to_ordinal(dt.d) - date_to_ordinal(date_new(dt.d.year, 1, 1))
	return day * DATETIME_SECONDS_PER_DAY + time_of_day_seconds(dt.t)


# Rightmost insertion point of value in the ascending a[0..n) (Python's
# bisect_right).
int zoneinfo_bisect_right(int* a, int n, int value):
	int lo = 0
	int hi = n
	while (lo < hi):
		int mid = (lo + hi) / 2
		if (value < a[mid]):
			hi = mid
		else:
			lo = mid + 1
	return lo


# ---- POSIX TZ strings ------------------------------------------------------------

int zoneinfo_is_digit(int c):
	return (c >= '0') && (c <= '9')


int zoneinfo_is_alpha(int c):
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z'))


# Parses an abbreviation at s[*pos]: letters, or <...> of letters,
# digits, '+' and '-'. Returns a malloc'd copy (without <>) or 0.
char* zoneinfo_parse_abbr(char* s, int* pos):
	int i = *pos
	int start = i
	int end = i
	if (s[i] == '<'):
		i = i + 1
		start = i
		while (zoneinfo_is_alpha(s[i]) || zoneinfo_is_digit(s[i]) || (s[i] == '+') || (s[i] == '-')): i = i + 1
		if ((s[i] != '>') || (i == start)): return 0
		end = i
		i = i + 1
	else:
		while (zoneinfo_is_alpha(s[i])): i = i + 1
		if (i == start): return 0
		end = i
	char* out = cast(char*, malloc(end - start + 1))
	int k = 0
	while (k < end - start):
		out[k] = s[start + k]
		k = k + 1
	out[k] = 0
	*pos = i
	return out


# Parses n digits (min_digits..max_digits) into *out.
int zoneinfo_parse_digits(char* s, int* pos, int min_digits, int max_digits, int* out):
	int i = *pos
	int value = 0
	while (zoneinfo_is_digit(s[i]) && (i - *pos < max_digits)):
		value = value * 10 + s[i] - '0'
		i = i + 1
	if (i - *pos < min_digits): return 0
	if (zoneinfo_is_digit(s[i])): return 0
	*pos = i
	*out = value
	return 1


# [+-]h{1,3}[:mm[:ss]] into signed seconds; *hours gets the hour field.
int zoneinfo_parse_hms(char* s, int* pos, int* out, int* hours):
	int i = *pos
	int sign = 1
	if ((s[i] == '+') || (s[i] == '-')):
		if (s[i] == '-'): sign = 0 - 1
		i = i + 1
	int h = 0
	int m = 0
	int sec = 0
	if (!zoneinfo_parse_digits(s, &i, 1, 3, &h)): return 0
	if (s[i] == ':'):
		i = i + 1
		if (!zoneinfo_parse_digits(s, &i, 2, 2, &m)): return 0
		if (s[i] == ':'):
			i = i + 1
			if (!zoneinfo_parse_digits(s, &i, 2, 2, &sec)): return 0
	*pos = i
	*hours = h
	*out = sign * (h * 3600 + m * 60 + sec)
	return 1


# A UTC offset as written in TZ strings: hours WEST of UTC, so "+5" and
# "5" are -5h. Hours must be 0..24.
int zoneinfo_parse_offset(char* s, int* pos, int* out):
	int h = 0
	int v = 0
	if (!zoneinfo_parse_hms(s, pos, &v, &h)): return 0
	if (h > 24): return 0
	*out = 0 - v
	return 1


# date[/time] up to the next ',' or the end; time defaults to 02:00.
int zoneinfo_parse_rule_date(char* s, int* pos, zoneinfo_rule_date* out):
	int i = *pos
	out.kind = ZONEINFO_RULE_DAY
	out.month = 0
	out.week = 0
	out.weekday = 0
	out.day = 0
	out.time = 7200
	if (s[i] == 'M'):
		i = i + 1
		out.kind = ZONEINFO_RULE_MONTH
		if (!zoneinfo_parse_digits(s, &i, 1, 2, &out.month)): return 0
		if (s[i] != '.'): return 0
		i = i + 1
		if (!zoneinfo_parse_digits(s, &i, 1, 1, &out.week)): return 0
		if (s[i] != '.'): return 0
		i = i + 1
		if (!zoneinfo_parse_digits(s, &i, 1, 1, &out.weekday)): return 0
		if ((out.month < 1) || (out.month > 12)): return 0
		if ((out.week < 1) || (out.week > 5)): return 0
		if (out.weekday > 6): return 0
	else:
		if (s[i] == 'J'):
			out.kind = ZONEINFO_RULE_JULIAN
			i = i + 1
		if (!zoneinfo_parse_digits(s, &i, 1, 3, &out.day)): return 0
		if (out.day > 365): return 0
		if ((out.kind == ZONEINFO_RULE_JULIAN) && (out.day < 1)): return 0
	if (s[i] == '/'):
		i = i + 1
		int h = 0
		if (!zoneinfo_parse_hms(s, &i, &out.time, &h)): return 0
		if (h > 167): return 0
	*pos = i
	return 1


# Fills z's after-table fields from a TZ string. 1 on success; 0 on a
# syntax error (z's rule fields are then unspecified).
int zoneinfo_parse_tz_string(zoneinfo* z, char* s):
	int i = 0
	char* std = zoneinfo_parse_abbr(s, &i)
	if (std == 0): return 0
	zoneinfo_free_if(z.std_abbr)
	z.std_abbr = std
	int std_offset = 0
	if (!zoneinfo_parse_offset(s, &i, &std_offset)): return 0
	if (s[i] == 0):
		z.has_rule = 0
		z.after.utc_offset = std_offset
		z.after.dst = 0
		z.after.abbr = std
		return 1
	char* dst = zoneinfo_parse_abbr(s, &i)
	if (dst == 0): return 0
	zoneinfo_free_if(z.dst_abbr)
	z.dst_abbr = dst
	int dst_offset = std_offset + 3600
	if ((s[i] != ',') && (s[i] != 0)):
		if (!zoneinfo_parse_offset(s, &i, &dst_offset)): return 0
	if (s[i] != ','): return 0
	i = i + 1
	if (!zoneinfo_parse_rule_date(s, &i, &z.rule_start)): return 0
	if (s[i] != ','): return 0
	i = i + 1
	if (!zoneinfo_parse_rule_date(s, &i, &z.rule_end)): return 0
	if (s[i] != 0): return 0
	z.has_rule = 1
	z.dst_diff = dst_offset - std_offset
	z.rule_std.utc_offset = std_offset
	z.rule_std.dst = 0
	z.rule_std.abbr = std
	z.rule_dst.utc_offset = dst_offset
	z.rule_dst.dst = z.dst_diff
	z.rule_dst.abbr = dst
	return 1


# Local seconds since Jan 1 00:00 of year at which rule date d switches.
int zoneinfo_rule_seconds(zoneinfo_rule_date d, int year):
	int day = 0
	if (d.kind == ZONEINFO_RULE_MONTH):
		date first = date_new(year, d.month, 1)
		int first_weekday = date_weekday(first)    # Monday = 0
		int month_day = datetime_floor_mod(d.weekday - (first_weekday + 1), 7) + 1
		month_day = month_day + (d.week - 1) * 7
		if (month_day > date_days_in_month(year, d.month)): month_day = month_day - 7
		day = date_day_of_year(date_new(year, d.month, month_day)) - 1
	else if (d.kind == ZONEINFO_RULE_JULIAN):
		day = d.day - 1
		if ((d.day >= 60) && date_is_leap_year(year)): day = day + 1
	else:
		day = d.day
	return day * DATETIME_SECONDS_PER_DAY + d.time


int zoneinfo_in_dst_window(int start, int end, int ts):
	if (start < end): return (start <= ts) && (ts < end)
	return !((end <= ts) && (ts < start))


# Python's _TZStr._get_trans_info: the period at local wall seconds ts
# into year.
zoneinfo_period zoneinfo_rule_local(zoneinfo* z, int year, int ts, int fold):
	int start = zoneinfo_rule_seconds(z.rule_start, year)
	int end = zoneinfo_rule_seconds(z.rule_end, year)
	if ((fold != 0) == (z.dst_diff >= 0)):
		end = end - z.dst_diff
	else:
		start = start + z.dst_diff
	if (zoneinfo_in_dst_window(start, end, ts)): return z.rule_dst
	return z.rule_std


# Python's _TZStr._get_trans_info_fromutc: the period at UTC seconds ts
# into year (the UTC year), and whether the result is a fold.
zoneinfo_period zoneinfo_rule_fromutc(zoneinfo* z, int year, int ts, int* fold):
	int start = zoneinfo_rule_seconds(z.rule_start, year) - z.rule_std.utc_offset
	int end = zoneinfo_rule_seconds(z.rule_end, year) - z.rule_dst.utc_offset
	int isdst = zoneinfo_in_dst_window(start, end, ts)
	int ambig_start = start
	int ambig_end = start - z.dst_diff
	if (z.dst_diff > 0):
		ambig_start = end
		ambig_end = end + z.dst_diff
	*fold = (ambig_start <= ts) && (ts < ambig_end)
	if (isdst): return z.rule_dst
	return z.rule_std


# ---- TZif -------------------------------------------------------------------------

struct zoneinfo_reader:
	char* data
	int length
	int pos
	int ok


int zoneinfo_need(zoneinfo_reader* r, int n):
	if ((n < 0) || (r.pos + n > r.length) || (r.pos + n < r.pos)): r.ok = 0
	return r.ok


int zoneinfo_u8(zoneinfo_reader* r):
	if (!zoneinfo_need(r, 1)): return 0
	int v = r.data[r.pos] & 255
	r.pos = r.pos + 1
	return v


# Big-endian signed 32-bit.
int zoneinfo_i32(zoneinfo_reader* r):
	if (!zoneinfo_need(r, 4)): return 0
	int b0 = zoneinfo_u8(r)
	int b1 = zoneinfo_u8(r)
	int b2 = zoneinfo_u8(r)
	int b3 = zoneinfo_u8(r)
	if (b0 >= 128): b0 = b0 - 256
	return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3


# Big-endian signed 64-bit. On x64 *range is 0. On x86 a value outside
# the word sets *range to -1 (below) or 1 (above) and returns 0.
int zoneinfo_i64(zoneinfo_reader* r, int* range):
	*range = 0
	int hi = zoneinfo_i32(r)
	int lo = zoneinfo_i32(r)
	if (__word_size__ == 8):
		int shift = 32
		return (hi << shift) | (lo & ((1 << shift) - 1))
	if ((hi == 0) && (lo >= 0)): return lo
	if ((hi == 0 - 1) && (lo < 0)): return lo
	if (hi < 0):
		*range = 0 - 1
	else:
		*range = 1
	return 0


struct zoneinfo_header:
	int version
	int isutcnt
	int isstdcnt
	int leapcnt
	int timecnt
	int typecnt
	int charcnt


int zoneinfo_read_header(zoneinfo_reader* r, zoneinfo_header* h):
	if (!zoneinfo_need(r, 44)): return 0
	char* p = &r.data[r.pos]
	if ((p[0] != 'T') || (p[1] != 'Z') || (p[2] != 'i') || (p[3] != 'f')):
		r.ok = 0
		return 0
	int v = p[4] & 255
	if (v == 0):
		h.version = 1
	else if ((v >= '2') && (v <= '9')):
		h.version = v - '0'
	else:
		r.ok = 0
		return 0
	r.pos = r.pos + 20
	h.isutcnt = zoneinfo_i32(r)
	h.isstdcnt = zoneinfo_i32(r)
	h.leapcnt = zoneinfo_i32(r)
	h.timecnt = zoneinfo_i32(r)
	h.typecnt = zoneinfo_i32(r)
	h.charcnt = zoneinfo_i32(r)
	int limit = 1 << 20
	if ((h.isutcnt < 0) || (h.isstdcnt < 0) || (h.leapcnt < 0) || (h.timecnt < 0) || (h.typecnt < 0) || (h.charcnt < 0)): r.ok = 0
	if ((h.isutcnt > limit) || (h.isstdcnt > limit) || (h.leapcnt > limit) || (h.timecnt > limit) || (h.typecnt > 256) || (h.charcnt > limit)): r.ok = 0
	return r.ok


# Python's ZoneInfo._utcoff_to_dstoff: infer each DST type's DST
# adjustment from its neighbors in the transition list.
void zoneinfo_infer_dst(zoneinfo* z):
	int typecnt = z.type_count
	int dst_cnt = 0
	int i = 0
	while (i < typecnt):
		z.type_dst[i] = 0
		if (z.type_isdst[i]): dst_cnt = dst_cnt + 1
		i = i + 1
	int dst_found = 0
	int finished_early = 0
	i = 1
	while (i < z.transition_count):
		if (dst_cnt == dst_found):
			finished_early = 1
			break
		int idx = z.trans_type[i]
		if (z.type_isdst[idx] && (z.type_dst[idx] == 0)):
			int dstoff = 0
			int utcoff = z.type_offset[idx]
			int comp_idx = z.trans_type[i - 1]
			if (!z.type_isdst[comp_idx]): dstoff = utcoff - z.type_offset[comp_idx]
			int skip = 0
			if ((dstoff == 0) && (idx < typecnt - 1) && (i + 1 < z.transition_count)):
				comp_idx = z.trans_type[i + 1]
				if (z.type_isdst[comp_idx]):
					skip = 1
				else:
					dstoff = utcoff - z.type_offset[comp_idx]
			if ((skip == 0) && (dstoff != 0)):
				dst_found = dst_found + 1
				z.type_dst[idx] = dstoff
		i = i + 1
	if (finished_early == 0):
		i = 0
		while (i < typecnt):
			if ((z.type_dst[i] == 0) && z.type_isdst[i]): z.type_dst[i] = 3600
			i = i + 1


# Python's ZoneInfo._ts_to_local: each transition as local wall seconds,
# using the larger of the two offsets around it for fold = 0 and the
# smaller for fold = 1.
void zoneinfo_compute_local(zoneinfo* z):
	int n = z.transition_count
	z.trans_local0 = zoneinfo_int_array(n)
	z.trans_local1 = zoneinfo_int_array(n)
	if (n == 0): return
	int i = 0
	while (i < n):
		int off0 = z.type_offset[0]
		int off1 = z.type_offset[0]
		if (i == 0):
			if (z.type_count > 1): off1 = z.type_offset[z.trans_type[0]]
		else:
			off0 = z.type_offset[z.trans_type[i - 1]]
			off1 = z.type_offset[z.trans_type[i]]
		if (off1 > off0):
			int t = off0
			off0 = off1
			off1 = t
		z.trans_local0[i] = zoneinfo_add_sat(z.trans_utc[i], off0)
		z.trans_local1[i] = zoneinfo_add_sat(z.trans_utc[i], off1)
		i = i + 1


zoneinfo_period zoneinfo_type_period(zoneinfo* z, int idx):
	zoneinfo_period p
	p.utc_offset = z.type_offset[idx]
	p.dst = z.type_dst[idx]
	p.abbr = &z.abbr_chars[z.type_abbr[idx]]
	return p


# Parses a TZif image (RFC 8536 v1, v2 or v3). Returns a new zone, or 0
# when data is not a valid TZif file. key may be 0.
zoneinfo* zoneinfo_from_bytes(char* data, int length, char* key):
	zoneinfo_reader r
	r.data = data
	r.length = length
	r.pos = 0
	r.ok = 1
	zoneinfo_header h
	if (!zoneinfo_read_header(&r, &h)): return 0
	int time_size = 4
	if (h.version >= 2):
		# Skip the v1 block; the 64-bit block after it is authoritative.
		int skip = h.timecnt * 5 + h.typecnt * 6 + h.charcnt + h.leapcnt * 8 + h.isstdcnt + h.isutcnt
		if (!zoneinfo_need(&r, skip)): return 0
		r.pos = r.pos + skip
		if (!zoneinfo_read_header(&r, &h)): return 0
		time_size = 8
	if (!zoneinfo_need(&r, h.timecnt * (time_size + 1) + h.typecnt * 6 + h.charcnt)): return 0
	if (h.typecnt < 1): return 0
	zoneinfo* z = zoneinfo_new_empty()
	z.type_count = h.typecnt
	z.trans_utc = zoneinfo_int_array(h.timecnt)
	z.trans_type = zoneinfo_int_array(h.timecnt)
	# Transition times. On x86, drop those past the word (the footer
	# covers them) and clamp earlier ones to the smallest int.
	int kept = 0
	int i = 0
	while (i < h.timecnt):
		int t = 0
		int range = 0
		if (time_size == 4):
			t = zoneinfo_i32(&r)
		else:
			t = zoneinfo_i64(&r, &range)
		if (range < 0): t = zoneinfo_int_min()
		if (range == 0 - 1 || range == 0):
			if ((kept > 0) && (t < z.trans_utc[kept - 1])): r.ok = 0
			z.trans_utc[kept] = t
			kept = kept + 1
		i = i + 1
	i = 0
	while (i < h.timecnt):
		int idx = zoneinfo_u8(&r)
		if (idx >= h.typecnt): r.ok = 0
		if (i < kept): z.trans_type[i] = idx
		i = i + 1
	z.transition_count = kept
	z.type_offset = zoneinfo_int_array(h.typecnt)
	z.type_dst = zoneinfo_int_array(h.typecnt)
	z.type_isdst = zoneinfo_int_array(h.typecnt)
	z.type_abbr = zoneinfo_int_array(h.typecnt)
	i = 0
	while (i < h.typecnt):
		z.type_offset[i] = zoneinfo_i32(&r)
		z.type_isdst[i] = zoneinfo_u8(&r) != 0
		z.type_abbr[i] = zoneinfo_u8(&r)
		if (!datetime_utc_offset_is_valid(z.type_offset[i])): r.ok = 0
		if (z.type_abbr[i] >= h.charcnt): r.ok = 0
		i = i + 1
	z.abbr_chars = cast(char*, malloc(h.charcnt + 1))
	i = 0
	while (i < h.charcnt):
		z.abbr_chars[i] = zoneinfo_u8(&r)
		i = i + 1
	z.abbr_chars[h.charcnt] = 0
	if (!r.ok):
		zoneinfo_free(z)
		return 0
	# The footer: skip leap seconds and indicators, then "\n<TZ>\n".
	if (h.version >= 2):
		int skip = h.leapcnt * 12 + h.isstdcnt + h.isutcnt
		int ok = zoneinfo_need(&r, skip + 2)
		if (ok):
			r.pos = r.pos + skip
			if (zoneinfo_u8(&r) != 10): ok = 0
		int start = r.pos
		while (ok && (r.pos < r.length) && (r.data[r.pos] != 10)): r.pos = r.pos + 1
		if (r.pos >= r.length): ok = 0
		if (!ok):
			zoneinfo_free(z)
			return 0
		if (r.pos > start):
			int n = r.pos - start
			char* footer = cast(char*, malloc(n + 1))
			int k = 0
			while (k < n):
				footer[k] = r.data[start + k]
				k = k + 1
			footer[n] = 0
			int parsed = zoneinfo_parse_tz_string(z, footer)
			free(footer)
			if (!parsed):
				zoneinfo_free(z)
				return 0
			if (z.has_rule == 0): z.has_rule = 0 - 1   # a fixed footer period
	zoneinfo_infer_dst(z)
	zoneinfo_compute_local(z)
	# Before the table: the first standard-time type (else the first
	# transition's type).
	i = 0
	while (i < z.type_count):
		if (!z.type_isdst[i]):
			z.before_type = i
			break
		i = i + 1
	if ((z.before_type < 0) && (z.transition_count > 0)): z.before_type = z.trans_type[0]
	# After the table without a rule: the footer's fixed period, else
	# the last transition's type (else the last type).
	if (z.has_rule < 0):
		z.has_rule = 0
	else if (z.has_rule == 0):
		if (z.transition_count > 0):
			z.after = zoneinfo_type_period(z, z.trans_type[z.transition_count - 1])
		else:
			z.after = zoneinfo_type_period(z, z.type_count - 1)
	zoneinfo_set_key(z, key)
	return z


# Reads a whole file. Returns a malloc'd buffer and *length, or 0.
char* zoneinfo_read_file(char* path, int* length):
	wstream* in = stream_open_read(path)
	if (in == 0): return 0
	string_builder* contents = string_new()
	io_result r
	int status = stream_read_all_checked(in, contents, &r)
	stream_close(in)
	if (status != IO_OK):
		string_free(contents)
		return 0
	char* data = contents.data
	*length = contents.length
	free(contents)
	return data


# Python's ZoneInfo.from_file: loads a TZif file. key may be 0. Returns
# 0 when the file is missing or invalid.
zoneinfo* zoneinfo_from_file(char* path, char* key):
	int length = 0
	char* data = zoneinfo_read_file(path, &length)
	if (data == 0): return 0
	zoneinfo* z = zoneinfo_from_bytes(data, length, key)
	free(data)
	return z


# A zone defined only by a POSIX TZ string ("EST5EDT,M3.2.0,M11.1.0",
# "<+0530>-5:30"), keyed by the string. 0 on a syntax error.
zoneinfo* zoneinfo_from_tz_string(char* tz):
	zoneinfo* z = zoneinfo_new_empty()
	if (!zoneinfo_parse_tz_string(z, tz)):
		zoneinfo_free(z)
		return 0
	zoneinfo_set_key(z, tz)
	return z


# UTC (key "UTC"); needs no files.
zoneinfo* zoneinfo_utc():
	zoneinfo* z = zoneinfo_from_tz_string(c"UTC0")
	zoneinfo_set_key(z, c"UTC")
	return z


# ---- finding zones ------------------------------------------------------------------

# A relative path with no empty, "." or ".." components (Python's
# _tzpath._validate_tzfile_path, plus no backslashes).
int zoneinfo_key_is_valid(char* key):
	if ((key == 0) || (key[0] == 0) || (key[0] == '/')): return 0
	int i = 0
	int start = 0
	while (1):
		int c = key[i]
		if ((c == '/') || (c == 0)):
			int n = i - start
			if (n == 0): return 0
			if ((n == 1) && (key[start] == '.')): return 0
			if ((n == 2) && (key[start] == '.') && (key[start + 1] == '.')): return 0
			if (c == 0): return 1
			start = i + 1
		if (c == 92): return 0
		i = i + 1
	return 0


# Loads key from one directory. 0 when the key is invalid or the file
# is missing or not TZif.
zoneinfo* zoneinfo_load_from(char* key, char* dir):
	if (!zoneinfo_key_is_valid(key)): return 0
	if ((dir == 0) || (dir[0] == 0)): return 0
	char* path = path_join(dir, key)
	zoneinfo* z = zoneinfo_from_file(path, key)
	free(path)
	return z


# Loads key from $TZDIR when set (non-empty), else from the first of
# /usr/share/zoneinfo, /usr/lib/zoneinfo, /usr/share/lib/zoneinfo and
# /etc/zoneinfo that has it. 0 when not found.
zoneinfo* zoneinfo_load(char* key):
	char* tzdir = env_get(c"TZDIR")
	if ((tzdir != 0) && (tzdir[0] != 0)): return zoneinfo_load_from(key, tzdir)
	zoneinfo* z = zoneinfo_load_from(key, c"/usr/share/zoneinfo")
	if (z == 0): z = zoneinfo_load_from(key, c"/usr/lib/zoneinfo")
	if (z == 0): z = zoneinfo_load_from(key, c"/usr/share/lib/zoneinfo")
	if (z == 0): z = zoneinfo_load_from(key, c"/etc/zoneinfo")
	return z


# The local zone for a given $TZ value (0 = unset), $TZDIR value (0 =
# default search path) and localtime file (normally /etc/localtime),
# resolved like glibc. Never 0: falls back to UTC.
zoneinfo* zoneinfo_local_from(char* tz, char* tzdir, char* localtime_path):
	zoneinfo* z = 0
	if (tz == 0):
		if (localtime_path != 0): z = zoneinfo_from_file(localtime_path, c"localtime")
		if (z == 0): z = zoneinfo_utc()
		return z
	if (tz[0] == ':'): tz = tz + 1
	if (tz[0] == 0): return zoneinfo_utc()
	if (tz[0] == '/'):
		z = zoneinfo_from_file(tz, tz)
	else if ((tzdir != 0) && (tzdir[0] != 0)):
		z = zoneinfo_load_from(tz, tzdir)
	else:
		z = zoneinfo_load(tz)
	if (z == 0): z = zoneinfo_from_tz_string(tz)
	if (z == 0): z = zoneinfo_utc()
	return z


# The process's local zone ($TZ, $TZDIR, /etc/localtime; UTC fallback).
zoneinfo* zoneinfo_local():
	return zoneinfo_local_from(env_get(c"TZ"), env_get(c"TZDIR"), c"/etc/localtime")


# ---- lookups ----------------------------------------------------------------------

# Python's ZoneInfo._find_trans: the period in force at the naive local
# wall time dt (any offset on dt is ignored) with the given fold.
zoneinfo_period zoneinfo_lookup_local(zoneinfo* z, datetime dt, int fold):
	int n = z.transition_count
	int ts = 0
	int fits = zoneinfo_wall_seconds(dt, &ts)
	int* lt = z.trans_local0
	if (fold != 0): lt = z.trans_local1
	if (n > 0):
		int before = dt.d.year < 1970
		if (fits): before = ts < lt[0]
		if (before): return zoneinfo_type_period(z, z.before_type)
	int after = dt.d.year >= 1970
	if (fits && (n > 0)): after = ts > lt[n - 1]
	if ((n == 0) || after):
		if (z.has_rule): return zoneinfo_rule_local(z, dt.d.year, zoneinfo_year_seconds(dt), fold)
		return z.after
	int idx = zoneinfo_bisect_right(lt, n, ts) - 1
	return zoneinfo_type_period(z, z.trans_type[idx])


int zoneinfo_utcoffset(zoneinfo* z, datetime dt, int fold):
	return zoneinfo_lookup_local(z, dt, fold).utc_offset


int zoneinfo_dst(zoneinfo* z, datetime dt, int fold):
	return zoneinfo_lookup_local(z, dt, fold).dst


# The abbreviation (points into the zone; do not free).
char* zoneinfo_tzname(zoneinfo* z, datetime dt, int fold):
	return zoneinfo_lookup_local(z, dt, fold).abbr


# Python's naive.replace(tzinfo=zone): dt's wall-clock fields made aware
# with the offset in force there for the given fold.
datetime zoneinfo_localize(zoneinfo* z, datetime dt, int fold):
	return datetime_with_offset(datetime_naive(dt), zoneinfo_utcoffset(z, dt, fold))


# Whether the naive wall time dt occurs once, twice (ambiguous) or never
# (nonexistent) in z.
int zoneinfo_local_kind(zoneinfo* z, datetime dt):
	int off0 = zoneinfo_utcoffset(z, dt, 0)
	int off1 = zoneinfo_utcoffset(z, dt, 1)
	if (off0 > off1): return ZONEINFO_LOCAL_AMBIGUOUS
	if (off0 < off1): return ZONEINFO_LOCAL_NONEXISTENT
	return ZONEINFO_LOCAL_UNIQUE


# The period in force at the UTC instant whose wall-clock fields are utc
# (Python's fromutc minus the arithmetic); *fold as fromutc reports it.
zoneinfo_period zoneinfo_lookup_utc(zoneinfo* z, datetime utc, int* fold):
	*fold = 0
	int n = z.transition_count
	int ts = 0
	int fits = zoneinfo_wall_seconds(utc, &ts)
	if (n >= 1):
		int before = utc.d.year < 1970
		if (fits): before = ts < z.trans_utc[0]
		if (before): return zoneinfo_type_period(z, z.before_type)
	int after = utc.d.year >= 1970
	if (fits && (n > 0)): after = ts > z.trans_utc[n - 1]
	if (((n == 0) || after) && z.has_rule):
		return zoneinfo_rule_fromutc(z, utc.d.year, zoneinfo_year_seconds(utc), fold)
	if ((n == 0) || !fits): return z.after
	int idx = zoneinfo_bisect_right(z.trans_utc, n, ts)
	zoneinfo_period prev
	zoneinfo_period cur
	if ((n > 1) && (ts >= z.trans_utc[1])):
		prev = zoneinfo_type_period(z, z.trans_type[idx - 2])
		cur = zoneinfo_type_period(z, z.trans_type[idx - 1])
	else if (ts > z.trans_utc[n - 1]):
		prev = zoneinfo_type_period(z, z.trans_type[n - 1])
		cur = z.after
	else:
		prev = zoneinfo_type_period(z, z.before_type)
		cur = zoneinfo_type_period(z, z.trans_type[0])
	# Python's shift > ts - t, without overflow when t is clamped on x86.
	*fold = zoneinfo_add_sat(z.trans_utc[idx - 1], prev.utc_offset - cur.utc_offset) > ts
	return cur


# Python's zone.fromutc / dt.astimezone(zone): the local time of the
# instant dt (aware at any offset, or naive and read as UTC), as an
# aware datetime at the local offset. *fold (when fold is not 0) is 1
# for the second occurrence of an ambiguous wall time.
datetime zoneinfo_fromutc(zoneinfo* z, datetime dt, int* fold):
	datetime utc = dt
	if (utc.has_offset): utc = datetime_to_utc(utc)
	utc = datetime_naive(utc)
	int f = 0
	zoneinfo_period p = zoneinfo_lookup_utc(z, utc, &f)
	if (fold != 0): *fold = f
	return datetime_with_offset(datetime_add(utc, duration_from_seconds(p.utc_offset)), p.utc_offset)


# The local aware datetime of a Unix timestamp in zone (Python's
# datetime.fromtimestamp(ts, zone)).
datetime datetime_from_unix_zone(int timestamp, zoneinfo* zone):
	return zoneinfo_fromutc(zone, datetime_from_unix(timestamp), 0)


# The UTC offset in force at a Unix timestamp.
int zoneinfo_offset_at(zoneinfo* z, int timestamp):
	int fold = 0
	return zoneinfo_lookup_utc(z, datetime_naive(datetime_from_unix(timestamp)), &fold).utc_offset


# The current time in zone, aware at its offset.
datetime datetime_now_zone(zoneinfo* z):
	return zoneinfo_fromutc(z, datetime_now_utc(), 0)


# The current local time (zoneinfo_local's zone), aware at its offset.
datetime datetime_now_local():
	zoneinfo* z = zoneinfo_local()
	datetime now = datetime_now_zone(z)
	zoneinfo_free(z)
	return now
