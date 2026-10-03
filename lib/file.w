/*
Whole-file helpers built on lib.stream.

These read through a buffered stream rather than the seek-based file_size()
hack, so they also work on non-seekable inputs like /proc files and pipes.

Failures are reported, never dressed up as success: a read error returns
0 rather than truncated text, and file_write_text reports a failed write
or close. These helpers do not sync -- a returned 1 means the bytes
reached the OS, not stable storage. For crash durability use
file_write_durable / fs_replace_durable in lib/fs.w (temp file, fsync,
rename, directory fsync).

Design notes: docs/projects/streams.md
*/
import lib.lib
import lib.io
import lib.stream
import structures.string


# Returns the file contents as a malloc'd NUL-terminated string the caller
# may free, or 0 when the file cannot be opened or a read fails (a read
# error is never returned as truncated contents).
char* file_read_text(char* path):
	wstream* in = stream_open_read(path)
	if (in == 0): return 0
	string_builder* contents = string_new()
	# A regular file's size is only a hint (it may still grow, and pipes
	# and /proc files report nothing useful), but reserving it lets
	# stream_read_all read straight into the result with no regrowth.
	int size = file_size(in.fd)
	if (size > 0): string_reserve(contents, size + in.capacity)
	io_result r
	int status = stream_read_all_checked(in, contents, &r)
	stream_close(in)
	if (status != IO_OK):
		string_free(contents)
		return 0
	char* text = contents.data
	free(contents)
	return text


# Creates or truncates the file (mode rwxr-xr-x before umask) and writes
# length bytes of text. Returns IO_OK, or the status of the failing open,
# write or close with r.transferred = bytes written. A close error is
# reported even after a complete write (the data may not have reached
# the file). No sync: see lib/fs.w for durable writes.
int file_write_text_checked(char* path, char* text, int length, io_result* r):
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 493 = rwxr-xr-x
	int fd = open(path, 577, 493)
	if (fd < 0): return io_result_from_syscall(r, fd)
	io_result closed
	int status = io_write_all(fd, text, length, r)
	io_close(fd, &closed)
	if (status != IO_OK): return status
	if (closed.status != IO_OK):
		r.status = closed.status
		r.native_error = closed.native_error
	return r.status


# Creates or truncates the file. Returns 1 on success, 0 when the open,
# write or close fails.
int file_write_text(char* path, char* text):
	io_result r
	return file_write_text_checked(path, text, strlen(text), &r) == IO_OK


# Returns the file's lines (without newlines) as malloc'd strings the caller
# may free, or 0 when the file cannot be opened or a read fails.
list[char*] file_read_lines(char* path):
	wstream* in = stream_open_read(path)
	if (in == 0): return 0
	list[char*] lines = new list[char*]
	string_builder* line = string_new()
	while (stream_read_line(in, line)): lines.push(strclone(line.data))
	string_free(line)
	int failed = stream_error(in) != IO_OK
	stream_close(in)
	if (failed):
		for char* text in lines: free(text)
		__w_list_free(cast(__w_list*, lines))
		return 0
	return lines
