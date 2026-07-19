/*
readlink: print the target of a symbolic link.

Usage: readlink [-n] <path>

-n suppresses the trailing newline. Boolean flags are parsed by hand
because lib/args.w would treat the path as the flag's value.
*/
import lib.lib
import lib.stat
import lib.stream


void readlink_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: readlink [-n] <path>")
	stream_flush(err)


int main(int argc, int argv):
	int no_newline = 0
	char* path = 0
	int i = 1
	while (i < argc):
		char** slot = argv + i * __word_size__
		char* arg = *slot
		if ((strcmp(arg, c"-h") == 0) | (strcmp(arg, c"--help") == 0)):
			readlink_usage()
			return 0
		if (strcmp(arg, c"-n") == 0):
			no_newline = 1
		else if (arg[0] == '-'):
			readlink_usage()
			return 1
		else:
			if (path != 0):
				readlink_usage()
				return 1
			path = arg
		i = i + 1
	if (path == 0):
		readlink_usage()
		return 1
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
