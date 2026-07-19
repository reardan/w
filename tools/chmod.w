/*
chmod: set file permission bits (octal mode only).

Usage: chmod <octal-mode> <path>...

Accepts modes like 644 or 0644. Symbolic modes (u+x) are out of scope.
*/
import lib.lib
import lib.stat
import lib.stream


void chmod_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: chmod <octal-mode> <path>...")
	stream_flush(err)


# Parse an octal integer. Returns the value, or -1 on invalid input.
int chmod_parse_octal(char* s):
	if (s == 0):
		return -1
	if (s[0] == 0):
		return -1
	int result = 0
	int i = 0
	while (s[i]):
		int d = s[i] - '0'
		if ((d < 0) | (d > 7)):
			return -1
		result = result * 8 + d
		i = i + 1
	return result


int main(int argc, int argv):
	if (argc >= 2):
		char** help_slot = argv + __word_size__
		char* first = *help_slot
		if ((strcmp(first, c"-h") == 0) | (strcmp(first, c"--help") == 0)):
			chmod_usage()
			return 0
	if (argc < 3):
		chmod_usage()
		return 1
	char** mode_slot = argv + __word_size__
	int mode = chmod_parse_octal(*mode_slot)
	if (mode < 0):
		wstream* err = stderr_writer()
		stream_write_line(err, c"chmod: invalid octal mode")
		stream_flush(err)
		return 1
	int failed = 0
	int i = 2
	while (i < argc):
		char** path_slot = argv + i * __word_size__
		char* path = *path_slot
		int err = file_chmod(path, mode)
		if (err != 0):
			wstream* err_out = stderr_writer()
			stream_write_cstr(err_out, c"chmod: cannot chmod '")
			stream_write_cstr(err_out, path)
			stream_write_cstr(err_out, c"': ")
			stream_write_cstr(err_out, itoa(err))
			stream_write_line(err_out, c"")
			stream_flush(err_out)
			failed = 1
		i = i + 1
	return failed
