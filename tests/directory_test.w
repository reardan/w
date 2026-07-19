import lib.testing

/*
https://man7.org/linux/man-pages/man2/getdents.2.html

struct linux_dirent {
	unsigned long  d_ino;     // Inode number
	unsigned long  d_off;     // Offset to next linux_dirent
	unsigned short d_reclen;  // Length of this linux_dirent
	char           d_name[];  // Filename (null-terminated)
	char           pad;       // Zero padding byte
	char           d_type;    // File type (only since Linux 2.6.4);
	                          // offset is (d_reclen - 1)
}

d_reclen / d_name sit two words after the start of the record -- same
layout lib/shell_commands.w reads. The old `(buf + 6) >> 16` trick
shifted the pointer address itself; under the freelist heap that
sometimes produced a plausible reclen by accident, but under
W_DEBUG_ALLOC high mmap addresses made reclen huge and walked into the
guard page (SIGSEGV).
*/


int dirent_reclen(char* buf):
	char* p = buf + 2 * __word_size__
	return (p[0] & 255) + ((p[1] & 255) << 8)


char* dirent_name(char* buf):
	return buf + 2 * __word_size__ + 2


char* print_dirent(char* buf):
	int length = dirent_reclen(buf)
	print_int0(c"inode: ", cast(int, buf))
	print_int0(c", next: ", cast(int, buf + __word_size__))
	print_int0(c", length: ", length)
	char* type_ptr = buf + length - 1
	int type = type_ptr[0]
	print2(c", type: ")
	if (type == 4):
		print2(c"D")
	else if (type == 8):
		print2(c"F")
	else:
		print_int0(c"", type)
	print_string(c", name: ", dirent_name(buf))
	return buf + length


void read_directory(int file):
	int buf_size = 10000
	char* buf = malloc(buf_size)
	int dents_result = getdents(file, buf, buf_size)
	print_int(c"dents_result: ", dents_result)
	translate_syscall_failure(dents_result)
	char* cur = buf
	while (cur < (buf + dents_result)):
		cur = print_dirent(cur)
	println2(c"")
	free(buf)


int ls_longest_filename
int ls_max_line_length
int ls_column

void print_ent(char* buf, int length):
	char* type_ptr = buf + length - 1
	int type = type_ptr[0]
	if (type == 4): /* directory */
		print_color_bg(dirent_name(buf), 31, 44)
	else if (type == 8): /* file */
		print_color(dirent_name(buf), 33)
	else:
		print2(dirent_name(buf))
	print2(c" ")


void print_pad(int length):
	while (length > 0):
		print2(c" ")
		length = length - 1


int print_dirent_ls(char* buf, int should_print):
	int length = dirent_reclen(buf)
	int str_length = strlen(dirent_name(buf))

	if (str_length > ls_longest_filename):
		ls_longest_filename = str_length

	if (should_print == 0):
		return length

	# Newline if it would extend
	if (ls_column + str_length >= ls_max_line_length):
		println2(c"")
		ls_column = 0

	print_ent(buf, length)
	print_pad(ls_longest_filename - str_length)
	ls_column = ls_column + ls_longest_filename

	return length


void print_dirents(char* buf, int byte_count, int should_print):
	int index = 0
	ls_column = 0
	while (index < byte_count):
		index = index + print_dirent_ls(buf + index, should_print)
	println2(c"")


void ls(int file):
	ls_longest_filename = 0
	ls_max_line_length = 120
	ls_column = 0
	int buf_size = 10000
	char* buf = malloc(buf_size)
	int dents_result = getdents(file, buf, buf_size)
	print_int(c"dents_result: ", dents_result)
	translate_syscall_failure(dents_result)

	# Go through to find longest filename
	println2(c"")
	print_dirents(buf, dents_result, 0)
	println2(c"")

	# Print entries with justification
	print_dirents(buf, dents_result, 1)
	println2(c"")
	free(buf)


void test_directory():
	# O_DIRECTORY 0x00200000 == 2097152; older comment had the wrong value.
	# 65536 is still accepted by this kernel as directory-only open on ".".
	int file = open(c".", 65536, 511)
	translate_syscall_failure(file)
	print_int(c"'.' directory file: ", file)

	ls(file)

	close(file)


void a_test_mkdir():
	char* filename = c"./test_dir/"
	int file = mkdir(filename, 511)
	translate_syscall_failure(file)
	close(file)

# I know its stupid, but
# this test depends on the previous test_mkdir()
void a_test_rmdir():
	char* filename = c"./test_dir/"
	int err = rmdir(filename)
	translate_syscall_failure(err)
