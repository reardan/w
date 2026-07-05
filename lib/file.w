/*
Whole-file helpers built on lib.stream.

These read through a buffered stream rather than the seek-based file_size()
hack, so they also work on non-seekable inputs like /proc files and pipes.

Design notes: docs/projects/streams.md
*/
import lib.lib
import lib.stream
import structures.string


# Returns the file contents as a malloc'd NUL-terminated string the caller
# may free, or 0 when the file cannot be opened.
char* file_read_text(char* path):
	wstream* in = stream_open_read(path)
	if (in == 0):
		return 0
	string_builder* contents = string_new()
	stream_read_all(in, contents)
	stream_close(in)
	char* text = contents.data
	free(contents)
	return text


# Creates or truncates the file. Returns 1 on success, 0 on failure.
int file_write_text(char* path, char* text):
	wstream* out = stream_open_write(path)
	if (out == 0):
		return 0
	stream_write_cstr(out, text)
	stream_close(out)
	return 1


# Returns the file's lines (without newlines) as malloc'd strings the caller
# may free, or 0 when the file cannot be opened.
list[char*] file_read_lines(char* path):
	wstream* in = stream_open_read(path)
	if (in == 0):
		return 0
	list[char*] lines = new list[char*]
	string_builder* line = string_new()
	while (stream_read_line(in, line)):
		lines.push(strclone(line.data))
	string_free(line)
	stream_close(in)
	return lines
