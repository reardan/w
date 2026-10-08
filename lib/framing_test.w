# wbuild: x64
import lib.testing
import lib.net
import lib.framing


int framing_test_pair(int* fds):
	int err = socket_pair(fds)
	asserts(c"socket_pair failed", err >= 0)
	return err


void test_write_then_read_one_message():
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)

	char* body = c"{\x22jsonrpc\x22:\x222.0\x22}"
	int total = frame_write_cstr(fds[0], body)
	asserts(c"frame_write_cstr failed", total > strlen(body))
	close(fds[0])

	frame_reader* r = frame_reader_new(fds[1])
	int length = 0
	char* got = frame_read_message(r, &length)
	asserts(c"expected a message", cast(int, got) != 0)
	assert_equal(strlen(body), length)
	assert_strings_equal(body, got)
	assert_equal(0, r.error)

	# Clean EOF afterwards.
	char* next = frame_read_message(r, &length)
	assert_equal(0, cast(int, next))
	assert_equal(0, r.error)

	free(got)
	frame_reader_free(r)
	close(fds[1])
	free(fds)


void test_two_messages_in_one_read():
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)

	char* wire = c"Content-Length: 5\x0d\x0a\x0d\x0ahelloContent-Length: 5\x0d\x0a\x0d\x0aworld"
	assert_equal(strlen(wire), write_all(fds[0], wire, strlen(wire)))
	close(fds[0])

	frame_reader* r = frame_reader_new(fds[1])
	int length = 0
	char* first = frame_read_message(r, &length)
	assert_equal(5, length)
	assert_strings_equal(c"hello", first)
	char* second = frame_read_message(r, &length)
	assert_equal(5, length)
	assert_strings_equal(c"world", second)
	assert_equal(0, r.error)

	free(first)
	free(second)
	frame_reader_free(r)
	close(fds[1])
	free(fds)


void test_message_split_across_writes():
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)

	# Split mid-header and mid-body.
	char* part1 = c"Content-Len"
	char* part2 = c"gth: 4\x0d\x0a\x0d\x0api"
	char* part3 = c"ng"
	assert_equal(strlen(part1), write_all(fds[0], part1, strlen(part1)))
	assert_equal(strlen(part2), write_all(fds[0], part2, strlen(part2)))
	assert_equal(strlen(part3), write_all(fds[0], part3, strlen(part3)))
	close(fds[0])

	frame_reader* r = frame_reader_new(fds[1])
	int length = 0
	char* got = frame_read_message(r, &length)
	assert_equal(4, length)
	assert_strings_equal(c"ping", got)

	free(got)
	frame_reader_free(r)
	close(fds[1])
	free(fds)


void test_extra_headers_and_case_insensitive_name():
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)

	char* wire = c"Content-Type: application/json\x0d\x0aCONTENT-LENGTH: 2\x0d\x0a\x0d\x0aok"
	assert_equal(strlen(wire), write_all(fds[0], wire, strlen(wire)))
	close(fds[0])

	frame_reader* r = frame_reader_new(fds[1])
	int length = 0
	char* got = frame_read_message(r, &length)
	assert_equal(2, length)
	assert_strings_equal(c"ok", got)

	free(got)
	frame_reader_free(r)
	close(fds[1])
	free(fds)


void test_missing_content_length_sets_error():
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)

	char* wire = c"Content-Type: application/json\x0d\x0a\x0d\x0abody"
	assert_equal(strlen(wire), write_all(fds[0], wire, strlen(wire)))
	close(fds[0])

	frame_reader* r = frame_reader_new(fds[1])
	int length = 0
	char* got = frame_read_message(r, &length)
	assert_equal(0, cast(int, got))
	assert_equal(frame_error_malformed, r.error)

	frame_reader_free(r)
	close(fds[1])
	free(fds)


void test_truncated_body_sets_error():
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)

	char* wire = c"Content-Length: 10\x0d\x0a\x0d\x0ashort"
	assert_equal(strlen(wire), write_all(fds[0], wire, strlen(wire)))
	close(fds[0])

	frame_reader* r = frame_reader_new(fds[1])
	int length = 0
	char* got = frame_read_message(r, &length)
	assert_equal(0, cast(int, got))
	assert_equal(frame_error_malformed, r.error)

	frame_reader_free(r)
	close(fds[1])
	free(fds)


void test_large_message_grows_buffer():
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)

	# Larger than the initial 1024-byte reader buffer.
	int body_length = 3000
	char* body = cast(char*, malloc(body_length + 1))
	for i in range(body_length): body[i] = 'a' + (i % 26)
	body[body_length] = 0

	int total = frame_write_message(fds[0], body, body_length)
	asserts(c"frame_write_message failed", total > body_length)
	close(fds[0])

	frame_reader* r = frame_reader_new(fds[1])
	int length = 0
	char* got = frame_read_message(r, &length)
	assert_equal(body_length, length)
	assert_strings_equal(body, got)

	free(body)
	free(got)
	frame_reader_free(r)
	close(fds[1])
	free(fds)


# Writes wire to a fresh socket pair, closes the writer, and reads one
# message with r configured by max_body (0 = default). Returns r.error.
int framing_test_read_error(char* wire, int wire_len, int max_body):
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)
	assert_equal(wire_len, write_all(fds[0], wire, wire_len))
	close(fds[0])

	frame_reader* r = frame_reader_new(fds[1])
	if (max_body > 0): frame_reader_set_max_body(r, max_body)
	int length = 0
	char* got = frame_read_message(r, &length)
	assert_equal(0, cast(int, got))
	int error = r.error
	frame_reader_free(r)
	close(fds[1])
	free(fds)
	return error


void test_content_length_over_cap_is_rejected():
	char* wire = c"Content-Length: 101\x0d\x0a\x0d\x0a"
	assert_equal(frame_error_too_large, framing_test_read_error(wire, strlen(wire), 100))

	# Exactly the cap is fine.
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)
	char* ok = c"Content-Length: 5\x0d\x0a\x0d\x0ahello"
	assert_equal(strlen(ok), write_all(fds[0], ok, strlen(ok)))
	close(fds[0])
	frame_reader* r = frame_reader_new(fds[1])
	frame_reader_set_max_body(r, 5)
	int length = 0
	char* got = frame_read_message(r, &length)
	assert_strings_equal(c"hello", got)
	assert_equal(0, r.error)
	free(got)
	frame_reader_free(r)
	close(fds[1])
	free(fds)

	# The default cap rejects an absurd length before buffering a byte.
	char* huge = c"Content-Length: 1000000000\x0d\x0a\x0d\x0a"
	assert_equal(frame_error_too_large, framing_test_read_error(huge, strlen(huge), 0))


void test_content_length_digit_overflow_is_rejected():
	# 2^32 + 5 and 2^64 + 5 would wrap to 5 with an unchecked value*10.
	char* wire32 = c"Content-Length: 4294967301\x0d\x0a\x0d\x0ahello"
	assert_equal(frame_error_too_large, framing_test_read_error(wire32, strlen(wire32), 0))
	char* wire64 = c"Content-Length: 18446744073709551621\x0d\x0a\x0d\x0ahello"
	assert_equal(frame_error_too_large, framing_test_read_error(wire64, strlen(wire64), 0))
	char* zeros = c"Content-Length: 0000000000000000000000000000005\x0d\x0a\x0d\x0ahello"
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)
	assert_equal(strlen(zeros), write_all(fds[0], zeros, strlen(zeros)))
	close(fds[0])
	frame_reader* r = frame_reader_new(fds[1])
	int length = 0
	char* got = frame_read_message(r, &length)
	assert_strings_equal(c"hello", got)
	free(got)
	frame_reader_free(r)
	close(fds[1])
	free(fds)


void test_unterminated_header_flood_is_rejected():
	# 20 KB of header lines with no blank terminator line: the reader
	# must give up at max_header_bytes rather than buffer forever.
	int n = 20000
	char* wire = cast(char*, malloc(n))
	for i in range(n): wire[i] = 'a'
	int i = 0
	while (i + 11 < n):
		mem_copy(wire + i, c"X-Pad: aaa\x0d\x0a", 12)
		i = i + 12
	assert_equal(frame_error_too_large, framing_test_read_error(wire, n, 0))
	free(wire)


void test_read_exact_and_write_all():
	int* fds = cast(int*, malloc(__word_size__ * 2))
	framing_test_pair(fds)

	assert_equal(4, write_all(fds[0], c"abcd", 4))
	char* buf = cast(char*, malloc(8))
	assert_equal(4, read_exact(fds[1], buf, 4))
	buf[4] = 0
	assert_strings_equal(c"abcd", buf)

	# EOF before n bytes returns the shorter count.
	assert_equal(2, write_all(fds[0], c"xy", 2))
	close(fds[0])
	assert_equal(2, read_exact(fds[1], buf, 8))

	close(fds[1])
	free(buf)
	free(fds)
