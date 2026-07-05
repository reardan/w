/*
Buffered stream IO over raw file descriptors.

A wstream wraps a file descriptor with a byte buffer so callers stop paying
one syscall per byte (the getchar/putc pattern). A stream is either a reader
or a writer, never both on the same wstream. Writers buffer until the buffer
fills, stream_flush() is called, or the stream is closed/freed.

Also provides stdin/stdout/stderr singletons for line-oriented tools and
Content-Length framing (the LSP/MCP wire format) for stdio protocol servers.

Design notes: docs/projects/streams.md
*/
import lib.lib
import structures.string


struct wstream:
	int fd
	char* buffer
	int capacity
	int position   # next unread byte (readers only)
	int limit      # end of buffered data (readers) / pending bytes (writers)
	int eof
	int writable


int STREAM_DEFAULT_CAPACITY():
	return 4096


wstream* stream_reader_sized(int fd, int capacity):
	if (capacity < 1):
		capacity = 1
	wstream* s = new wstream()
	s.fd = fd
	s.buffer = malloc(capacity)
	s.capacity = capacity
	s.position = 0
	s.limit = 0
	s.eof = 0
	s.writable = 0
	return s


wstream* stream_reader(int fd):
	return stream_reader_sized(fd, STREAM_DEFAULT_CAPACITY())


wstream* stream_writer_sized(int fd, int capacity):
	wstream* s = stream_reader_sized(fd, capacity)
	s.writable = 1
	return s


wstream* stream_writer(int fd):
	return stream_writer_sized(fd, STREAM_DEFAULT_CAPACITY())


# Returns 0 when the file cannot be opened for reading.
wstream* stream_open_read(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0
	return stream_reader(fd)


# Creates or truncates the file. Returns 0 when the file cannot be opened.
wstream* stream_open_write(char* path):
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 493 = rwxr-xr-x
	int fd = open(path, 577, 493)
	if (fd < 0):
		return 0
	return stream_writer(fd)


void stream_flush(wstream* s):
	if (s.writable && (s.limit > 0)):
		write(s.fd, s.buffer, s.limit)
		s.limit = 0


# Flush and release the stream without closing the descriptor
# (for stdin/stdout/stderr).
void stream_free(wstream* s):
	stream_flush(s)
	free(s.buffer)
	free(s)


void stream_close(wstream* s):
	int fd = s.fd
	stream_free(s)
	close(fd)


/* Reader operations */

# Refill the buffer from the descriptor. A failed read is treated as EOF.
void stream_fill(wstream* s):
	if (s.eof):
		return
	s.position = 0
	s.limit = 0
	int count = read(s.fd, s.buffer, s.capacity)
	if (count <= 0):
		s.eof = 1
		return
	s.limit = count


# Returns the next byte without consuming it, or -1 at end of input.
int stream_peek_byte(wstream* s):
	if (s.position >= s.limit):
		stream_fill(s)
	if (s.position >= s.limit):
		return (-1)
	return s.buffer[s.position]


# Returns the next byte, or -1 at end of input.
int stream_read_byte(wstream* s):
	int c = stream_peek_byte(s)
	if (c != -1):
		s.position = s.position + 1
	return c


# Reads up to n bytes into out. Returns the number of bytes read,
# 0 at end of input.
int stream_read(wstream* s, char* out, int n):
	int copied = 0
	while (copied < n):
		if (s.position >= s.limit):
			# Large remainders skip the buffer and read straight into out.
			if ((n - copied) >= s.capacity):
				if (s.eof):
					return copied
				int count = read(s.fd, out + copied, n - copied)
				if (count <= 0):
					s.eof = 1
					return copied
				copied = copied + count
				continue
			stream_fill(s)
			if (s.position >= s.limit):
				return copied
		while ((copied < n) && (s.position < s.limit)):
			out[copied] = s.buffer[s.position]
			s.position = s.position + 1
			copied = copied + 1
	return copied


# Reads one line into the builder, dropping the trailing newline.
# Returns 1 when a line was read, 0 when the input was already exhausted.
int stream_read_line(wstream* s, string_builder* line):
	string_clear(line)
	int c = stream_read_byte(s)
	if (c == -1):
		return 0
	while ((c != 10) && (c != -1)):
		string_append_char(line, c)
		c = stream_read_byte(s)
	return 1


void stream_append_bytes(string_builder* out, char* data, int n):
	string_reserve(out, n)
	int i = 0
	while (i < n):
		out.data[out.length + i] = data[i]
		i = i + 1
	out.length = out.length + n
	out.data[out.length] = 0


# Appends everything remaining on the stream to the builder. Works on
# non-seekable descriptors (pipes, sockets), unlike file_size().
void stream_read_all(wstream* s, string_builder* out):
	while (1):
		if (s.position >= s.limit):
			stream_fill(s)
			if (s.position >= s.limit):
				return
		stream_append_bytes(out, s.buffer + s.position, s.limit - s.position)
		s.position = s.limit


/* Writer operations */

void stream_write(wstream* s, char* data, int n):
	# Writes at least as large as the buffer bypass it.
	if (n >= s.capacity):
		stream_flush(s)
		write(s.fd, data, n)
		return
	if ((s.limit + n) > s.capacity):
		stream_flush(s)
	int i = 0
	while (i < n):
		s.buffer[s.limit + i] = data[i]
		i = i + 1
	s.limit = s.limit + n


void stream_write_byte(wstream* s, int c):
	if (s.limit >= s.capacity):
		stream_flush(s)
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
	if (stream_stdin == 0):
		stream_stdin = stream_reader(0)
	return stream_stdin


wstream* stdout_writer():
	if (stream_stdout == 0):
		stream_stdout = stream_writer(1)
	return stream_stdout


wstream* stderr_writer():
	if (stream_stderr == 0):
		stream_stderr = stream_writer(2)
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
		if (line.length == 0):
			break
		if (starts_with(line.data, c"Content-Length:")):
			char* value = line.data + 15
			while (value[0] == ' '):
				value = value + 1
			length = atoi(value)
	string_free(line)
	if (length < 0):
		return 0
	string_clear(body)
	string_reserve(body, length)
	int i = 0
	while (i < length):
		int c = stream_read_byte(in)
		if (c == -1):
			return 0
		string_append_char(body, c)
		i = i + 1
	return 1


void frame_write(wstream* out, char* data, int length):
	stream_write_cstr(out, c"Content-Length: ")
	stream_write_int(out, length)
	stream_write_cstr(out, c"\x0d\x0a\x0d\x0a")
	stream_write(out, data, length)
	stream_flush(out)
