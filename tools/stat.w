/*
stat: print file metadata, dogfooding lib/stat.w.

Usage: stat [-f|--nofollow] <path>...

Default follows symlinks (stat(2)). -f / --nofollow uses lstat(2).
Prints a short human-readable block per path. Exit 1 if any path fails.

-f/--nofollow are declared boolean flags (lib/args.w's args_has_bool_flag)
so a bare -f directly before a path doesn't swallow it as the flag's
value.
*/
import lib.lib
import lib.args
import lib.stat
import lib.passwd
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
	char* user = passwd_uid_name(st.uid)
	if (user != 0):
		stream_write_cstr(out, c" (")
		stream_write_cstr(out, user)
		stream_write_cstr(out, c")")
		free(user)
	stream_write_cstr(out, c"\tGid: ")
	stream_write_cstr(out, itoa(st.gid))
	char* group = passwd_gid_name(st.gid)
	if (group != 0):
		stream_write_cstr(out, c" (")
		stream_write_cstr(out, group)
		stream_write_cstr(out, c")")
		free(group)
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


# 1 when body is one of stat's own recognized flag names.
int stat_flag_recognized(char* body):
	if (args_name_matches(body, c"h")):
		return 1
	if (args_name_matches(body, c"help")):
		return 1
	if (args_name_matches(body, c"f")):
		return 1
	if (args_name_matches(body, c"nofollow")):
		return 1
	return 0


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_has_flag(c"h") || args_has_flag(c"help")):
		stat_usage()
		return 0
	int nofollow = args_has_bool_flag(c"f") || args_has_bool_flag(c"nofollow")
	int i = 1
	while (i < args_count()):
		char* body = args_flag_body(args_get(i))
		if (body != 0):
			if (stat_flag_recognized(body) == 0):
				stat_usage()
				return 1
		i = i + 1
	int path_count = args_positional_count()
	if (path_count < 1):
		stat_usage()
		return 1
	int failed = 0
	i = 0
	while (i < path_count):
		char* path = args_positional(i)
		failed = failed | stat_print_one(path, nofollow)
		i = i + 1
	return failed
