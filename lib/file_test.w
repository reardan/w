# wbuild: x64
import lib.testing
import lib.file


void test_file_write_and_read_text():
	assert_equal(1, file_write_text(c"bin/file_test_round_trip.txt", c"alpha\x0abeta\x0a"))
	char* text = file_read_text(c"bin/file_test_round_trip.txt")
	assert_strings_equal(c"alpha\x0abeta\x0a", text)
	free(text)


void test_file_write_truncates_existing():
	assert_equal(1, file_write_text(c"bin/file_test_truncate.txt", c"a much longer original text"))
	assert_equal(1, file_write_text(c"bin/file_test_truncate.txt", c"short"))
	char* text = file_read_text(c"bin/file_test_truncate.txt")
	assert_strings_equal(c"short", text)
	free(text)


void test_file_read_text_missing_file():
	char* text = file_read_text(c"bin/file_test_missing_11aa.txt")
	assert_equal(0, cast(int, text))


void test_file_read_empty_file():
	assert_equal(1, file_write_text(c"bin/file_test_empty.txt", c""))
	char* text = file_read_text(c"bin/file_test_empty.txt")
	assert_strings_equal(c"", text)
	free(text)


void test_file_read_lines():
	file_write_text(c"bin/file_test_lines.txt", c"one\x0a\x0athree\x0atrailing")
	list[char*] lines = file_read_lines(c"bin/file_test_lines.txt")
	assert_equal(4, lines.length)
	assert_strings_equal(c"one", lines[0])
	assert_strings_equal(c"", lines[1])
	assert_strings_equal(c"three", lines[2])
	assert_strings_equal(c"trailing", lines[3])
	for char* line in lines: free(line)


void test_file_read_lines_missing_file():
	list[char*] lines = file_read_lines(c"bin/file_test_missing_11aa.txt")
	assert_equal(0, cast(int, lines))


void test_file_read_lines_empty_file():
	file_write_text(c"bin/file_test_empty.txt", c"")
	list[char*] lines = file_read_lines(c"bin/file_test_empty.txt")
	assert_equal(0, lines.length)


void test_file_write_text_reports_write_failure():
	# /dev/full accepts the open and fails every write with ENOSPC.
	assert_equal(0, file_write_text(c"/dev/full", c"lost"))
	io_result r
	assert_equal(IO_NO_SPACE, file_write_text_checked(c"/dev/full", c"lost", 4, &r))
	assert_equal(28, r.native_error)
	assert_equal(0, r.transferred)


void test_file_write_text_reports_open_failure():
	assert_equal(0, file_write_text(c"bin/file_test_no_such_dir/x.txt", c"x"))
	io_result r
	assert_equal(IO_IO_ERROR, file_write_text_checked(c"bin/file_test_no_such_dir/x.txt", c"x", 1, &r))
	assert_equal(2, r.native_error)  # ENOENT


void test_file_write_text_checked_writes_length_bytes():
	io_result r
	# Embedded NUL: the explicit length is honored, not strlen.
	assert_equal(IO_OK, file_write_text_checked(c"bin/file_test_checked.txt", c"ab\x00cd", 5, &r))
	assert_equal(5, r.transferred)
	int fd = open(c"bin/file_test_checked.txt", 0, 0)
	assert_equal(5, seek(fd, 0, 2))
	close(fd)


void test_file_read_error_is_not_truncated_text():
	# read(2) on a directory fails (EISDIR): no text, rather than "".
	assert_equal(0, cast(int, file_read_text(c"lib")))
	assert_equal(0, cast(int, file_read_lines(c"lib")))
