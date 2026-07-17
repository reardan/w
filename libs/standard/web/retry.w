# Retry policy for the pure-W HTTPS stack (plan 11 phase 3, issue #202,
# part of #155). Decides whether a failed http_request should be retried
# and how long to wait, honoring a server-provided Retry-After header in
# both its delta-seconds and HTTP-date forms and otherwise backing off
# exponentially with optional full jitter.
#
# Public API:
#   retry_policy* retry_policy_default()      caller frees with retry_policy_free
#   void          retry_policy_free(retry_policy* p)
#   int   retry_should_retry(retry_policy* p, int attempt, http_response* resp)
#   int   retry_delay_ms(retry_policy* p, int attempt, http_response* resp)
#   int   retry_delay_ms_at(retry_policy* p, int attempt, http_response* resp, int now)
#   int   retry_backoff_ms(retry_policy* p, int attempt)
#   int   retry_retryable_default(int status)   the default status predicate
#   int   retry_http_date_to_unix(char* text)   HTTP-date -> unix seconds, or -1
#   int   retry_after_seconds(char* value, int now)  Retry-After -> seconds, or -1
#
# attempt is the 0-based index of the attempt that just completed (0 for
# the first). retry_should_retry allows another attempt while
# attempt+1 < max_attempts and either the transport failed (resp.error
# set) or the status is retryable. retry_delay_ms uses the process wall
# clock for HTTP-date deltas; retry_delay_ms_at takes an injectable now
# (unix seconds) so the HTTP-date path is deterministically testable.
import lib.lib
import lib.time
import libs.standard.web.http_client
import libs.standard.crypto.random


# A status-retryability predicate: status code -> 1 (retry) or 0.
type retry_pred = fn(int) -> int


# Retry configuration. retryable is a function pointer (defaulting to
# retry_retryable_default) so callers can widen or narrow the retryable
# status set without touching this module.
struct retry_policy:
	int max_attempts
	int base_delay_ms
	int max_delay_ms
	int jitter
	retry_pred* retryable


# Retryable when the server asks to slow down (429) or is transiently
# unhealthy (any 5xx, which includes 529 "site overloaded").
int retry_retryable_default(int status):
	if (status == 429):
		return 1
	if ((status >= 500) && (status <= 599)):
		return 1
	return 0


# Sensible defaults: up to 5 attempts, 1s base doubling to a 32s cap,
# with full jitter enabled.
retry_policy* retry_policy_default():
	retry_policy* p = new retry_policy()
	p.max_attempts = 5
	p.base_delay_ms = 1000
	p.max_delay_ms = 32000
	p.jitter = 1
	p.retryable = retry_retryable_default
	return p


void retry_policy_free(retry_policy* p):
	if (p == 0):
		return
	free(p)


# Whether another attempt should follow this one: attempts remain AND
# (the transport failed OR the response status is retryable).
int retry_should_retry(retry_policy* p, int attempt, http_response* resp):
	if (p == 0):
		return 0
	if (attempt + 1 >= p.max_attempts):
		return 0
	if (resp == 0):
		return 1
	if (resp.error != 0):
		return 1
	return p.retryable(resp.status)


/* Exponential backoff */

# base_delay_ms * 2^attempt, capped at max_delay_ms. Doubling stops as
# soon as the cap is reached, so the multiply never overflows.
int retry_backoff_ms(retry_policy* p, int attempt):
	int delay = p.base_delay_ms
	if (delay < 0):
		delay = 0
	int i = 0
	while (i < attempt):
		if (delay >= p.max_delay_ms):
			return p.max_delay_ms
		delay = delay * 2
		i = i + 1
	if (delay > p.max_delay_ms):
		return p.max_delay_ms
	if (delay < 0):
		return p.max_delay_ms
	return delay


# A uniformly-distributed 31-bit non-negative int from the CSPRNG (0 on
# a random failure, which only shortens a single backoff wait).
int retry_random_u31():
	char* buf = malloc(4)
	int ok = random_bytes(buf, 4)
	int v = 0
	if (ok != 0):
		v = (buf[0] & 255) | ((buf[1] & 255) << 8) | ((buf[2] & 255) << 16) | ((buf[3] & 127) << 24)
	free(buf)
	return v


# Full jitter: a uniform draw from [0, computed].
int retry_full_jitter(int computed):
	if (computed <= 0):
		return 0
	int r = retry_random_u31()
	return r % (computed + 1)


/* Retry-After parsing */

int retry_is_digit(int c):
	if ((c >= '0') && (c <= '9')):
		return 1
	return 0


int retry_is_alpha(int c):
	if ((c >= 'a') && (c <= 'z')):
		return 1
	if ((c >= 'A') && (c <= 'Z')):
		return 1
	return 0


int retry_lower(int c):
	if ((c >= 'A') && (c <= 'Z')):
		return c + 32
	return c


void retry_skip_ws(char* s, int* pos):
	int p = *pos
	while ((s[p] == ' ') || (s[p] == 9)):
		p = p + 1
	*pos = p


# Reads a run of decimal digits at *pos into *out; returns the digit
# count (0 when none) and advances *pos past them.
int retry_read_uint(char* s, int* pos, int* out):
	int p = *pos
	int start = p
	int v = 0
	while (retry_is_digit(s[p] & 255) != 0):
		if (v > 200000000):
			v = 2000000000
		else:
			v = v * 10 + ((s[p] & 255) - '0')
		p = p + 1
	*out = v
	*pos = p
	return p - start


# Maps a 3-letter English month abbreviation at s[at..at+2] to 1..12, or
# -1 when it is not a month name.
int retry_month_index(char* s, int at):
	int a = retry_lower(s[at] & 255)
	int b = retry_lower(s[at + 1] & 255)
	int c = retry_lower(s[at + 2] & 255)
	if ((a == 'j') && (b == 'a') && (c == 'n')):
		return 1
	if ((a == 'f') && (b == 'e') && (c == 'b')):
		return 2
	if ((a == 'm') && (b == 'a') && (c == 'r')):
		return 3
	if ((a == 'a') && (b == 'p') && (c == 'r')):
		return 4
	if ((a == 'm') && (b == 'a') && (c == 'y')):
		return 5
	if ((a == 'j') && (b == 'u') && (c == 'n')):
		return 6
	if ((a == 'j') && (b == 'u') && (c == 'l')):
		return 7
	if ((a == 'a') && (b == 'u') && (c == 'g')):
		return 8
	if ((a == 's') && (b == 'e') && (c == 'p')):
		return 9
	if ((a == 'o') && (b == 'c') && (c == 't')):
		return 10
	if ((a == 'n') && (b == 'o') && (c == 'v')):
		return 11
	if ((a == 'd') && (b == 'e') && (c == 'c')):
		return 12
	return (-1)


# Reads a 3-letter month at *pos, advancing past it. Returns 1..12 or -1.
int retry_read_month(char* s, int* pos):
	int p = *pos
	if (retry_is_alpha(s[p] & 255) == 0):
		return (-1)
	if (retry_is_alpha(s[p + 1] & 255) == 0):
		return (-1)
	if (retry_is_alpha(s[p + 2] & 255) == 0):
		return (-1)
	int m = retry_month_index(s, p)
	if (m < 0):
		return (-1)
	*pos = p + 3
	return m


# Reads "HH:MM:SS" at *pos into the out params. Returns 1 on success.
int retry_read_time(char* s, int* pos, int* hh, int* mm, int* ss):
	int p = *pos
	int h = 0
	int m = 0
	int sec = 0
	if (retry_read_uint(s, &p, &h) == 0):
		return 0
	if (s[p] != ':'):
		return 0
	p = p + 1
	if (retry_read_uint(s, &p, &m) == 0):
		return 0
	if (s[p] != ':'):
		return 0
	p = p + 1
	if (retry_read_uint(s, &p, &sec) == 0):
		return 0
	*hh = h
	*mm = m
	*ss = sec
	*pos = p
	return 1


# Days from the Unix epoch (1970-01-01) to a valid Gregorian y/m/d, by
# Howard Hinnant's civil-to-days formula. Correct for the positive years
# HTTP dates carry.
int retry_days_from_civil(int y, int m, int d):
	if (m <= 2):
		y = y - 1
	int era = y / 400
	int yoe = y - era * 400
	int mp = m + 9
	if (m > 2):
		mp = m - 3
	int doy = (153 * mp + 2) / 5 + d - 1
	int doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468


# Assembles validated fields into Unix seconds, or -1 when out of range
# or before the epoch.
int retry_fields_to_unix(int year, int month, int day, int hh, int mm, int ss):
	if ((month < 1) || (month > 12)):
		return (-1)
	if ((day < 1) || (day > 31)):
		return (-1)
	if ((hh < 0) || (hh > 23)):
		return (-1)
	if ((mm < 0) || (mm > 59)):
		return (-1)
	# Allow a leap second (60) but fold it back to 59.
	if ((ss < 0) || (ss > 60)):
		return (-1)
	if (ss == 60):
		ss = 59
	if (year < 1970):
		return (-1)
	int days = retry_days_from_civil(year, month, day)
	if (days < 0):
		return (-1)
	return days * 86400 + hh * 3600 + mm * 60 + ss


# Parses an HTTP-date to Unix seconds, or -1 on failure. Handles the
# preferred IMF-fixdate ("Sun, 06 Nov 1994 08:49:37 GMT") plus the two
# obsolete formats: RFC 850 ("Sunday, 06-Nov-94 08:49:37 GMT") and
# asctime ("Sun Nov  6 08:49:37 1994").
int retry_http_date_to_unix(char* text):
	if (text == 0):
		return (-1)
	int pos = 0
	retry_skip_ws(text, &pos)
	# Skip the leading weekday name.
	while (retry_is_alpha(text[pos] & 255) != 0):
		pos = pos + 1
	if (text[pos] == ','):
		pos = pos + 1
	retry_skip_ws(text, &pos)
	int day = 0
	int month = 0
	int year = 0
	int hh = 0
	int mm = 0
	int ss = 0
	if (retry_is_alpha(text[pos] & 255) != 0):
		# asctime: month day time year (no comma after the weekday).
		month = retry_read_month(text, &pos)
		if (month < 0):
			return (-1)
		retry_skip_ws(text, &pos)
		if (retry_read_uint(text, &pos, &day) == 0):
			return (-1)
		retry_skip_ws(text, &pos)
		if (retry_read_time(text, &pos, &hh, &mm, &ss) == 0):
			return (-1)
		retry_skip_ws(text, &pos)
		if (retry_read_uint(text, &pos, &year) == 0):
			return (-1)
	else:
		# IMF-fixdate or RFC 850: day sep month sep year time.
		if (retry_read_uint(text, &pos, &day) == 0):
			return (-1)
		if ((text[pos] != '-') && (text[pos] != ' ')):
			return (-1)
		pos = pos + 1
		month = retry_read_month(text, &pos)
		if (month < 0):
			return (-1)
		if ((text[pos] != '-') && (text[pos] != ' ')):
			return (-1)
		pos = pos + 1
		int ny = retry_read_uint(text, &pos, &year)
		if (ny == 0):
			return (-1)
		if (ny == 2):
			# RFC 850 two-digit year: 70..99 -> 1900s, 00..69 -> 2000s.
			if (year < 70):
				year = year + 2000
			else:
				year = year + 1900
		retry_skip_ws(text, &pos)
		if (retry_read_time(text, &pos, &hh, &mm, &ss) == 0):
			return (-1)
	return retry_fields_to_unix(year, month, day, hh, mm, ss)


# Interprets a Retry-After value against now (unix seconds): a bare
# delta-seconds count, or an HTTP-date whose delta from now is returned
# (clamped to >= 0). Returns seconds to wait, or -1 when unparseable.
int retry_after_seconds(char* value, int now):
	if (value == 0):
		return (-1)
	int pos = 0
	retry_skip_ws(value, &pos)
	int start = pos
	# A run of digits followed only by trailing whitespace is a
	# delta-seconds value.
	int p = pos
	while (retry_is_digit(value[p] & 255) != 0):
		p = p + 1
	int all_digits = 0
	if (p > start):
		int q = p
		while ((value[q] == ' ') || (value[q] == 9)):
			q = q + 1
		if (value[q] == 0):
			all_digits = 1
	if (all_digits != 0):
		int secs = 0
		retry_read_uint(value, &start, &secs)
		return secs
	int when = retry_http_date_to_unix(value)
	if (when < 0):
		return (-1)
	int delta = when - now
	if (delta < 0):
		delta = 0
	return delta


/* Delay computation */

# Converts a seconds count to a clamped millisecond delay, guarding the
# multiply against overflow before applying the max_delay_ms cap.
int retry_seconds_to_delay_ms(retry_policy* p, int secs):
	if (secs < 0):
		return 0
	if (secs > 2000000):
		return p.max_delay_ms
	int ms = secs * 1000
	if (ms > p.max_delay_ms):
		return p.max_delay_ms
	return ms


# Delay before the next attempt, using an injectable now (unix seconds)
# for any Retry-After HTTP-date. A present, parseable Retry-After wins
# (clamped to max_delay_ms, no jitter); otherwise exponential backoff
# with full jitter when the policy enables it.
int retry_delay_ms_at(retry_policy* p, int attempt, http_response* resp, int now):
	if (p == 0):
		return 0
	if (resp != 0):
		char* ra = http_response_header(resp, c"retry-after")
		if (ra != 0):
			int secs = retry_after_seconds(ra, now)
			if (secs >= 0):
				return retry_seconds_to_delay_ms(p, secs)
	int computed = retry_backoff_ms(p, attempt)
	if (p.jitter != 0):
		return retry_full_jitter(computed)
	return computed


# Delay before the next attempt using the process wall clock for any
# Retry-After HTTP-date.
int retry_delay_ms(retry_policy* p, int attempt, http_response* resp):
	return retry_delay_ms_at(p, attempt, resp, time_now())
