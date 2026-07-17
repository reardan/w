# Server-Sent Events reader for the pure-W HTTPS stack (plan 11 phase
# 3, issue #202, part of #155). A WHATWG EventSource line parser that
# consumes an http_stream (libs/standard/web/http_client.w) byte by
# byte and surfaces dispatched events.
#
# Public API:
#   sse_reader* sse_open(http_stream* s)       never returns 0
#   sse_event*  sse_next(sse_reader* r)         next event, or 0 at end
#   int         sse_reader_error(sse_reader* r) 0 = clean EOF, else code
#   int         sse_reader_retry_ms(sse_reader* r)
#   void        sse_reader_free(sse_reader* r)
#   void        sse_event_free(sse_event* ev)
#   int         sse_error_none() / sse_error_stream() / sse_error_overflow()
#
# Ownership: sse_open BORROWS the http_stream. It never closes or frees
# it; the caller still owns the stream and must http_stream_close it
# after sse_reader_free. A dispatched sse_event is owned by the caller
# and released with sse_event_free.
#
# Parsing follows the WHATWG "interpreting an event stream" algorithm:
#   - a leading UTF-8 BOM is stripped once at the very start;
#   - lines end with CR, LF, or CRLF (all buffered across reads);
#   - "field:value" with a single optional leading space stripped from
#     the value; a line with no colon is a field with an empty value;
#   - "event" sets the event type, "data" lines are joined with LF,
#     "id" updates the last event id (ignored when it contains a NUL),
#     "retry" (digits only) updates the reconnect delay;
#   - a line beginning with ':' is a comment / keep-alive and ignored;
#   - unknown fields are ignored;
#   - a blank line dispatches the accumulated event, unless the data
#     buffer is empty (then the buffers are reset and nothing fires).
# The line buffer and the accumulated data buffer are each hard-capped;
# exceeding a cap fails closed with sse_error_overflow.
import lib.lib
import structures.string
import libs.standard.web.http_client


# One dispatched event. event defaults to "message". data is the joined
# data lines with the single trailing LF removed. id is the last-seen
# event id (0 when none has been seen). retry_ms mirrors the reader's
# current reconnect delay (0 when the stream never sent one). All owned
# by the event; released by sse_event_free.
struct sse_event:
	char* event
	char* data
	char* id
	int retry_ms


# Streaming parser state. buf is the raw read buffer refilled from the
# stream; line accumulates the current (unterminated) line; data and
# event_type accumulate the event under construction; last_id and
# retry_ms persist across events per the spec.
struct sse_reader:
	http_stream* stream
	char* buf
	int buf_cap
	int buf_pos
	int buf_len
	int eof
	int error
	int started
	int pending_cr
	string_builder* line
	string_builder* data
	string_builder* event_type
	char* last_id
	int retry_ms


/* Error codes reported by sse_reader_error */

int sse_error_none():
	return 0


# The underlying http_stream_read returned an error.
int sse_error_stream():
	return 1


# A single line, or the accumulated data buffer, exceeded its cap.
int sse_error_overflow():
	return 2


# Cap on one line (bytes between terminators).
int sse_max_line():
	return 1048576


# Cap on the accumulated data buffer of one event.
int sse_max_event():
	return 8388608


# Size of the raw read buffer pulled from the stream.
int sse_buf_cap():
	return 4096


/* Construction / teardown */

# Wraps a stream in a fresh reader. The stream is borrowed, never
# closed here. Never returns 0.
sse_reader* sse_open(http_stream* s):
	sse_reader* r = new sse_reader()
	r.stream = s
	r.buf_cap = sse_buf_cap()
	r.buf = malloc(r.buf_cap)
	r.buf_pos = 0
	r.buf_len = 0
	r.eof = 0
	r.error = 0
	r.started = 0
	r.pending_cr = 0
	r.line = string_new()
	r.data = string_new()
	r.event_type = string_new()
	r.last_id = 0
	r.retry_ms = 0
	return r


# Frees the reader and its buffers. Does not touch the borrowed stream.
void sse_reader_free(sse_reader* r):
	if (r == 0):
		return
	free(r.buf)
	string_free(r.line)
	string_free(r.data)
	string_free(r.event_type)
	if (r.last_id != 0):
		free(r.last_id)
	free(r)


# 0 after a clean end-of-stream, otherwise an sse_error_* code.
int sse_reader_error(sse_reader* r):
	if (r == 0):
		return sse_error_none()
	return r.error


# The reader's current reconnect delay in milliseconds (0 when unset).
int sse_reader_retry_ms(sse_reader* r):
	if (r == 0):
		return 0
	return r.retry_ms


void sse_event_free(sse_event* ev):
	if (ev == 0):
		return
	if (ev.event != 0):
		free(ev.event)
	if (ev.data != 0):
		free(ev.data)
	if (ev.id != 0):
		free(ev.id)
	free(ev)


/* Small byte-range helpers (byte-accurate, embedded NUL aware) */

# Fresh NUL-terminated copy of base[start..end). Embedded NULs are
# preserved in the copy (though a C-string consumer stops at the first).
char* sse_range_clone(char* base, int start, int end):
	int n = end - start
	if (n < 0):
		n = 0
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = base[start + i]
		i = i + 1
	out[n] = 0
	return out


int sse_range_has_nul(char* base, int start, int end):
	int i = start
	while (i < end):
		if ((base[i] & 255) == 0):
			return 1
		i = i + 1
	return 0


# Whether base[0..name_end) equals the C-string target (case-sensitive,
# SSE field names are exact).
int sse_name_eq(char* base, int name_end, char* target):
	int i = 0
	while (i < name_end):
		if (target[i] == 0):
			return 0
		if ((base[i] & 255) != (target[i] & 255)):
			return 0
		i = i + 1
	return target[i] == 0


int sse_range_all_digits(char* base, int start, int end):
	if (end <= start):
		return 0
	int i = start
	while (i < end):
		int c = base[i] & 255
		if ((c < '0') || (c > '9')):
			return 0
		i = i + 1
	return 1


# Parses base[start..end) as a non-negative decimal, clamping absurd
# values so the multiply cannot overflow.
int sse_range_atoi(char* base, int start, int end):
	int v = 0
	int i = start
	while (i < end):
		if (v > 200000000):
			return 2000000000
		v = v * 10 + (base[i] - '0')
		i = i + 1
	return v


/* Field handling */

# Applies one parsed field to the event under construction. name is
# base[0..name_end); the value is base[vstart..vend).
void sse_apply_field(sse_reader* r, char* base, int name_end, int vstart, int vend):
	if (sse_name_eq(base, name_end, c"event") != 0):
		string_clear(r.event_type)
		string_append_bytes(r.event_type, base + vstart, vend - vstart)
	else if (sse_name_eq(base, name_end, c"data") != 0):
		if (r.data.length + (vend - vstart) > sse_max_event()):
			r.error = sse_error_overflow()
		else:
			string_append_bytes(r.data, base + vstart, vend - vstart)
			string_append_char(r.data, 10)
	else if (sse_name_eq(base, name_end, c"id") != 0):
		# Ignore an id that contains a NUL (WHATWG rule).
		if (sse_range_has_nul(base, vstart, vend) == 0):
			if (r.last_id != 0):
				free(r.last_id)
			r.last_id = sse_range_clone(base, vstart, vend)
	else if (sse_name_eq(base, name_end, c"retry") != 0):
		# Digits only; anything else leaves the delay unchanged.
		if (sse_range_all_digits(base, vstart, vend) != 0):
			r.retry_ms = sse_range_atoi(base, vstart, vend)


# Parses the current (non-empty) line into a field and applies it.
# Comment lines (leading ':') are ignored.
void sse_process_field(sse_reader* r):
	char* line = r.line.data
	int len = r.line.length
	if ((line[0] & 255) == ':'):
		return
	int colon = 0
	int found = 0
	while ((colon < len) && (found == 0)):
		if ((line[colon] & 255) == ':'):
			found = 1
		else:
			colon = colon + 1
	int name_end = colon
	int vstart = len
	int vend = len
	if (found != 0):
		vstart = colon + 1
		if (vstart < len):
			if ((line[vstart] & 255) == ' '):
				vstart = vstart + 1
		vend = len
	sse_apply_field(r, line, name_end, vstart, vend)


# Builds the event from the accumulated buffers on a blank line, or 0
# when the data buffer is empty (buffers are reset either way).
sse_event* sse_dispatch(sse_reader* r):
	if (r.data.length == 0):
		string_clear(r.event_type)
		return 0
	int dlen = r.data.length
	# Strip the single trailing LF added after the last data line.
	if ((r.data.data[dlen - 1] & 255) == 10):
		dlen = dlen - 1
	sse_event* ev = new sse_event()
	if (r.event_type.length > 0):
		ev.event = sse_range_clone(r.event_type.data, 0, r.event_type.length)
	else:
		ev.event = strclone(c"message")
	ev.data = sse_range_clone(r.data.data, 0, dlen)
	if (r.last_id != 0):
		ev.id = strclone(r.last_id)
	else:
		ev.id = 0
	ev.retry_ms = r.retry_ms
	string_clear(r.event_type)
	string_clear(r.data)
	return ev


# Called when a line terminator completes r.line. Returns a dispatched
# event (blank line, non-empty data) or 0.
sse_event* sse_end_line(sse_reader* r):
	if (r.line.length == 0):
		return sse_dispatch(r)
	sse_process_field(r)
	string_clear(r.line)
	return 0


/* Reading */

# Ensures r.buf holds unread bytes. Returns 1 when bytes are available,
# 0 at clean end-of-stream, -1 on a stream error (r.error set).
int sse_refill(sse_reader* r):
	if (r.error != 0):
		return (-1)
	while (r.buf_pos >= r.buf_len):
		if (r.eof != 0):
			return 0
		if (r.started == 0):
			# First fill: gather at least 3 bytes (or hit EOF) so a
			# leading BOM can be recognised even if the initial read is
			# short.
			r.buf_pos = 0
			r.buf_len = 0
			while ((r.buf_len < 3) && (r.eof == 0) && (r.error == 0)):
				int got = http_stream_read(r.stream, r.buf + r.buf_len, r.buf_cap - r.buf_len)
				if (got > 0):
					r.buf_len = r.buf_len + got
				else if (got == 0):
					r.eof = 1
				else:
					r.error = sse_error_stream()
			r.started = 1
			if (r.error != 0):
				return (-1)
			if (r.buf_len >= 3):
				if ((r.buf[0] & 255) == 239):
					if ((r.buf[1] & 255) == 187):
						if ((r.buf[2] & 255) == 191):
							r.buf_pos = 3
		else:
			r.buf_pos = 0
			r.buf_len = 0
			int got = http_stream_read(r.stream, r.buf, r.buf_cap)
			if (got > 0):
				r.buf_len = got
			else if (got == 0):
				r.eof = 1
			else:
				r.error = sse_error_stream()
				return (-1)
	return 1


# Next dispatched event, or 0 at end-of-stream or on error. Use
# sse_reader_error to tell a clean EOF (0) from a failure. The returned
# event is owned by the caller (sse_event_free).
sse_event* sse_next(sse_reader* r):
	if (r == 0):
		return 0
	if (r.error != 0):
		return 0
	while (1):
		int state = sse_refill(r)
		if (state < 0):
			return 0
		if (state == 0):
			# End of stream: any half-built event is discarded per spec.
			return 0
		while (r.buf_pos < r.buf_len):
			int b = r.buf[r.buf_pos] & 255
			r.buf_pos = r.buf_pos + 1
			if (b == 13):
				r.pending_cr = 1
				sse_event* ev = sse_end_line(r)
				if (r.error != 0):
					return 0
				if (ev != 0):
					return ev
			else if (b == 10):
				if (r.pending_cr != 0):
					r.pending_cr = 0
				else:
					sse_event* ev = sse_end_line(r)
					if (r.error != 0):
						return 0
					if (ev != 0):
						return ev
			else:
				r.pending_cr = 0
				if (r.line.length >= sse_max_line()):
					r.error = sse_error_overflow()
					return 0
				string_append_char(r.line, b)
	return 0
