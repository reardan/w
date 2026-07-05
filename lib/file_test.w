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
	for char* line in lines:
		free(line)


void test_file_read_lines_missing_file():
	list[char*] lines = file_read_lines(c"bin/file_test_missing_11aa.txt")
	assert_equal(0, cast(int, lines))


void test_file_read_lines_empty_file():
	file_write_text(c"bin/file_test_empty.txt", c"")
	list[char*] lines = file_read_lines(c"bin/file_test_empty.txt")
	assert_equal(0, lines.length)
