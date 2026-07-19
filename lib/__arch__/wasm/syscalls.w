# WebAssembly/WASI "syscall" layer (docs/projects/wasm_backend.md D5).
# wasm has no syscall instruction, so every primitive is implemented on
# the fixed wasi_snapshot_preview1 import set that arrives through the
# module's import section; the compiler wraps each import in a thin
# W-callable stub (wasi_* below, defined by wasm_define_asm_functions in
# code_generator/wasm_module.w — the moral twin of the int-0x80 stubs on
# x86). This module keeps the same function surface as the other per-arch
# modules, so lib/ code compiles unchanged; primitives with no WASI
# equivalent return -1, the win64 convention.
#
# Scratch space for iovecs and out-parameters lives at fixed addresses in
# the reserved low page ([256, 512); single-threaded, like everything on
# this target). WASI errnos are returned positive; the wrappers negate
# them into the -errno convention the W runtime expects.

# The compiler-defined import stubs (all arguments and results are i32;
# u64 rights/precision parameters take a zero-extended 32-bit word).
int wasi_proc_exit(int code);
int wasi_fd_write(int fd, int iovs, int iovs_len, int nwritten_ptr);
int wasi_fd_read(int fd, int iovs, int iovs_len, int nread_ptr);
int wasi_fd_close(int fd);
int wasi_path_open(int dirfd, int dirflags, char* path, int path_len, int oflags, int rights, int fdflags, int out_fd_ptr);
int wasi_args_sizes_get(int argc_ptr, int buf_len_ptr);
int wasi_args_get(int argv_ptr, int buf);
int wasi_path_unlink_file(int dirfd, char* path, int path_len);
int wasi_clock_time_get(int clock, int timespec_ptr);
int wasi_fd_seek(int fd, int offset, int whence, int out_ptr);
int wasi_memory_grow(int pages);
int wasi_memory_size();


# The first preopened directory (WASI convention: fds 0-2 are stdio, 3 is
# the first preopen — "." under tools/run_wasm.sh).
int wasi_preopen_fd():
	return 3


int wasi_cstr_len(char* s):
	int n = 0
	while (s[n]):
		n = n + 1
	return n


/* File IO: */

# mode uses the Linux open(2) flag encoding the rest of lib/ passes in:
# low two bits select read/write, 0x40 is O_CREAT, 0x200 is O_TRUNC,
# 0x400 is O_APPEND. Paths resolve against the preopened directory;
# a leading "/" or "./" is stripped.
int open(char *filename, int mode, int permissions):
	while ((filename[0] == '.') && (filename[1] == '/')):
		filename = filename + 2
	while (filename[0] == '/'):
		filename = filename + 1
	int oflags = 0
	if (mode & 64):
		oflags = oflags | 1     /* CREAT */
	if (mode & 512):
		oflags = oflags | 8     /* TRUNC */
	int fdflags = 0
	if (mode & 1024):
		fdflags = 1             /* APPEND */
	# rights: the regular-file set (read/write/seek/tell/sync/advise/
	# allocate/filestat/poll, 0x08E001FF). Anything broader — directory
	# rights, undefined bits — trips the rights validation in strict
	# preview1 hosts (uvwasi/Node).
	int err = wasi_path_open(wasi_preopen_fd(), 1, filename, wasi_cstr_len(filename), oflags, 0x08E001FF, fdflags, 260)
	if (err):
		return 0 - err
	int* out = cast(int*, 260)
	return *out


int create_file(char* filename, int permissions):
	return open(filename, 577, permissions)   /* O_WRONLY|O_CREAT|O_TRUNC */


int write(int file, char* s, int length):
	int* iov = cast(int*, 256)
	iov[0] = cast(int, s)
	iov[1] = length
	int err = wasi_fd_write(file, 256, 1, 264)
	if (err):
		return 0 - err
	int* out = cast(int*, 264)
	return *out


int read(int file, char* buf, int size):
	int* iov = cast(int*, 256)
	iov[0] = cast(int, buf)
	iov[1] = size
	int err = wasi_fd_read(file, 256, 1, 264)
	if (err):
		return 0 - err
	int* out = cast(int*, 264)
	return *out


int close(int file):
	int err = wasi_fd_close(file)
	if (err):
		return 0 - err
	return 0


int seek(int file, int offset, int reference):
	int err = wasi_fd_seek(file, offset, reference, 272)
	if (err):
		return 0 - err
	int* out = cast(int*, 272)
	return *out


int unlink(char* path):
	while ((path[0] == '.') && (path[1] == '/')):
		path = path + 2
	while (path[0] == '/'):
		path = path + 1
	int err = wasi_path_unlink_file(wasi_preopen_fd(), path, wasi_cstr_len(path))
	if (err):
		return 0 - err
	return 0


# WASI defines fd_sync/fd_datasync, but they are not in the compiler's
# fixed import set (wasm_define_asm_functions); until they are wired
# up these report failure honestly rather than claim durability.
int fsync(int file):
	return -1


int fdatasync(int file):
	return -1


int mkdir(char* path, int mode):
	return -1


int rmdir(char* path):
	return -1


int chdir(char* path):
	return -1


# The WASI "current directory" is the preopen root: report "/" so the
# compiler's upward import search (compile_relative_path) does exactly
# one pass — open() strips the leading slash and resolves against the
# preopen.
int getcwd(char* buf, int size):
	if (size < 2):
		return -1
	buf[0] = '/'
	buf[1] = 0
	return 2


int getdents(int file, char* buf, int count):
	return -1


# Portable metadata wrappers are Linux-first (lib/stat.w).
int at_fdcwd():
	return 0 - 100


int at_symlink_nofollow():
	return 256


int statx(char* path, int flags, int mask, char* buf):
	return -1


int chmod(char* path, int mode):
	return -1


int utimensat(char* path, int times, int flags):
	return -1


int fchownat(char* path, int uid, int gid, int flags):
	return -1


int chown(char* path, int uid, int gid):
	return -1


int lchown(char* path, int uid, int gid):
	return -1


int getuid():
	return -1


int getgid():
	return -1


int readlink(char* path, char* buf, int size):
	return -1


int symlink(char* target, char* linkpath):
	return -1


/* Time */

# time(2): seconds since the epoch; out may be 0.
int linux_time(int* out):
	int err = wasi_clock_time_get(0, 280)
	if (err):
		return 0 - err
	int* ts = cast(int*, 280)
	if (out):
		*out = ts[0]
	return ts[0]


# clock_gettime(2): writes a {seconds, nanoseconds} timespec.
int clock_gettime(int clock_id, int* out):
	int wasi_clock = 0    /* CLOCK_REALTIME */
	if (clock_id == 1):
		wasi_clock = 1    /* CLOCK_MONOTONIC */
	int err = wasi_clock_time_get(wasi_clock, cast(int, out))
	if (err):
		return 0 - err
	return 0


int sys_clock_gettime(int clock_id, int ts):
	return clock_gettime(clock_id, cast(int*, ts))


int nanosleep(int* req, int* rem):
	return -1


int sys_nanosleep(int req, int rem):
	return -1


/* Memory */

# No brk on wasm. Returning 0 makes lib/memory.w's first growth check
# fail cleanly, flipping the allocator into its mmap mode permanently
# (the arm64_darwin module uses the same convention).
int brk(char* addr):
	return 0


int wasm_heap_next

# mmap on memory.grow: a page-aligned bump allocator over the linear
# memory above the data segment. prot/flags are ignored (memory is
# always read-write); munmap is a no-op.
int mmap(int addr, int length, int prot, int flags):
	if (wasm_heap_next == 0):
		wasm_heap_next = wasi_memory_size() << 16
	int base = wasm_heap_next
	int end = base + length
	int have = wasi_memory_size() << 16
	if (end > have):
		int need_pages = ((end - have) + 65535) >> 16
		if (wasi_memory_grow(need_pages) == -1):
			return -1
	wasm_heap_next = (end + 4095) & (0 - 4096)
	return base


int munmap(int addr, int length):
	return 0


# WASI's linear memory has no per-page protection primitive, so guard
# pages (lib/memory_debug.w) can't be enforced here; always report
# failure so callers degrade to bookkeeping-only behavior.
int mprotect(int addr, int length, int prot):
	return -1


int sys_mincore(int addr, int length, int vec):
	return -1


/* Processes */

int getpid():
	return 1


void exit(int error_code):
	wasi_proc_exit(error_code)


void thread_exit(int error_code):
	wasi_proc_exit(error_code)


int fork():
	return -1


int execve(char* path, char** argv, char** envp):
	return -1


int wait4(int pid, int* status, int options, int rusage):
	return -1


int pipe(int* fds):
	return -1


int dup2(int oldfd, int newfd):
	return -1


int kill(int pid, int sig):
	return -1


int os_windows():
	return 0


int sys_ptrace(int request, int pid, int addr, int data):
	return -1


int sys_clone(int flags, int child_stack):
	return -1


int sys_fcntl(int fd, int cmd, int arg):
	return -1


int sys_ioctl(int fd, int request, int arg):
	return -1


int sys_poll(int fds, int nfds, int timeout_ms):
	return -1


int poll(int* fds, int nfds, int timeout_ms):
	return -1


int rt_sigaction(int signum, int* act, int* oldact):
	return -1


/* Startup */

# The wasm entry stub calls __w_wasm_start (see wasm_finish in
# code_generator/wasm_module.w), which rebuilds the W (argc, argv)
# contract from the WASI arguments and chains to _main. Memory comes from
# mmap directly because lib/memory.w's malloc is not necessarily part of
# the program.
int _main(int argc, int argv);


int __w_wasm_start(int stub_argc, int stub_argv):
	if (wasi_args_sizes_get(256, 260)):
		return _main(stub_argc, stub_argv)
	int* argc_p = cast(int*, 256)
	int* buf_len_p = cast(int*, 260)
	int argc = *argc_p
	int buf_len = *buf_len_p
	int block = mmap(0, (argc + 2) * 4 + buf_len, 3, 34)
	if (block == -1):
		return _main(stub_argc, stub_argv)
	int argv = block
	int buf = block + (argc + 2) * 4
	if (wasi_args_get(argv, buf)):
		return _main(stub_argc, stub_argv)
	int* av = cast(int*, argv)
	av[argc] = 0
	av[argc + 1] = 0   /* empty environment vector */
	return _main(argc, argv)
