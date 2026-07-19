/*
stat: print file metadata, dogfooding lib/stat.w.

Usage: stat [-f|--nofollow] <path>...

Default follows symlinks (stat(2)). -f / --nofollow uses lstat(2).
Prints a short human-readable block per path. Exit 1 if any path fails.

Boolean flags are parsed by hand: lib/args.w treats the token after a
bare -flag as that flag's value, which would swallow the first path.
*/
import lib.lib
import lib.stat
import lib.stream


void stat_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: stat [-f|--nofollow] <path>...")
	stream_flush(err)


void stat_print_octal(wstream* out, int mode):
	char* digits = malloc(5)
	digits[4] = 0
	int i = 3
	int v = mode & 4095
	while (i >= 0):
		digits[i] = (v & 7) + '0'
		v = v / 8
		i = i - 1
	stream_write_cstr(out, digits)
	free(digits)


void stat_print_type(wstream* out, file_stat* st):
	if (file_is_reg(st)):
		stream_write_cstr(out, c"regular file")
	else if (file_is_dir(st)):
		stream_write_cstr(out, c"directory")
	else if (file_is_lnk(st)):
		stream_write_cstr(out, c"symbolic link")
	else:
		stream_write_cstr(out, c"other")


int stat_print_one(char* path, int nofollow):
	file_stat st
	int err = 0
	if (nofollow):
		err = file_lstat_path(path, &st)
	else:
		err = file_stat_path(path, &st)
	if (err != 0):
		wstream* err_out = stderr_writer()
		stream_write_cstr(err_out, c"stat: cannot stat '")
		stream_write_cstr(err_out, path)
		stream_write_cstr(err_out, c"': ")
		stream_write_cstr(err_out, itoa(err))
		stream_write_line(err_out, c"")
		stream_flush(err_out)
		return 1
	wstream* out = stdout_writer()
	stream_write_cstr(out, c"  File: ")
	stream_write_line(out, path)
	stream_write_cstr(out, c"  Size: ")
	stream_write_cstr(out, itoa(st.size))
	stream_write_cstr(out, c"\tType: ")
	stat_print_type(out, &st)
	stream_write_line(out, c"")
	stream_write_cstr(out, c"  Mode: ")
	stat_print_octal(out, file_mode_perm(&st))
	stream_write_cstr(out, c"\tUid: ")
	stream_write_cstr(out, itoa(st.uid))
	stream_write_cstr(out, c"\tGid: ")
	stream_write_cstr(out, itoa(st.gid))
	stream_write_line(out, c"")
	stream_write_cstr(out, c"Access: ")
	stream_write_cstr(out, itoa(st.atime))
	stream_write_line(out, c"")
	stream_write_cstr(out, c"Modify: ")
	stream_write_cstr(out, itoa(st.mtime))
	stream_write_line(out, c"")
	stream_write_cstr(out, c"Change: ")
	stream_write_cstr(out, itoa(st.ctime))
	stream_write_line(out, c"")
	stream_flush(out)
	return 0


int main(int argc, int argv):
	int nofollow = 0
	int path_count = 0
	char** paths = cast(char**, malloc(argc * __word_size__))
	int i = 1
	while (i < argc):
		char** slot = argv + i * __word_size__
		char* arg = *slot
		if ((strcmp(arg, c"-h") == 0) | (strcmp(arg, c"--help") == 0)):
			stat_usage()
			free(cast(void*, paths))
			return 0
		if ((strcmp(arg, c"-f") == 0) | (strcmp(arg, c"--nofollow") == 0)):
			nofollow = 1
		else if (arg[0] == '-'):
			stat_usage()
			free(cast(void*, paths))
			return 1
		else:
			save_word(cast(char*, paths) + path_count * __word_size__, cast(int, arg))
			path_count = path_count + 1
		i = i + 1
	if (path_count < 1):
		stat_usage()
		free(cast(void*, paths))
		return 1
	int failed = 0
	i = 0
	while (i < path_count):
		char* path = cast(char*, load_word(cast(char*, paths) + i * __word_size__))
		failed = failed | stat_print_one(path, nofollow)
		i = i + 1
	free(cast(void*, paths))
	return failed
