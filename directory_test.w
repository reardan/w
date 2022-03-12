import testing

/* 
https://man7.org/linux/man-pages/man2/getdents.2.html

struct linux_dirent {
	uint32  d_ino;     Inode number 
	uint32  d_off;     Offset to next linux_dirent 
	uint16 d_reclen;  Length of this linux_dirent 
	char           d_name[];  Filename (null-terminated) 
						length is actually (d_reclen - 2 -
						offsetof(struct linux_dirent, d_name)) 
	
	char           pad;       // Zero padding byte
	char           d_type;    // File type (only since Linux
								// 2.6.4); offset is (d_reclen - 1)
	
}
*/


int print_dirent(char* buf):
	print_int0("inode: ", buf)
	print_int0(", next: ", buf + 4)
	int* len = (buf + 6)
	int length = len >> 16 /* todo: better word translation */
	print_int0(", length: ", length)
	char* type_ptr = buf + length - 1
	int type = type_ptr[0]
	print2(", type: ")
	if (type == 4):
		print2("D")
	else if (type == 8):
		print2("F")
	else:
		print_int0("", type)
	print_string(", name: ", buf + 10)
	return buf + length


void read_directory(int file):
	int buf_size = 10000
	char* buf = malloc(buf_size)
	int dents_result = getdents(file, buf, buf_size)
	print_int("dents_result: ", dents_result)
	translate_syscall_failure(dents_result)
	char* cur = buf
	while (cur < (buf + dents_result)):
		cur = print_dirent(cur)
	println2("")


int ls_longest_filename
int ls_max_line_length
int ls_column

void print_ent(char* buf, int length):
	char* type_ptr = buf + length - 1
	int type = type_ptr[0]
	if (type == 4): /* directory */
		print_color_bg(buf + 10, 31, 44)
	else if (type == 8): /* file */
		print_color(buf + 10, 33)
	else:
		print2(buf + 10)
	print2(" ")


void print_pad(int length):
	while (length > 0):
		print2(" ")
		length = length - 1


int print_dirent_ls(char* buf, int should_print):
	int* len = (buf + 6)
	int length = len >> 16 /* todo: better word translation */
	int str_length = strlen(buf + 10)

	if (str_length > ls_longest_filename):
		ls_longest_filename = str_length

	if (should_print == 0):
		return length

	# Newline if it would extend
	if (ls_column + str_length >= ls_max_line_length):
		println2("")
		ls_column = 0

	int* func = print_ent
	func(buf, length)
	print_pad(ls_longest_filename - str_length)
	ls_column = ls_column + ls_longest_filename

	return length


void print_dirents(char* buf, int max_length, int should_print):
	char* cur = buf
	int index = 0
	ls_column = 0
	while (cur + index < max_length):
		index = index + print_dirent_ls(cur + index, should_print)
	println2("")


void ls(int file):
	ls_longest_filename = 0
	ls_max_line_length = 120
	ls_column = 0
	int buf_size = 10000
	char* buf = malloc(buf_size)
	int dents_result = getdents(file, buf, buf_size)
	print_int("dents_result: ", dents_result)
	translate_syscall_failure(dents_result)
	int max_length = (buf + dents_result)

	# Go through to find longest filename
	println2("")
	print_dirents(buf, max_length, 0)
	println2("")

	# Print entries with justification
	print_dirents(buf, max_length, 1)
	println2("")



void test_directory():
	# O_DIRECTORY 00200000==65536 must be a directory (fcntl.h) WRONG
	# 0x00200000==2097152
	int file = open(".", 65536, 511)
	translate_syscall_failure(file)
	print_int("'.' directory file: ", file)

	# Now print directory entries
	# read_directory(file)
	ls(file)

	close(file)


void a_test_mkdir():
	char* filename = "./test_dir/"
	int file = mkdir(filename, 511)
	translate_syscall_failure(file)
	close(file)

# I know its stupid, but
# this test depends on the previous test_mkdir()
void a_test_rmdir():
	char* filename = "./test_dir/"
	int err = rmdir(filename)
	translate_syscall_failure(err)
