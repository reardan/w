# wbuild: x64
import lib.testing
import lib.stream
import lib.file
import lib.net


# Tiny capacities force the refill/flush paths on every few bytes.
void stream_test_write_fixture(char* path, char* text, int capacity):
	int fd = open(path, 577, 493)
	asserts(c"fixture open failed", fd >= 0)
	wstream* out = stream_writer_sized(fd, capacity)
	stream_write_cstr(out, text)
	stream_close(out)


void test_stream_write_then_read_bytes():
	stream_test_write_fixture(c"bin/stream_test_bytes.txt", c"abcdef", 4)
	wstream* in = stream_open_read(c"bin/stream_test_bytes.txt")
	asserts(c"open_read failed", cast(int, in) != 0)
	assert_equal('a', stream_peek_byte(in))
	assert_equal('a', stream_read_byte(in))
	assert_equal('b', stream_read_byte(in))
	assert_equal('c', stream_read_byte(in))
	assert_equal('d', stream_read_byte(in))
	assert_equal('e', stream_read_byte(in))
	assert_equal('f', stream_read_byte(in))
	assert_equal(-1, stream_read_byte(in))
	assert_equal(-1, stream_peek_byte(in))
	assert_equal(-1, stream_read_byte(in))
	stream_close(in)


void test_stream_open_read_missing_file():
	wstream* in = stream_open_read(c"bin/stream_test_missing_11aa.txt")
	assert_equal(0, cast(int, in))


void test_stream_read_spanning_refills():
	stream_test_write_fixture(c"bin/stream_test_span.txt", c"0123456789", 3)
	int fd = open(c"bin/stream_test_span.txt", 0, 0)
	wstream* in = stream_reader_sized(fd, 3)
	char* buf = malloc(16)
	# 7 > capacity 3: exercises both the buffered and the direct-read path.
	assert_equal(7, stream_read(in, buf, 7))
	buf[7] = 0
	assert_strings_equal(c"0123456", buf)
	assert_equal(3, stream_read(in, buf, 16))
	buf[3] = 0
	assert_strings_equal(c"789", buf)
	assert_equal(0, stream_read(in, buf, 16))
	stream_close(in)
	free(buf)


void test_stream_read_line():
	stream_test_write_fixture(c"bin/stream_test_lines.txt", c"first\x0a\x0athird line\x0ano newline", 4)
	int fd = open(c"bin/stream_test_lines.txt", 0, 0)
	wstream* in = stream_reader_sized(fd, 4)
	string_builder* line = string_new()
	assert_equal(1, stream_read_line(in, line))
	assert_strings_equal(c"first", line.data)
	assert_equal(1, stream_read_line(in, line))
	assert_strings_equal(c"", line.data)
	assert_equal(1, stream_read_line(in, line))
	assert_strings_equal(c"third line", line.data)
	assert_equal(1, stream_read_line(in, line))
	assert_strings_equal(c"no newline", line.data)
	assert_equal(0, stream_read_line(in, line))
	assert_strings_equal(c"", line.data)
	stream_close(in)
	string_free(line)


void test_stream_read_all_spans_buffers():
	stream_test_write_fixture(c"bin/stream_test_all.txt", c"the quick brown fox jumps over the lazy dog", 8)
	int fd = open(c"bin/stream_test_all.txt", 0, 0)
	wstream* in = stream_reader_sized(fd, 8)
	string_builder* all = string_new()
	stream_read_all(in, all)
	assert_strings_equal(c"the quick brown fox jumps over the lazy dog", all.data)
	# Reading again appends nothing.
	stream_read_all(in, all)
	assert_equal(43, all.length)
	stream_close(in)
	string_free(all)


void test_stream_write_helpers():
	int fd = open(c"bin/stream_test_helpers.txt", 577, 493)
	wstream* out = stream_writer_sized(fd, 4)
	stream_write_line(out, c"n=")
	stream_write_int(out, -42)
	stream_write_byte(out, ' ')
	string s = "utf8"
	stream_write_string(out, s)
	# A write larger than the buffer takes the bypass path.
	stream_write_cstr(out, c" 0123456789abcdef")
	stream_close(out)

	wstream* in = stream_open_read(c"bin/stream_test_helpers.txt")
	string_builder* all = string_new()
	stream_read_all(in, all)
	assert_strings_equal(c"n=\x0a-42 utf8 0123456789abcdef", all.data)
	stream_close(in)
	string_free(all)


void test_stream_flush_makes_bytes_visible():
	int fd = open(c"bin/stream_test_flush.txt", 577, 493)
	wstream* out = stream_writer(fd)
	stream_write_cstr(out, c"buffered")

	# Nothing is on disk until the writer flushes.
	char* probe = file_read_text(c"bin/stream_test_flush.txt")
	assert_strings_equal(c"", probe)
	free(probe)

	stream_flush(out)
	probe = file_read_text(c"bin/stream_test_flush.txt")
	assert_strings_equal(c"buffered", probe)
	free(probe)
	stream_close(out)


void test_stream_over_socketpair():
	# Sockets are not seekable: file_size() style IO cannot work here,
	# streams must.
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)

	wstream* out = stream_writer_sized(fds[0], 4)
	stream_write_line(out, c"over")
	stream_write_line(out, c"the wire")
	stream_close(out)

	wstream* in = stream_reader_sized(fds[1], 4)
	string_builder* line = string_new()
	assert_equal(1, stream_read_line(in, line))
	assert_strings_equal(c"over", line.data)
	assert_equal(1, stream_read_line(in, line))
	assert_strings_equal(c"the wire", line.data)
	assert_equal(0, stream_read_line(in, line))
	stream_close(in)
	string_free(line)
	free(fds)


void test_frame_round_trip():
	int fd = open(c"bin/stream_test_frame.txt", 577, 493)
	wstream* out = stream_writer(fd)
	frame_write(out, c"hello frames", 12)
	frame_write(out, c"", 0)
	frame_write(out, c"second", 6)
	stream_free(out)
	close(fd)

	wstream* in = stream_open_read(c"bin/stream_test_frame.txt")
	string_builder* body = string_new()
	assert_equal(1, frame_read(in, body))
	assert_strings_equal(c"hello frames", body.data)
	assert_equal(1, frame_read(in, body))
	assert_equal(0, body.length)
	assert_equal(1, frame_read(in, body))
	assert_strings_equal(c"second", body.data)
	assert_equal(0, frame_read(in, body))
	stream_close(in)
	string_free(body)


void test_frame_read_tolerates_bare_newlines_and_extra_headers():
	stream_test_write_fixture(c"bin/stream_test_frame2.txt", c"Content-Type: application/json\x0aContent-Length:5\x0a\x0ahello", 8)
	wstream* in = stream_open_read(c"bin/stream_test_frame2.txt")
	string_builder* body = string_new()
	assert_equal(1, frame_read(in, body))
	assert_strings_equal(c"hello", body.data)
	stream_close(in)
	string_free(body)


void test_frame_read_truncated_body_fails():
	stream_test_write_fixture(c"bin/stream_test_frame3.txt", c"Content-Length: 100\x0d\x0a\x0d\x0ashort", 8)
	wstream* in = stream_open_read(c"bin/stream_test_frame3.txt")
	string_builder* body = string_new()
	assert_equal(0, frame_read(in, body))
	stream_close(in)
	string_free(body)


void test_frame_over_socketpair():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)

	wstream* out = stream_writer(fds[0])
	frame_write(out, c"{\x22method\x22:\x22ping\x22}", 17)
	stream_close(out)

	wstream* in = stream_reader(fds[1])
	string_builder* body = string_new()
	assert_equal(1, frame_read(in, body))
	assert_strings_equal(c"{\x22method\x22:\x22ping\x22}", body.data)
	assert_equal(0, frame_read(in, body))
	stream_close(in)
	string_free(body)
	free(fds)


void test_std_writers_are_singletons():
	wstream* out = stdout_writer()
	asserts(c"stdout_writer returned 0", cast(int, out) != 0)
	asserts(c"stdout_writer not a singleton", cast(int, out) == cast(int, stdout_writer()))
	assert_equal(1, out.fd)
	assert_equal(2, stderr_writer().fd)
	assert_equal(0, stdin_reader().fd)
