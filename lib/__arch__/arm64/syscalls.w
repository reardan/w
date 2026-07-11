# AArch64 Linux syscall wrappers. Numbers come from the generic syscall
# table (include/uapi/asm-generic/unistd.h); arguments pass in x0..x5 with
# the number in x8 via the syscall/syscall7 stubs (svc #0 convention). The
# result, or a negative errno, comes back in x0 — the same contract the
# x86/x64 wrappers expose, so lib/ stays architecture-agnostic.
#
# AArch64 dropped several legacy calls, so a few wrappers are re-expressed
# in terms of their *at / 64-bit replacements (openat, mkdirat, unlinkat,
# getdents64, pipe2, dup3, ppoll, clock_gettime).

# AT_FDCWD: operate relative to the current working directory.
int arm64_at_fdcwd():
	return 0 - 100


struct arm64_timespec:
	int tv_sec
	int tv_nsec


/* File IO: */

# openat with O_CREAT|O_WRONLY|O_TRUNC (0x241 = 577).
int create_file(char* filename, int permissions):
	return syscall7(56, arm64_at_fdcwd(), filename, 577, permissions, 0, 0)

# mode: 0 - read, 1 - write, 2 - readwrite (plus O_CREAT etc.)
int open(char *filename, int mode, int permissions):
	return syscall7(56, arm64_at_fdcwd(), filename, mode, permissions, 0, 0)

int write(int file, char* s, int length):
	return syscall(64, file, s, length)

int read(int file, char* buf, int size):
	return syscall(63, file, buf, size)

int close(int file):
	return syscall(57, file, 0, 0)

# reference: 0 - beginning, 1 - current position, 2 - end of file
int seek(int file, int offset, int reference):
	return syscall(62, file, offset, reference)

# unlinkat with no flags removes a file.
int unlink(char* path):
	return syscall(35, arm64_at_fdcwd(), path, 0)

# Directory syscalls:
int mkdir(char* path, int mode):
	return syscall7(34, arm64_at_fdcwd(), path, mode, 0, 0, 0)

# unlinkat with AT_REMOVEDIR (0x200).
int rmdir(char* path):
	return syscall(35, arm64_at_fdcwd(), path, 512)

# getdents64: note its record layout differs from the legacy getdents
# (d_type sits right after d_reclen rather than at the record's end).
int getdents(int file, char* buf, int count):
	return syscall(61, file, buf, count)

int getcwd(char* buf, int size):
	return syscall(17, buf, size, 0)

# No time(2) on AArch64: read CLOCK_REALTIME and return the seconds field.
int linux_time(int* out):
	arm64_timespec ts
	ts.tv_sec = 0
	ts.tv_nsec = 0
	syscall(113, 0, cast(int, &ts), 0)
	if (out != 0):
		*out = ts.tv_sec
	return ts.tv_sec

/* memory and threading */
# The heap allocator built on brk lives in lib/memory.w
int brk(char* addr):
	return syscall(214, addr, 0, 0)

# mmap (222): all six arguments in registers; fd must be -1 for
# MAP_ANONYMOUS mappings and the offset is in bytes.
int mmap(int addr, int length, int prot, int flags):
	return syscall7(222, addr, length, prot, flags, -1, 0)

# munmap (215): releases a mapping created by mmap. addr must be page-aligned.
int munmap(int addr, int length):
	return syscall(215, addr, length, 0)

# clone: the trailing 0 pads to syscall's fixed nr + 3 slots (the third
# kernel argument is unused here); without it the nr slot read garbage.
int sys_clone(int flags, int child_stack):
	return syscall(220, flags, child_stack, 0)

# ppoll (73): fds points at an array of 8-byte pollfd records. timeout_ms
# < 0 blocks forever; otherwise it is converted to a timespec.
int arm64_ppoll(int fds, int nfds, int timeout_ms):
	if (timeout_ms < 0):
		return syscall7(73, fds, nfds, 0, 0, 8, 0)
	arm64_timespec ts
	ts.tv_sec = timeout_ms / 1000
	ts.tv_nsec = (timeout_ms % 1000) * 1000000
	return syscall7(73, fds, nfds, cast(int, &ts), 0, 8, 0)

int sys_poll(int fds, int nfds, int timeout_ms):
	return arm64_ppoll(fds, nfds, timeout_ms)

int sys_fcntl(int fd, int cmd, int arg):
	return syscall(25, fd, cmd, arg)

# ioctl (29): request values like TCGETS/TCSETS come from lib/termios.w.
int sys_ioctl(int fd, int request, int arg):
	return syscall(29, fd, request, arg)

# mincore (232): one residency byte per page in vec.
int sys_mincore(int addr, int length, int vec):
	return syscall(232, addr, length, vec)

# nanosleep (101): req/rem point at { long seconds; long nanoseconds }.
int sys_nanosleep(int req, int rem):
	return syscall(101, req, rem, 0)

int sys_clock_gettime(int clock_id, int ts):
	return syscall(113, clock_id, ts, 0)

# rt_sigaction (134). sigsetsize must be _NSIG/8 = 8.
int rt_sigaction(int signum, int* act, int* oldact):
	return syscall7(134, signum, act, oldact, 8, 0, 0)


/* Process management */

# fork via clone(SIGCHLD, 0): child pid in the parent, 0 in the child.
int fork():
	return syscall(220, 17, 0, 0)

# argv and envp are NULL-terminated vectors of char* (word-sized entries).
int execve(char* path, char** argv, char** envp):
	return syscall(221, path, argv, envp)

# Reaps a child. pid -1 waits for any child; options 1 is WNOHANG.
int wait4(int pid, int* status, int options, int rusage):
	return syscall7(260, pid, status, options, rusage, 0, 0)

# pipe2 (59): the kernel writes two 32-bit fds (read end, write end).
int pipe(int* fds):
	return syscall(59, fds, 0, 0)

# dup3 (24): unlike dup2 it requires oldfd != newfd.
int dup2(int oldfd, int newfd):
	return syscall(24, oldfd, newfd, 0)

int kill(int pid, int sig):
	return syscall(129, pid, sig, 0)


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


# ptrace (117). Same classic ABI as x86; wdbg's attach mode only decodes
# x86/x86-64 register frames, so this wrapper exists for build parity.
int sys_ptrace(int request, int pid, int addr, int data):
	return syscall7(117, request, pid, addr, data, 0, 0)

int chdir(char* path):
	return syscall(49, path, 0, 0)

int getpid():
	return syscall(172, 0, 0, 0)

# req points at a two-word timespec (seconds, nanoseconds). rem may be 0.
int nanosleep(int* req, int* rem):
	return syscall(101, req, rem, 0)

# fds points at an array of pollfd structs (8 bytes each).
int poll(int* fds, int nfds, int timeout_ms):
	return arm64_ppoll(cast(int, fds), nfds, timeout_ms)

# clock_id 1 is CLOCK_MONOTONIC. out points at a two-word timespec.
int clock_gettime(int clock_id, int* out):
	return syscall(113, clock_id, out, 0)


/* Native socket syscalls on AArch64. */
int sys_socket(int family, int socket_type, int protocol):
	return syscall(198, family, socket_type, protocol)


int sys_connect(int sockfd, int addr, int addrlen):
	return syscall(203, sockfd, addr, addrlen)


int sys_accept(int sockfd, int addr, int addrlen):
	return syscall(202, sockfd, addr, addrlen)


int sys_sendto(int sockfd, char* buf, int len, int flags, int addr, int addrlen):
	return syscall7(206, sockfd, buf, len, flags, addr, addrlen)


int sys_bind(int sockfd, int addr, int addrlen):
	return syscall(200, sockfd, addr, addrlen)


int sys_listen(int sockfd, int backlog):
	return syscall(201, sockfd, backlog, 0)


int sys_getsockname(int sockfd, int addr, int addrlen):
	return syscall(204, sockfd, addr, addrlen)


int sys_socketpair(int family, int socket_type, int protocol, int fds):
	return syscall7(199, family, socket_type, protocol, fds, 0, 0)


# recvfrom (207) with a null address doubles as recv.
int sys_recv(int sockfd, char* buf, int len, int flags):
	return syscall7(207, sockfd, buf, len, flags, 0, 0)


int sys_recvfrom(int sockfd, char* buf, int len, int flags, int addr, int addrlen):
	return syscall7(207, sockfd, buf, len, flags, addr, addrlen)


int sys_setsockopt(int sockfd, int level, int optname, int optval, int optlen):
	return syscall7(208, sockfd, level, optname, optval, optlen, 0)

# getrandom (278): fills buf with up to buflen bytes from the kernel
# CSPRNG. flags 0 blocks until the entropy pool is initialized.
int sys_getrandom(char* buf, int buflen, int flags):
	return syscall(278, buf, buflen, flags)

# exit_group: terminates every thread in the process, like libc exit().
void exit(int error_code):
	syscall(94, error_code, 0, 0)

# exit: terminates only the calling thread.
void thread_exit(int error_code):
	syscall(93, error_code, 0, 0)
