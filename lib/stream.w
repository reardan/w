/*
Buffered stream IO over raw file descriptors.

A wstream wraps a file descriptor with a byte buffer so callers stop paying
one syscall per byte (the getchar/putc pattern). A stream is either a reader
or a writer, never both on the same wstream. Writers buffer until the buffer
fills, stream_flush() is called, or the stream is closed/freed.

Errors (lib/io.w statuses): every descriptor operation goes through the
checked io_* loops (EINTR retried, partial writes continued, zero
progress an error). The first failure latches a sticky error on the
stream, queryable with stream_error()/stream_error_errno():
- Writers keep the unwritten suffix of a failed flush at the front of
  the buffer and refuse new bytes until stream_clear_error() (which keeps
  the retained bytes, so the next flush retries them) or close. That
  includes IO_WOULD_BLOCK on a non-blocking descriptor: await
  writability, clear, flush again.
- Readers record a failed read as an error, never as end of input:
  s.eof means the descriptor really reported EOF. Reads return -1 / 0 /
  short counts exactly as at EOF, so callers that care check
  stream_error() (or use the *_checked variants) to tell them apart.
Flush (hand bytes to the OS), sync (stream_sync: flush + fsync, the
durability barrier) and close (stream_close_checked: flush + close,
report errors, NOT a sync) are distinct. A failed close is never
retried: the descriptor is released either way. The legacy void calls
delegate to the checked ones and leave the sticky error queryable (until
the stream is freed).

Also provides stdin/stdout/stderr singletons for line-oriented tools and
Content-Length framing (the LSP/MCP wire format) for stdio protocol servers.

Design notes: docs/projects/streams.md
*/
import lib.lib
import lib.io
import structures.string


struct wstream:
	int fd
	char* buffer
	int capacity
	int position   # next unread byte (readers only)
	int limit      # end of buffered data (readers) / pending bytes (writers)
	int eof        # the descriptor reported end of input (readers)
	int writable
	int error_status   # sticky IO_* status of the first failure, IO_OK when none
	int error_errno    # its positive platform errno (0 when none applies)


const int STREAM_DEFAULT_CAPACITY = 4096


wstream* stream_reader_sized(int fd, int capacity):
	if (capacity < 1): capacity = 1
	wstream* s = new wstream()
	s.fd = fd
	s.buffer = cast(char*, malloc(capacity))
	s.capacity = capacity
	s.position = 0
	s.limit = 0
	s.eof = 0
	s.writable = 0
	s.error_status = IO_OK
	s.error_errno = 0
	return s


wstream* stream_reader(int fd):
	return stream_reader_sized(fd, STREAM_DEFAULT_CAPACITY)


wstream* stream_writer_sized(int fd, int capacity):
	wstream* s = stream_reader_sized(fd, capacity)
	s.writable = 1
	return s


wstream* stream_writer(int fd):
	return stream_writer_sized(fd, STREAM_DEFAULT_CAPACITY)


# Returns 0 when the file cannot be opened for reading.
wstream* stream_open_read(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	return stream_reader(fd)


# Creates or truncates the file. Returns 0 when the file cannot be opened.
wstream* stream_open_write(char* path):
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 493 = rwxr-xr-x
	int fd = open(path, 577, 493)
	if (fd < 0): return 0
	return stream_writer(fd)


/* Sticky errors */

# The latched IO_* status (IO_OK when the stream has not failed).
int stream_error(wstream* s):
	return s.error_status


# The latched failure's positive errno (0 when none applies).
int stream_error_errno(wstream* s):
	return s.error_errno


# Latches the first failure; later ones keep the original cause.
int stream_latch_error(wstream* s, int status, int native_error):
	if (s.error_status == IO_OK):
		s.error_status = status
		s.error_errno = native_error
	return s.error_status


# Explicit recovery: forgets the latched error. A writer keeps its
# retained unwritten bytes (the next flush retries them; see
# stream_discard_pending to drop them instead); a reader may read again.
void stream_clear_error(wstream* s):
	s.error_status = IO_OK
	s.error_errno = 0


# Bytes a writer holds that have not reached the descriptor yet.
int stream_pending(wstream* s):
	if (s.writable): return s.limit
	return 0


# Drops a writer's buffered bytes without writing them (e.g. after
# giving up on a failed destination). Returns how many were dropped.
int stream_discard_pending(wstream* s):
	int dropped = stream_pending(s)
	if (s.writable): s.limit = 0
	return dropped


# Fills r with the latched error (transferred 0) and returns it.
int stream_report_error(wstream* s, io_result* r):
	return io_result_set(r, 0, s.error_status, s.error_errno)


/* Flush, sync, close */

# Writes the buffered bytes to the descriptor. transferred is the bytes
# written by this call. On failure the unwritten suffix moves to the
# buffer front and stays pending, and the error latches. A stream that
# already holds an error reports it without writing.
int stream_flush_checked(wstream* s, io_result* r):
	if (s.error_status != IO_OK): return stream_report_error(s, r)
	if ((s.writable == 0) || (s.limit <= 0)): return io_result_set(r, 0, IO_OK, 0)
	io_result step
	int status = io_write_all(s.fd, s.buffer, s.limit, &step)
	int written = step.transferred
	if (status == IO_OK):
		s.limit = 0
		return io_result_set(r, written, IO_OK, 0)
	if (written > 0):
		int remaining = s.limit - written
		for i in range(remaining): s.buffer[i] = s.buffer[written + i]
		s.limit = remaining
	stream_latch_error(s, status, step.native_error)
	return io_result_set(r, written, status, step.native_error)


void stream_flush(wstream* s):
	io_result r
	stream_flush_checked(s, &r)


# The durability barrier: flush, then fsync the descriptor. A failed
# fsync latches like a failed write (after a failed fsync Linux may have
# dropped the dirty pages, so a later successful one proves nothing).
# transferred is the bytes the flush wrote.
int stream_sync(wstream* s, io_result* r):
	int status = stream_flush_checked(s, r)
	if (status != IO_OK): return status
	int written = r.transferred
	int ret = fsync(s.fd)
	if (ret < 0):
		io_result_from_syscall(r, ret)
		stream_latch_error(s, r.status, r.native_error)
		r.transferred = written
		return r.status
	return io_result_set(r, written, IO_OK, 0)


# Flush and release the stream without closing the descriptor
# (for stdin/stdout/stderr). Use stream_flush_checked first to see
# whether the bytes arrived.
void stream_free(wstream* s):
	stream_flush(s)
	free(s.buffer)
	free(s)


# Flushes, closes the descriptor and frees the stream, reporting the
# first failure: a latched or flush error (transferred = bytes the flush
# wrote) wins over a close error. Not a sync -- use stream_sync first for
# durability. The descriptor is closed exactly once, even on failure.
int stream_close_checked(wstream* s, io_result* r):
	int fd = s.fd
	stream_flush_checked(s, r)
	free(s.buffer)
	free(s)
	io_result closed
	io_close(fd, &closed)
	if (r.status != IO_OK): return r.status
	if (closed.status != IO_OK):
		r.status = closed.status
		r.native_error = closed.native_error
	return r.status


void stream_close(wstream* s):
	io_result r
	stream_close_checked(s, &r)


/* Reader operations */

# Refill the buffer from the descriptor. End of input sets s.eof; a
# failed read latches the error instead (s.eof stays 0). Either way the
# buffer comes back empty, and nothing more is read until recovery.
void stream_fill(wstream* s):
	if (s.eof || (s.error_status != IO_OK)): return
	s.position = 0
	s.limit = 0
	io_result r
	int status = io_read_some(s.fd, s.buffer, s.capacity, &r)
	if (status == IO_EOF):
		s.eof = 1
		return
	if (status != IO_OK):
		stream_latch_error(s, status, r.native_error)
		return
	s.limit = r.transferred


# Returns the next byte (0..255) without consuming it, or -1 at end of
# input. s.buffer is char*, a sign-extending load, so the raw value must
# be masked: otherwise bytes 0x80-0xFF come back as negative ints, and
# 0xFF in particular collides with the -1 EOF sentinel.
int stream_peek_byte(wstream* s):
	if (s.position >= s.limit): stream_fill(s)
	if (s.position >= s.limit): return (-1)
	return s.buffer[s.position] & 255


# Returns the next byte, or -1 at end of input.
int stream_read_byte(wstream* s):
	int c = stream_peek_byte(s)
	if (c != -1): s.position = s.position + 1
	return c


# Reads n bytes into out unless input ends or fails first. Returns IO_OK
# (transferred == n), IO_EOF (transferred < n: real end of input), or
# the latched error with the bytes copied before it.
int stream_read_checked(wstream* s, char* out, int n, io_result* r):
	int copied = 0
	while (copied < n):
		if (s.position >= s.limit):
			if (s.error_status != IO_OK):
				return io_result_set(r, copied, s.error_status, s.error_errno)
			if (s.eof): return io_result_set(r, copied, IO_EOF, 0)
			# Large remainders skip the buffer and read straight into out.
			if ((n - copied) >= s.capacity):
				io_result step
				int status = io_read_some(s.fd, out + copied, n - copied, &step)
				if (status == IO_EOF):
					s.eof = 1
				else if (status != IO_OK):
					stream_latch_error(s, status, step.native_error)
				else:
					copied = copied + step.transferred
				continue
			stream_fill(s)
			continue
		while ((copied < n) && (s.position < s.limit)):
			out[copied] = s.buffer[s.position]
			s.position = s.position + 1
			copied = copied + 1
	return io_result_set(r, copied, IO_OK, 0)


# Reads up to n bytes into out. Returns the number of bytes read, short
# (0 when nothing remains) at end of input or on an error -- tell the two
# apart with stream_error().
int stream_read(wstream* s, char* out, int n):
	io_result r
	stream_read_checked(s, out, n, &r)
	return r.transferred


# Reads one line into the builder, dropping the trailing newline.
# Returns 1 when a line was read, 0 when the input was already exhausted.
# A read error ends the line (or returns 0) like end of input does;
# stream_error() tells the two apart.
int stream_read_line(wstream* s, string_builder* line):
	string_clear(line)
	int c = stream_read_byte(s)
	if (c == -1): return 0
	while ((c != 10) && (c != -1)):
		string_append_char(line, c)
		c = stream_read_byte(s)
	return 1


void stream_append_bytes(string_builder* out, char* data, int n):
	string_reserve(out, n)
	for i in range(n): out.data[out.length + i] = data[i]
	out.length = out.length + n
	out.data[out.length] = 0


# Appends everything remaining on the stream to the builder. Works on
# non-seekable descriptors (pipes, sockets), unlike file_size().
#
# While the builder already has room (file_read_text reserves the file's
# size up front), reads go straight into its storage, skipping the
# stream buffer and the byte-copy loop.
#
# Returns IO_OK once real end of input is reached, or the latched error
# (transferred counts the bytes appended by this call either way).
int stream_read_all_checked(wstream* s, string_builder* out, io_result* r):
	int appended = 0
	while (1):
		if ((s.position >= s.limit) && (s.eof == 0) && (s.error_status == IO_OK) && (out.capacity - out.length - 1 >= s.capacity)):
			io_result step
			int status = io_read_some(s.fd, out.data + out.length, out.capacity - out.length - 1, &step)
			if (status == IO_EOF):
				s.eof = 1
			else if (status != IO_OK):
				stream_latch_error(s, status, step.native_error)
			else:
				out.length = out.length + step.transferred
				out.data[out.length] = 0
				appended = appended + step.transferred
			continue
		if (s.position >= s.limit):
			stream_fill(s)
			if (s.position >= s.limit):
				if (s.error_status != IO_OK):
					return io_result_set(r, appended, s.error_status, s.error_errno)
				return io_result_set(r, appended, IO_OK, 0)
		stream_append_bytes(out, s.buffer + s.position, s.limit - s.position)
		appended = appended + (s.limit - s.position)
		s.position = s.limit
	return IO_IO_ERROR


void stream_read_all(wstream* s, string_builder* out):
	io_result r
	stream_read_all_checked(s, out, &r)


/* Writer operations */

# Accepts n bytes: buffers them, or (when at least as large as the
# buffer) flushes and writes them straight through. transferred is the
# bytes of data accepted -- n on success. A stream holding an error
# accepts nothing; a failed flush accepts nothing and keeps its retained
# suffix; a failed direct write reports the prefix of data that reached
# the descriptor and latches (the rest of data is the caller's to retry
# -- it is not copied into the buffer).
int stream_write_checked(wstream* s, char* data, int n, io_result* r):
	if (s.error_status != IO_OK): return stream_report_error(s, r)
	if (n <= 0): return io_result_set(r, 0, IO_OK, 0)
	io_result step
	# Writes at least as large as the buffer bypass it.
	if (n >= s.capacity):
		if (stream_flush_checked(s, &step) != IO_OK):
			return io_result_set(r, 0, step.status, step.native_error)
		int status = io_write_all(s.fd, data, n, &step)
		if (status != IO_OK): stream_latch_error(s, status, step.native_error)
		return io_result_set(r, step.transferred, status, step.native_error)
	if ((s.limit + n) > s.capacity):
		if (stream_flush_checked(s, &step) != IO_OK):
			return io_result_set(r, 0, step.status, step.native_error)
	for i in range(n): s.buffer[s.limit + i] = data[i]
	s.limit = s.limit + n
	return io_result_set(r, n, IO_OK, 0)


# Legacy form: on failure the bytes are refused and stream_error() says
# why.
void stream_write(wstream* s, char* data, int n):
	io_result r
	stream_write_checked(s, data, n, &r)


void stream_write_byte(wstream* s, int c):
	if (s.error_status != IO_OK): return
	if (s.limit >= s.capacity):
		io_result r
		if (stream_flush_checked(s, &r) != IO_OK): return
	s.buffer[s.limit] = c
	s.limit = s.limit + 1


void stream_write_cstr(wstream* s, char* text):
	stream_write(s, text, strlen(text))


void stream_write_string(wstream* s, string str):
	stream_write(s, str.data, str.length)


void stream_write_int(wstream* s, int v):
	char* digits = itoa(v)
	stream_write_cstr(s, digits)
	free(digits)


void stream_write_line(wstream* s, char* text):
	stream_write_cstr(s, text)
	stream_write_byte(s, 10)


/* Standard descriptors, created on first use. Writers buffer: callers must
   stream_flush() before exiting (stream_write_line does not auto-flush). */

wstream* stream_stdin
wstream* stream_stdout
wstream* stream_stderr


wstream* stdin_reader():
	if (stream_stdin == 0): stream_stdin = stream_reader(0)
	return stream_stdin


wstream* stdout_writer():
	if (stream_stdout == 0): stream_stdout = stream_writer(1)
	return stream_stdout


wstream* stderr_writer():
	if (stream_stderr == 0): stream_stderr = stream_writer(2)
	return stream_stderr


/* Content-Length framing (the LSP/MCP stdio wire format):
   "Content-Length: N\r\n" ... "\r\n" followed by exactly N payload bytes. */

# Reads one frame into body. Unknown header lines are skipped; a plain "\n"
# terminator is tolerated alongside "\r\n". Returns 1 on success, 0 on end
# of input or a malformed frame.
int frame_read(wstream* in, string_builder* body):
	string_builder* line = string_new()
	int length = -1
	while (1):
		if (stream_read_line(in, line) == 0):
			string_free(line)
			return 0
		if ((line.length > 0) && (line.data[line.length - 1] == 13)):
			line.length = line.length - 1
			line.data[line.length] = 0
		if (line.length == 0): break
		if (starts_with(line.data, c"Content-Length:")):
			char* value = line.data + 15
			while (value[0] == ' '): value = value + 1
			length = atoi(value)
	string_free(line)
	if (length < 0): return 0
	string_clear(body)
	string_reserve(body, length)
	for i in range(length):
		int c = stream_read_byte(in)
		if (c == -1): return 0
		string_append_char(body, c)
	return 1


void frame_write(wstream* out, char* data, int length):
	stream_write_cstr(out, c"Content-Length: ")
	stream_write_int(out, length)
	stream_write_cstr(out, c"\x0d\x0a\x0d\x0a")
	stream_write(out, data, length)
	stream_flush(out)
