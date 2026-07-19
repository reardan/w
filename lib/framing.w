# Content-Length framing for byte streams (the LSP/MCP wire format):
#
#   Content-Length: <N>\r\n
#   [other headers are ignored]\r\n
#   \r\n
#   <N body bytes>
#
# frame_reader buffers a descriptor so it tolerates short reads, messages
# split across reads, and several messages arriving in a single read.
import lib.lib
import lib.memory


# Writes all n bytes, retrying on short writes.
# Returns n, or a negative errno on failure.
int write_all(int fd, char* buf, int n):
	int total = 0
	while (total < n):
		int written = write(fd, buf + total, n - total)
		if (written < 0):
			return written
		if (written == 0):
			return total
		total = total + written
	return total


# Reads exactly n bytes unless EOF or an error cuts the stream short.
# Returns the number of bytes read (n on success) or a negative errno.
int read_exact(int fd, char* buf, int n):
	int total = 0
	while (total < n):
		int count = read(fd, buf + total, n - total)
		if (count < 0):
			return count
		if (count == 0):
			return total
		total = total + count
	return total


struct frame_reader:
	int fd
	char* buffer
	int capacity
	int length
	int offset
	int error


frame_reader* frame_reader_new(int fd):
	frame_reader* r = new frame_reader()
	r.fd = fd
	r.capacity = 1024
	r.buffer = malloc(r.capacity)
	r.length = 0
	r.offset = 0
	r.error = 0
	return r


void frame_reader_free(frame_reader* r):
	free(r.buffer)
	free(r)


# Drops consumed bytes, grows the buffer when full, and reads more from
# the descriptor. Returns bytes read (0 on EOF) or a negative errno.
int frame_reader_fill(frame_reader* r):
	if (r.offset > 0):
		int i = 0
		while (r.offset + i < r.length):
			r.buffer[i] = r.buffer[r.offset + i]
			i = i + 1
		r.length = r.length - r.offset
		r.offset = 0
	if (r.length == r.capacity):
		int new_capacity = r.capacity * 2
		r.buffer = realloc(r.buffer, r.length, new_capacity)
		r.capacity = new_capacity
	int count = read(r.fd, r.buffer + r.length, r.capacity - r.length)
	if (count > 0):
		r.length = r.length + count
	return count


# Index just past "\r\n\r\n" in the buffered bytes, or -1 if the header
# block is not complete yet.
int frame_find_header_end(frame_reader* r):
	int i = r.offset
	while (i + 3 < r.length):
		if ((r.buffer[i] == 13) && (r.buffer[i + 1] == 10) && (r.buffer[i + 2] == 13) && (r.buffer[i + 3] == 10)):
			return i + 4
		i = i + 1
	return 0 - 1


int frame_char_lower(int c):
	if ((c >= 'A') && (c <= 'Z')):
		return c + 32
	return c


# Case-insensitively matches name at buffer index i, staying below limit.
# Returns the index just past the name, or -1 on mismatch.
int frame_match_header_name(frame_reader* r, int i, int limit, char* name):
	int j = 0
	while (name[j] != 0):
		if (i >= limit):
			return 0 - 1
		if (frame_char_lower(r.buffer[i] & 255) != (name[j] & 255)):
			return 0 - 1
		i = i + 1
		j = j + 1
	return i


# Parses the Content-Length value out of the buffered header block that
# ends at header_end. Returns the length, or -1 when absent or malformed.
int frame_parse_content_length(frame_reader* r, int header_end):
	int i = r.offset
	while (i < header_end):
		int after_name = frame_match_header_name(r, i, header_end, c"content-length:")
		if (after_name >= 0):
			while ((after_name < header_end) && (r.buffer[after_name] == ' ')):
				after_name = after_name + 1
			int value = 0
			int digits = 0
			while ((after_name < header_end) && (r.buffer[after_name] >= '0') && (r.buffer[after_name] <= '9')):
				value = value * 10 + r.buffer[after_name] - '0'
				digits = digits + 1
				after_name = after_name + 1
			if (digits == 0):
				return 0 - 1
			return value
		# Skip to the start of the next header line.
		while (i < header_end):
			if (r.buffer[i] == 10):
				i = i + 1
				break
			i = i + 1
	return 0 - 1


# Extracts one message if it is already fully buffered, without reading
# from the descriptor (useful with non-blocking descriptors and event
# loops). Returns a malloc'd null-terminated body and stores its length
# in length_out, or 0 when the buffered bytes are incomplete. A malformed
# header also sets r.error to 1.
char* frame_take_buffered_message(frame_reader* r, int* length_out):
	*length_out = 0
	int header_end = frame_find_header_end(r)
	if (header_end < 0):
		return 0

	int body_length = frame_parse_content_length(r, header_end)
	if (body_length < 0):
		r.error = 1
		return 0

	if (r.length - header_end < body_length):
		return 0

	char* body = malloc(body_length + 1)
	int i = 0
	while (i < body_length):
		body[i] = r.buffer[header_end + i]
		i = i + 1
	body[body_length] = 0
	r.offset = header_end + body_length
	*length_out = body_length
	return body


# Reads one framed message, blocking until it is complete. Returns a
# malloc'd null-terminated body and stores its length in length_out.
# Returns 0 on clean EOF or on error; a malformed header or truncated
# stream also sets r.error to 1.
char* frame_read_message(frame_reader* r, int* length_out):
	char* body = frame_take_buffered_message(r, length_out)
	while (body == 0):
		if (r.error):
			return 0
		int count = frame_reader_fill(r)
		if (count < 0):
			r.error = 1
			return 0
		if (count == 0):
			# EOF: clean if nothing was buffered, truncated otherwise.
			if (r.offset < r.length):
				r.error = 1
			return 0
		body = frame_take_buffered_message(r, length_out)
	return body


# Writes "Content-Length: N\r\n\r\n" followed by the body.
# Returns the total bytes written or a negative errno.
int frame_write_message(int fd, char* body, int length):
	char* digits = itoa(length)
	char* header = strjoin(c"Content-Length: ", digits)
	char* full_header = strjoin(header, c"\x0d\x0a\x0d\x0a")
	free(digits)
	free(header)
	int header_length = strlen(full_header)
	int written = write_all(fd, full_header, header_length)
	free(full_header)
	if (written < header_length):
		if (written < 0):
			return written
		return 0 - 1
	int body_written = write_all(fd, body, length)
	if (body_written < 0):
		return body_written
	return header_length + body_written


# Convenience for null-terminated bodies such as serialized JSON.
int frame_write_cstr(int fd, char* body):
	return frame_write_message(fd, body, strlen(body))
