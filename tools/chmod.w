# wbuild: target=chmod dep=wv2 input=tools/chmod.w input=lib/stat.w output=bin/chmod
# wbuild: step="bin/wv2 tools/chmod.w -o bin/chmod"
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
	int mode = file_mode_parse_octal(*mode_slot)
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
