

/* File IO: */

int create_file(char* filename, int permissions):
	return syscall(8, filename, permissions, 0)

# mode: 0 - read, 1 - write, 2 - readwrite
int open(char *filename, int mode, int permissions):
	return syscall(5, filename, mode, permissions)

int write(int file, char* s, int length):
	return syscall(4, file, s, length)

int read(int file, char* buf, int size):
	return syscall(3, file, buf, size)

int close(int file):
	return syscall(6, file, 0, 0)

# reference: 0 - beginning, 1 - current position, 2 - end of file
int seek(int file, int offset, int reference):
	return syscall(19, file, offset, reference)

# Directory syscalls:
int mkdir(char* path, int mode):
	return syscall(39, path, mode, 0)

int rmdir(char* path):
	return syscall(40, path, 0, 0)

int getdents(int file, char* buf, int count):
	return syscall(141, file, buf, count)

/* memory and threading */
int brk(char* addr):
	return syscall(45, addr, 0, 0)

int malloc(int size):
	int result = brk(0)
	int err = brk(result + size)
	if (err < 0):
		return err
	return result

int mmap(int addr, int length, int prot, int flags):
	return syscall7(90, addr, length, prot, flags, 0, 0)

int sys_clone(int flags, int child_stack):
	return syscall(56, flags, child_stack)

void exit_w(int error_code):
	syscall(1, error_code, 0, 0)

