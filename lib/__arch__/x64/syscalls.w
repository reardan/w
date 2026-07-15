# x86-64 Linux syscall wrappers. Numbers come from
# arch/x86/entry/syscalls/syscall_64.tbl; arguments pass in registers via
# the syscall/syscall7 stubs (syscall instruction convention).

/* File IO: */

int create_file(char* filename, int permissions):
	return syscall(85, filename, permissions, 0)

# mode: 0 - read, 1 - write, 2 - readwrite
int open(char *filename, int mode, int permissions):
	return syscall(2, filename, mode, permissions)

int write(int file, char* s, int length):
	return syscall(1, file, s, length)

int read(int file, char* buf, int size):
	return syscall(0, file, buf, size)

int close(int file):
	return syscall(3, file, 0, 0)

# reference: 0 - beginning, 1 - current position, 2 - end of file
int seek(int file, int offset, int reference):
	return syscall(8, file, offset, reference)

int unlink(char* path):
	return syscall(87, path, 0, 0)

# Directory syscalls:
int mkdir(char* path, int mode):
	return syscall(83, path, mode, 0)

int rmdir(char* path):
	return syscall(84, path, 0, 0)

int getdents(int file, char* buf, int count):
	return syscall(78, file, buf, count)

int getcwd(char* buf, int size):
	return syscall(79, buf, size, 0)

int linux_time(int* out):
	return syscall(201, out, 0, 0)

/* memory and threading */
# The heap allocator built on brk lives in lib/memory.w
int brk(char* addr):
	return syscall(12, addr, 0, 0)

# mmap (9) takes all six arguments in registers; fd must be -1 for
# MAP_ANONYMOUS mappings and the offset is in bytes.
int mmap(int addr, int length, int prot, int flags):
	return syscall7(9, addr, length, prot, flags, -1, 0)

# munmap (11): releases a mapping created by mmap. addr must be page-aligned.
int munmap(int addr, int length):
	return syscall(11, addr, length, 0)

# mprotect (10): changes page protection (PROT_NONE=0, READ=1, WRITE=2,
# EXEC=4) on an existing mapping. addr and length must be page-aligned.
int mprotect(int addr, int length, int prot):
	return syscall(10, addr, length, prot)

# clone: the trailing 0 pads to syscall's fixed nr + 3 slots (the third
# kernel argument is unused here); without it the nr slot read garbage.
int sys_clone(int flags, int child_stack):
	return syscall(56, flags, child_stack, 0)

# futex (202): uaddr points at a 32-bit futex word (the low half of a
# W word on this target). futex_op is FUTEX_WAIT (0) / FUTEX_WAKE (1),
# usually with FUTEX_PRIVATE_FLAG (128) for the CLONE_VM threads of
# lib/thread.w. For WAIT, val is the expected word value and timeout
# may be 0 to block forever; for WAKE, val is the number of waiters to
# wake. The unused uaddr2/val3 slots pass 0 via syscall7.
int sys_futex(int uaddr, int futex_op, int val, int timeout):
	return syscall7(202, uaddr, futex_op, val, timeout, 0, 0)

# poll (7): fds points at an array of 8-byte pollfd records.
# timeout_ms < 0 blocks forever; 0 returns immediately.
int sys_poll(int fds, int nfds, int timeout_ms):
	return syscall(7, fds, nfds, timeout_ms)

int sys_fcntl(int fd, int cmd, int arg):
	return syscall(72, fd, cmd, arg)

# ioctl (16): request values like TCGETS/TCSETS come from lib/termios.w.
int sys_ioctl(int fd, int request, int arg):
	return syscall(16, fd, request, arg)

# mincore (27): one residency byte per page in vec; fails with -ENOMEM
# when the range is not fully mapped, which makes it a safe read probe.
int sys_mincore(int addr, int length, int vec):
	return syscall(27, addr, length, vec)

# nanosleep (35): req/rem point at { long seconds; long nanoseconds }
# which matches two W words on x86-64.
int sys_nanosleep(int req, int rem):
	return syscall(35, req, rem, 0)

int sys_clock_gettime(int clock_id, int ts):
	return syscall(228, clock_id, ts, 0)

# rt_sigaction (13). sigsetsize must be _NSIG/8 = 8. Unlike i386 the
# x86-64 kernel has no vdso sigreturn fallback, so real handlers need an
# SA_RESTORER trampoline in act.
int rt_sigaction(int signum, int* act, int* oldact):
	return syscall7(13, signum, act, oldact, 8, 0, 0)


/* Process management */

# Returns the child pid in the parent and 0 in the child; the child gets a
# copy-on-write duplicate of the address space and stack.
int fork():
	return syscall(57, 0, 0, 0)

# argv and envp are NULL-terminated vectors of char* (word-sized entries).
# Only returns on failure; on success the process image is replaced.
int execve(char* path, char** argv, char** envp):
	return syscall(59, path, argv, envp)

# Reaps a child. pid -1 waits for any child; options 1 is WNOHANG. status
# receives the raw wait status (may be 0 to discard). rusage should be 0.
int wait4(int pid, int* status, int options, int rusage):
	return syscall7(61, pid, status, options, rusage, 0, 0)

# The kernel writes two 32-bit fds (read end, write end) to fds on both
# architectures, so callers should read them back with load_int32.
int pipe(int* fds):
	return syscall(22, fds, 0, 0)

int dup2(int oldfd, int newfd):
	return syscall(33, oldfd, newfd, 0)

int kill(int pid, int sig):
	return syscall(62, pid, sig, 0)


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


# ptrace (101). request/pid/addr/data follow the classic ptrace(2) ABI.
# For PTRACE_PEEK* the raw syscall (unlike the glibc wrapper) writes the
# read word to *data and returns 0, so callers pass a word pointer as data
# and read it back; for PTRACE_POKE* data is the value to write.
int sys_ptrace(int request, int pid, int addr, int data):
	return syscall7(101, request, pid, addr, data, 0, 0)

int chdir(char* path):
	return syscall(80, path, 0, 0)

int getpid():
	return syscall(39, 0, 0, 0)

# req points at a timespec whose two fields (seconds, nanoseconds) are
# word-sized: 32-bit on i386, 64-bit on x86-64. rem may be 0.
int nanosleep(int* req, int* rem):
	return syscall(35, req, rem, 0)

# fds points at an array of pollfd structs: int fd, short events,
# short revents (8 bytes each on both architectures).
int poll(int* fds, int nfds, int timeout_ms):
	return syscall(7, fds, nfds, timeout_ms)

# clock_id 1 is CLOCK_MONOTONIC. out points at a timespec whose two fields
# (seconds, nanoseconds) are word-sized, like nanosleep's.
int clock_gettime(int clock_id, int* out):
	return syscall(228, clock_id, out, 0)


/* Native socket syscalls on x86-64. */
int sys_socket(int family, int socket_type, int protocol):
	return syscall(41, family, socket_type, protocol)


int sys_connect(int sockfd, int addr, int addrlen):
	return syscall(42, sockfd, addr, addrlen)


int sys_accept(int sockfd, int addr, int addrlen):
	return syscall(43, sockfd, addr, addrlen)


int sys_sendto(int sockfd, char* buf, int len, int flags, int addr, int addrlen):
	return syscall7(44, sockfd, buf, len, flags, addr, addrlen)


int sys_bind(int sockfd, int addr, int addrlen):
	return syscall(49, sockfd, addr, addrlen)


int sys_listen(int sockfd, int backlog):
	return syscall(50, sockfd, backlog, 0)


int sys_getsockname(int sockfd, int addr, int addrlen):
	return syscall(51, sockfd, addr, addrlen)


int sys_socketpair(int family, int socket_type, int protocol, int fds):
	return syscall7(53, family, socket_type, protocol, fds, 0, 0)


# recvfrom (45) with a null address doubles as recv on x86-64.
int sys_recv(int sockfd, char* buf, int len, int flags):
	return syscall7(45, sockfd, buf, len, flags, 0, 0)


# addr/addrlen may be 0 to ignore the sender address; addrlen is an in/out
# pointer to the address buffer size.
int sys_recvfrom(int sockfd, char* buf, int len, int flags, int addr, int addrlen):
	return syscall7(45, sockfd, buf, len, flags, addr, addrlen)


int sys_setsockopt(int sockfd, int level, int optname, int optval, int optlen):
	return syscall7(54, sockfd, level, optname, optval, optlen, 0)

# getrandom (318): fills buf with up to buflen bytes from the kernel
# CSPRNG. flags 0 blocks until the entropy pool is initialized.
int sys_getrandom(char* buf, int buflen, int flags):
	return syscall(318, buf, buflen, flags)

# exit_group: terminates every thread in the process, like libc exit().
void exit(int error_code):
	syscall(231, error_code, 0, 0)

# exit: terminates only the calling thread.
void thread_exit(int error_code):
	syscall(60, error_code, 0, 0)
