# wbuild: target=touch dep=wv2 input=tools/touch.w input=lib/stat.w output=bin/touch
# wbuild: step="bin/wv2 tools/touch.w -o bin/touch"
/*
touch: update file timestamps, creating the file when missing.

Usage: touch <path>...
*/
import lib.lib
import lib.stat
import lib.stream


void touch_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: touch <path>...")
	stream_flush(err)


int main(int argc, int argv):
	if (argc >= 2):
		char** help_slot = argv + __word_size__
		char* first = *help_slot
		if ((strcmp(first, c"-h") == 0) | (strcmp(first, c"--help") == 0)):
			touch_usage()
			return 0
	if (argc < 2):
		touch_usage()
		return 1
	int failed = 0
	for i in range(1, argc):
		char** path_slot = argv + i * __word_size__
		char* path = *path_slot
		if (path[0] == '-'):
			touch_usage()
			return 1
		int err = file_touch(path, 1)
		if (err != 0):
			wstream* err_out = stderr_writer()
			stream_write_cstr(err_out, c"touch: cannot touch '")
			stream_write_cstr(err_out, path)
			stream_write_cstr(err_out, c"': ")
			stream_write_cstr(err_out, itoa(err))
			stream_write_line(err_out, c"")
			stream_flush(err_out)
			failed = 1
	return failed
