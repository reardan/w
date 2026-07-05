import lib.testing
import lib.net
import lib.framing


int framing_test_pair(int* fds):
	int err = socket_pair(fds)
	asserts(c"socket_pair failed", err >= 0)
	return err


void test_write_then_read_one_message():
	int* fds = malloc(__word_size__ * 2)
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
	int* fds = malloc(__word_size__ * 2)
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
	int* fds = malloc(__word_size__ * 2)
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
	int* fds = malloc(__word_size__ * 2)
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
	int* fds = malloc(__word_size__ * 2)
	framing_test_pair(fds)

	char* wire = c"Content-Type: application/json\x0d\x0a\x0d\x0abody"
	assert_equal(strlen(wire), write_all(fds[0], wire, strlen(wire)))
	close(fds[0])

	frame_reader* r = frame_reader_new(fds[1])
	int length = 0
	char* got = frame_read_message(r, &length)
	assert_equal(0, cast(int, got))
	assert_equal(1, r.error)

	frame_reader_free(r)
	close(fds[1])
	free(fds)


void test_truncated_body_sets_error():
	int* fds = malloc(__word_size__ * 2)
	framing_test_pair(fds)

	char* wire = c"Content-Length: 10\x0d\x0a\x0d\x0ashort"
	assert_equal(strlen(wire), write_all(fds[0], wire, strlen(wire)))
	close(fds[0])

	frame_reader* r = frame_reader_new(fds[1])
	int length = 0
	char* got = frame_read_message(r, &length)
	assert_equal(0, cast(int, got))
	assert_equal(1, r.error)

	frame_reader_free(r)
	close(fds[1])
	free(fds)


void test_large_message_grows_buffer():
	int* fds = malloc(__word_size__ * 2)
	framing_test_pair(fds)

	# Larger than the initial 1024-byte reader buffer.
	int body_length = 3000
	char* body = malloc(body_length + 1)
	int i = 0
	while (i < body_length):
		body[i] = 'a' + (i % 26)
		i = i + 1
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


void test_read_exact_and_write_all():
	int* fds = malloc(__word_size__ * 2)
	framing_test_pair(fds)

	assert_equal(4, write_all(fds[0], c"abcd", 4))
	char* buf = malloc(8)
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
