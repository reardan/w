# x86 32 bit Linux syscalls
import code_generator.integer

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

int getcwd(char* buf, int size):
	return syscall(183, buf, size, 0)

/* memory and threading */
int brk(char* addr):
	return syscall(45, addr, 0, 0)

/*
Free-list allocator.

Every block has an 8-byte header: [size][next]. size counts payload bytes
only; next links free blocks (0 ends the list). malloc searches the free
list first (first fit, splitting large blocks) and only grows the heap with
brk when nothing fits. free() in lib.w pushes blocks back onto the list.
*/
int malloc_free_list
int malloc_heap_ptr
int malloc_heap_end

int malloc(int size):
	if (size < 1):
		size = 1
	# Round up to 8 bytes so blocks stay aligned
	size = ((size + 7) >> 3) << 3

	# First fit from the free list
	int prev = 0
	int block = malloc_free_list
	while (block != 0):
		int block_size = load_int(block)
		if (block_size >= size):
			int next = load_int(block + 4)
			# Split when the remainder can hold a header and a payload
			if (block_size >= size + 16):
				int rest = block + 8 + size
				save_int(rest, block_size - size - 8)
				save_int(rest + 4, next)
				next = rest
				save_int(block, size)
			if (prev == 0):
				malloc_free_list = next
			else:
				save_int(prev + 4, next)
			return block + 8
		prev = block
		block = load_int(block + 4)

	# Nothing fits: bump-allocate, growing the heap in 64KB chunks so most
	# mallocs avoid the two brk syscalls the old allocator paid every time.
	int needed = size + 8
	if (malloc_heap_ptr == 0):
		malloc_heap_ptr = brk(0)
		malloc_heap_end = malloc_heap_ptr
	if (malloc_heap_ptr + needed > malloc_heap_end):
		int chunk = 65536
		if (needed > chunk):
			chunk = ((needed + 65535) >> 16) << 16
		int err = brk(malloc_heap_end + chunk)
		if (err < 0):
			return err
		malloc_heap_end = malloc_heap_end + chunk

	block = malloc_heap_ptr
	malloc_heap_ptr = malloc_heap_ptr + needed
	save_int(block, size)
	return block + 8

# mmap2 (192): register-based 6-arg convention; old_mmap (90) wants an arg struct pointer.
# fd must be -1 for MAP_ANONYMOUS mappings; offset is in 4096-byte pages.
int mmap(int addr, int length, int prot, int flags):
	return syscall7(192, addr, length, prot, flags, -1, 0)

int sys_clone(int flags, int child_stack):
	return syscall(56, flags, child_stack)

# exit_group: terminates every thread in the process, like libc exit().
void exit(int error_code):
	syscall(252, error_code, 0, 0)

# exit: terminates only the calling thread.
void thread_exit(int error_code):
	syscall(1, error_code, 0, 0)
