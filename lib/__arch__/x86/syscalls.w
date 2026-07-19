# x86 (i386) 32-bit Linux syscall wrappers. Numbers come from
# arch/x86/entry/syscalls/syscall_32.tbl; arguments pass in registers via
# the syscall/syscall7 stubs (int 0x80 convention).

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

int unlink(char* path):
	return syscall(10, path, 0, 0)

# fsync (118): flushes the file's data and metadata to stable storage.
# Returns 0, or a negative errno (e.g. -9 EBADF on a closed fd).
int fsync(int file):
	return syscall(118, file, 0, 0)

# fdatasync (148): like fsync, but may skip metadata-only updates.
int fdatasync(int file):
	return syscall(148, file, 0, 0)

# Directory syscalls:
int mkdir(char* path, int mode):
	return syscall(39, path, mode, 0)

int rmdir(char* path):
	return syscall(40, path, 0, 0)

int rename(char* oldpath, char* newpath):
	return syscall(38, oldpath, newpath, 0)

int getdents(int file, char* buf, int count):
	return syscall(141, file, buf, count)

int getcwd(char* buf, int size):
	return syscall(183, buf, size, 0)

# File metadata / mode / links (see lib/stat.w for the portable parsers).

# AT_FDCWD for *at syscalls that take a dirfd.
int at_fdcwd():
	return 0 - 100


# AT_SYMLINK_NOFOLLOW for lstat-style lookups.
int at_symlink_nofollow():
	return 256


# statx (383): fills a 256-byte struct statx (uapi/linux/stat.h). dirfd
# is AT_FDCWD; `flags` is 0 to follow symlinks or AT_SYMLINK_NOFOLLOW to
# not; `mask` is usually STATX_BASIC_STATS (2047). Returns 0 or -errno.
int statx(char* path, int flags, int mask, char* buf):
	return syscall7(383, at_fdcwd(), path, flags, mask, buf, 0)


# chmod (15): set permission bits on `path`.
int chmod(char* path, int mode):
	return syscall(15, path, mode, 0)


# utimensat (320): set atime/mtime. times == 0 means "now" for both.
int utimensat(char* path, int times, int flags):
	return syscall7(320, at_fdcwd(), path, times, flags, 0, 0)


# readlink (85): copy the symlink target into buf (not NUL-terminated).
# Returns the byte count written, or a negative errno.
int readlink(char* path, char* buf, int size):
	return syscall(85, path, buf, size)


# symlink (83): create linkpath pointing at target.
int symlink(char* target, char* linkpath):
	return syscall(83, target, linkpath, 0)


# i386 time(2) returns a 32-bit time_t and overflows after 2038-01-19
# 03:14:07 UTC. Use clock_gettime64 (403) here in the future.
int linux_time(int* out):
	return syscall(13, out, 0, 0)

/* memory and threading */
# The heap allocator built on brk lives in lib/memory.w
int brk(char* addr):
	return syscall(45, addr, 0, 0)

# mmap2 (192): register-based 6-arg convention; old_mmap (90) wants an arg struct pointer.
# fd must be -1 for MAP_ANONYMOUS mappings; offset is in 4096-byte pages.
int mmap(int addr, int length, int prot, int flags):
	return syscall7(192, addr, length, prot, flags, -1, 0)

# munmap (91): releases a mapping created by mmap. addr must be page-aligned.
int munmap(int addr, int length):
	return syscall(91, addr, length, 0)

# mprotect (125): changes page protection (PROT_NONE=0, READ=1, WRITE=2,
# EXEC=4) on an existing mapping. addr and length must be page-aligned.
int mprotect(int addr, int length, int prot):
	return syscall(125, addr, length, prot)

# clone: the trailing 0 pads to syscall's fixed nr + 3 slots (the third
# kernel argument is unused here); without it the nr slot read garbage.
int sys_clone(int flags, int child_stack):
	return syscall(56, flags, child_stack, 0)

# futex (240): uaddr points at a 32-bit futex word. futex_op is
# FUTEX_WAIT (0) / FUTEX_WAKE (1), usually with FUTEX_PRIVATE_FLAG (128)
# for the CLONE_VM threads of lib/thread.w. For WAIT, val is the
# expected word value and timeout may be 0 to block forever; for WAKE,
# val is the number of waiters to wake. The unused uaddr2/val3 slots
# pass 0 via syscall7.
int sys_futex(int uaddr, int futex_op, int val, int timeout):
	return syscall7(240, uaddr, futex_op, val, timeout, 0, 0)

# poll (168): fds points at an array of 8-byte pollfd records.
# timeout_ms < 0 blocks forever; 0 returns immediately.
int sys_poll(int fds, int nfds, int timeout_ms):
	return syscall(168, fds, nfds, timeout_ms)

int sys_fcntl(int fd, int cmd, int arg):
	return syscall(55, fd, cmd, arg)

# ioctl (54): request values like TCGETS/TCSETS come from lib/termios.w.
int sys_ioctl(int fd, int request, int arg):
	return syscall(54, fd, request, arg)

# mincore (218): one residency byte per page in vec; fails with -ENOMEM
# when the range is not fully mapped, which makes it a safe read probe.
int sys_mincore(int addr, int length, int vec):
	return syscall(218, addr, length, vec)

# nanosleep (162): req/rem point at { long seconds; long nanoseconds }
# which matches two W words on i386.
int sys_nanosleep(int req, int rem):
	return syscall(162, req, rem, 0)

# clock_gettime (265): the 32-bit timespec is fine for CLOCK_MONOTONIC
# (seconds since boot), which is this wrapper's intended use.
int sys_clock_gettime(int clock_id, int ts):
	return syscall(265, clock_id, ts, 0)

# rt_sigaction (174). sigsetsize must be _NSIG/8 = 8 on i386. When act has
# no SA_RESTORER the kernel points the signal frame's return address at the
# vdso sigreturn trampoline, so plain W functions work as handlers.
int rt_sigaction(int signum, int* act, int* oldact):
	return syscall7(174, signum, act, oldact, 8, 0, 0)


/* Process management */

# Returns the child pid in the parent and 0 in the child; the child gets a
# copy-on-write duplicate of the address space and stack.
int fork():
	return syscall(2, 0, 0, 0)

# argv and envp are NULL-terminated vectors of char* (word-sized entries).
# Only returns on failure; on success the process image is replaced.
int execve(char* path, char** argv, char** envp):
	return syscall(11, path, argv, envp)

# Reaps a child. pid -1 waits for any child; options 1 is WNOHANG. status
# receives the raw wait status (may be 0 to discard). rusage should be 0.
int wait4(int pid, int* status, int options, int rusage):
	return syscall7(114, pid, status, options, rusage, 0, 0)

# The kernel writes two 32-bit fds (read end, write end) to fds on both
# architectures, so callers should read them back with load_int32.
int pipe(int* fds):
	return syscall(42, fds, 0, 0)

int dup2(int oldfd, int newfd):
	return syscall(63, oldfd, newfd, 0)

int kill(int pid, int sig):
	return syscall(37, pid, sig, 0)


# Returns 1 when running on Windows, 0 on all other platforms.
int os_windows():
	return 0


# Win32 API surface used by the os_windows()-guarded paths in shared
# modules (lib/process.w's CreateProcessA spawning, tools/wexec.w's
# FindFirstFileA directory walk). Those paths never run on this target;
# the stubs only keep the modules linkable -- the mirror image of the
# Unix-primitive stubs at the bottom of lib/__arch__/win64/syscalls.w.
# Each returns its Win32 failure value.

int CloseHandle(int handle):
	return 0


int GetStdHandle(int which):
	return -1


int CreateFileA(char* path, int access, int share, int security, int creation, int flags, int template_file):
	return -1


int CreatePipe(int* read_end, int* write_end, int security, int size):
	return 0


int SetHandleInformation(int handle, int mask, int flags):
	return 0


int CreateProcessA(char* app, char* cmdline, int proc_attr, int thread_attr, int inherit_handles, int flags, int env, char* dir, char* startup_info, char* proc_info):
	return 0


int WaitForSingleObject(int handle, int milliseconds):
	return -1


int GetExitCodeProcess(int handle, int* code):
	return 0


int TerminateProcess(int handle, int exit_code):
	return 0


int PeekNamedPipe(int handle, char* buf, int buf_size, int* bytes_read, int* bytes_avail, int* bytes_left):
	return 0


int FindFirstFileA(char* pattern, char* find_data):
	return -1


int FindNextFileA(int handle, char* find_data):
	return 0


int FindClose(int handle):
	return 0


# ptrace (26). request/pid/addr/data follow the classic ptrace(2) ABI.
# For PTRACE_PEEK* the raw syscall (unlike the glibc wrapper) writes the
# read word to *data and returns 0, so callers pass a word pointer as data
# and read it back; for PTRACE_POKE* data is the value to write.
int sys_ptrace(int request, int pid, int addr, int data):
	return syscall7(26, request, pid, addr, data, 0, 0)

int chdir(char* path):
	return syscall(12, path, 0, 0)

int getpid():
	return syscall(20, 0, 0, 0)

# req points at a timespec whose two fields (seconds, nanoseconds) are
# word-sized: 32-bit on i386, 64-bit on x86-64. rem may be 0.
int nanosleep(int* req, int* rem):
	return syscall(162, req, rem, 0)

# fds points at an array of pollfd structs: int fd, short events,
# short revents (8 bytes each on both architectures).
int poll(int* fds, int nfds, int timeout_ms):
	return syscall(168, fds, nfds, timeout_ms)

# clock_id 1 is CLOCK_MONOTONIC. out points at a timespec whose two fields
# (seconds, nanoseconds) are word-sized, like nanosleep's. The i386 variant
# keeps 32-bit fields; clock_gettime64 (403) is the future 2038 fix.
int clock_gettime(int clock_id, int* out):
	return syscall(265, clock_id, out, 0)


/* Socket syscalls use the i386 socketcall(2) multiplexer. */
struct sys_socket_args:
	int family
	int socket_type
	int protocol


struct sys_bind_args:
	int sockfd
	int addr
	int addrlen


struct sys_connect_args:
	int sockfd
	int addr
	int addrlen


struct sys_listen_args:
	int sockfd
	int backlog


struct sys_accept_args:
	int sockfd
	int addr
	int addrlen


struct sys_getsockname_args:
	int sockfd
	int addr
	int addrlen


struct sys_socketpair_args:
	int family
	int socket_type
	int protocol
	int fds


struct sys_sendto_args:
	int sockfd
	char* buf
	int len
	int flags
	int addr
	int addrlen


struct sys_setsockopt_args:
	int sockfd
	int level
	int optname
	int optval
	int optlen


struct sys_recv_args:
	int sockfd
	char* buf
	int len
	int flags


struct sys_recvfrom_args:
	int sockfd
	char* buf
	int len
	int flags
	int addr
	int addrlen


int sys_socket(int family, int socket_type, int protocol):
	sys_socket_args args
	args.family = family
	args.socket_type = socket_type
	args.protocol = protocol
	return syscall(102, 1, &args, 0)


int sys_bind(int sockfd, int addr, int addrlen):
	sys_bind_args args
	args.sockfd = sockfd
	args.addr = addr
	args.addrlen = addrlen
	return syscall(102, 2, &args, 0)


int sys_connect(int sockfd, int addr, int addrlen):
	sys_connect_args args
	args.sockfd = sockfd
	args.addr = addr
	args.addrlen = addrlen
	return syscall(102, 3, &args, 0)


int sys_listen(int sockfd, int backlog):
	sys_listen_args args
	args.sockfd = sockfd
	args.backlog = backlog
	return syscall(102, 4, &args, 0)


int sys_accept(int sockfd, int addr, int addrlen):
	sys_accept_args args
	args.sockfd = sockfd
	args.addr = addr
	args.addrlen = addrlen
	return syscall(102, 5, &args, 0)


int sys_getsockname(int sockfd, int addr, int addrlen):
	sys_getsockname_args args
	args.sockfd = sockfd
	args.addr = addr
	args.addrlen = addrlen
	return syscall(102, 6, &args, 0)


int sys_socketpair(int family, int socket_type, int protocol, int fds):
	sys_socketpair_args args
	args.family = family
	args.socket_type = socket_type
	args.protocol = protocol
	args.fds = fds
	return syscall(102, 8, &args, 0)


int sys_sendto(int sockfd, char* buf, int len, int flags, int addr, int addrlen):
	sys_sendto_args args
	args.sockfd = sockfd
	args.buf = buf
	args.len = len
	args.flags = flags
	args.addr = addr
	args.addrlen = addrlen
	return syscall(102, 11, &args, 0)


int sys_recv(int sockfd, char* buf, int len, int flags):
	sys_recv_args args
	args.sockfd = sockfd
	args.buf = buf
	args.len = len
	args.flags = flags
	return syscall(102, 10, &args, 0)


# addr/addrlen may be 0 to ignore the sender address; addrlen is an in/out
# pointer to the address buffer size.
int sys_recvfrom(int sockfd, char* buf, int len, int flags, int addr, int addrlen):
	sys_recvfrom_args args
	args.sockfd = sockfd
	args.buf = buf
	args.len = len
	args.flags = flags
	args.addr = addr
	args.addrlen = addrlen
	return syscall(102, 12, &args, 0)


int sys_setsockopt(int sockfd, int level, int optname, int optval, int optlen):
	sys_setsockopt_args args
	args.sockfd = sockfd
	args.level = level
	args.optname = optname
	args.optval = optval
	args.optlen = optlen
	return syscall(102, 14, &args, 0)

# getrandom (355): fills buf with up to buflen bytes from the kernel
# CSPRNG. flags 0 blocks until the entropy pool is initialized.
int sys_getrandom(char* buf, int buflen, int flags):
	return syscall(355, buf, buflen, flags)

# exit_group: terminates every thread in the process, like libc exit().
void exit(int error_code):
	syscall(252, error_code, 0, 0)

# exit: terminates only the calling thread.
void thread_exit(int error_code):
	syscall(1, error_code, 0, 0)
