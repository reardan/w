/*
readlink: print the target of a symbolic link.

Usage: readlink [-n] <path>

-n suppresses the trailing newline. -n is a declared boolean flag
(lib/args.w's args_has_bool_flag) so it doesn't swallow the path as its
value.
*/
import lib.lib
import lib.args
import lib.stat
import lib.stream


void readlink_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: readlink [-n] <path>")
	stream_flush(err)


# 1 when body is one of readlink's own recognized flag names.
int readlink_flag_recognized(char* body):
	if (args_name_matches(body, c"h")):
		return 1
	if (args_name_matches(body, c"help")):
		return 1
	if (args_name_matches(body, c"n")):
		return 1
	return 0


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_has_flag(c"h") || args_has_flag(c"help")):
		readlink_usage()
		return 0
	int no_newline = args_has_bool_flag(c"n")
	int i = 1
	while (i < args_count()):
		char* body = args_flag_body(args_get(i))
		if (body != 0):
			if (readlink_flag_recognized(body) == 0):
				readlink_usage()
				return 1
		i = i + 1
	if (args_positional_count() != 1):
		readlink_usage()
		return 1
	char* path = args_positional(0)
	char* buf = malloc(4096)
	int len = file_readlink(path, buf, 4096)
	if (len < 0):
		wstream* err_out = stderr_writer()
		stream_write_cstr(err_out, c"readlink: cannot read link '")
		stream_write_cstr(err_out, path)
		stream_write_cstr(err_out, c"': ")
		stream_write_cstr(err_out, itoa(len))
		stream_write_line(err_out, c"")
		stream_flush(err_out)
		free(buf)
		return 1
	if (len >= 4096):
		wstream* err_out = stderr_writer()
		stream_write_line(err_out, c"readlink: target too long")
		stream_flush(err_out)
		free(buf)
		return 1
	wstream* out = stdout_writer()
	stream_write_cstr(out, buf)
	if (no_newline == 0):
		stream_write_line(out, c"")
	stream_flush(out)
	free(buf)
	return 0
