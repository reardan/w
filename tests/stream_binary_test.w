# wbuild: x64
/*
Regression test for the stream_peek_byte sign-extension bug: a raw 0xFF
byte read through `s.buffer[s.position]` (a sign-extending `char` load)
came back as -1, indistinguishable from stream_peek_byte/stream_read_byte's
EOF sentinel. Because stream_read_byte only advances s.position when its
result is not -1, hitting a real 0xFF byte in the stream got the reader
permanently stuck at that position: stream_read_line returned a truncated
line and every later stream_read_line/file_read_lines call reported false
EOF from then on, silently losing the rest of the input. Fixed in
lib/stream.w by masking the load with `& 255`. This exercises the
byte-wise API directly plus the two lib/file.w helpers layered on it.
*/
import lib.testing
import lib.stream
import lib.file


# Writes every byte value 0..255 (including 0x00) via the byte-wise
# writer API. file_write_text can't be used for this one: it writes via
# strlen(text), which would stop at the embedded NUL.
void write_all_256_byte_values(char* path):
	int fd = open(path, 577, 493)
	asserts(c"fixture open failed", fd >= 0)
	# Small capacity forces refill/flush boundaries across the byte range.
	wstream* out = stream_writer_sized(fd, 7)
	int i = 0
	while (i < 256):
		stream_write_byte(out, i)
		i = i + 1
	stream_close(out)


void test_stream_byte_api_round_trips_all_256_values():
	char* path = c"bin/stream_binary_test_all256.bin"
	write_all_256_byte_values(path)

	int fd = open(path, 0, 0)
	asserts(c"fixture reopen failed", fd >= 0)
	# Small capacity forces refills across the same boundaries as the write.
	wstream* in = stream_reader_sized(fd, 5)
	int i = 0
	while (i < 256):
		assert_equal(i, stream_peek_byte(in))
		assert_equal(i, stream_read_byte(in))
		i = i + 1
	assert_equal(-1, stream_peek_byte(in))
	assert_equal(-1, stream_read_byte(in))
	assert_equal(-1, stream_read_byte(in))
	stream_close(in)


void test_file_read_text_round_trips_high_bytes():
	# Byte 0x00 is skipped here: file_read_text hands back a malloc'd
	# NUL-terminated C string by design (see its own doc comment), so an
	# embedded NUL is a distinct, pre-existing string-vs-buffer limitation
	# (strlen/strcmp stop at the first literal 0 byte no matter what this
	# fix does) -- not part of the sign-extension bug. 1..255 already
	# covers the whole 0x80-0xFF high half, including 0xFF itself.
	char* path = c"bin/stream_binary_test_high_bytes.bin"
	int fd = open(path, 577, 493)
	asserts(c"fixture open failed", fd >= 0)
	wstream* out = stream_writer_sized(fd, 7)
	int i = 1
	while (i < 256):
		stream_write_byte(out, i)
		i = i + 1
	stream_close(out)

	char* text = file_read_text(path)
	asserts(c"file_read_text failed", cast(int, text) != 0)
	assert_equal(255, strlen(text))
	i = 0
	while (i < 255):
		# text[i] is a plain char read: like any char access in the
		# language, it sign-extends on promotion to int (unrelated to
		# lib.stream -- see CLAUDE.md's char/byte notes). & 255 recovers
		# the unsigned byte value actually stored.
		assert_equal(i + 1, text[i] & 255)
		i = i + 1
	free(text)


void test_stream_read_line_does_not_truncate_at_0xff():
	char* path = c"bin/stream_binary_test_lines.bin"
	assert_equal(1, file_write_text(path, c"first line\x0aAB\xffCD\x0athird line\x0a"))

	wstream* in = stream_open_read(path)
	asserts(c"open_read failed", cast(int, in) != 0)
	string_builder* line = string_new()
	assert_equal(1, stream_read_line(in, line))
	assert_strings_equal(c"first line", line.data)
	assert_equal(1, stream_read_line(in, line))
	assert_equal(5, line.length)
	assert_strings_equal(c"AB\xffCD", line.data)
	assert_equal(1, stream_read_line(in, line))
	assert_strings_equal(c"third line", line.data)
	assert_equal(0, stream_read_line(in, line))
	stream_close(in)
	string_free(line)


void test_file_read_lines_does_not_truncate_at_0xff():
	char* path = c"bin/stream_binary_test_lines2.bin"
	assert_equal(1, file_write_text(path, c"first line\x0aAB\xffCD\x0athird line\x0a"))

	list[char*] lines = file_read_lines(path)
	assert_equal(3, lines.length)
	assert_strings_equal(c"first line", lines[0])
	assert_strings_equal(c"AB\xffCD", lines[1])
	assert_equal(5, strlen(lines[1]))
	assert_strings_equal(c"third line", lines[2])
	for char* line in lines:
		free(line)
