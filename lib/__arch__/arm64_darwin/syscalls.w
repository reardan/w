# AArch64 Darwin (XNU) syscall wrappers. Numbers come from the BSD table
# (apple-oss-distributions/xnu, bsd/kern/syscalls.master); arguments pass
# in x0..x5 with the number in x16 via the syscall/syscall7 stubs
# (svc #0x80 convention). The stubs convert Darwin's carry-flag + positive
# errno convention to the -errno contract the other targets expose, so
# lib/ stays architecture-agnostic.
#
# The wrapper surface matches lib/__arch__/arm64/syscalls.w exactly. Where
# Darwin has no equivalent raw syscall the wrapper is a documented stub:
# brk always fails (lib/memory.w then runs in mmap mode), rt_sigaction and
# sys_clone return -38 (ENOSYS-style; Darwin signal delivery needs a
# trampoline and threads go through bsdthread_create).
#
# Flag translation: lib/ callers hardcode Linux flag values, so open and
# mmap translate the bits Darwin numbers differently (O_CREAT/O_TRUNC/...,
# MAP_ANON) instead of forking every caller.

# Two words, matching XNU's user64_timeval (tv_sec and tv_usec are both
# 64-bit for 64-bit processes).
struct darwin_timeval:
	int tv_sec
	int tv_usec


# Linux open flag values -> Darwin. Read/write bits (0x3) match; O_CREAT,
# O_EXCL, O_TRUNC, O_APPEND, O_NONBLOCK and O_DIRECTORY are renumbered.
int darwin_open_flags(int mode):
	int flags = mode & 3
	if (mode & 64):
		flags = flags | 512      /* O_CREAT: 0x40 -> 0x200 */
	if (mode & 128):
		flags = flags | 2048     /* O_EXCL: 0x80 -> 0x800 */
	if (mode & 512):
		flags = flags | 1024     /* O_TRUNC: 0x200 -> 0x400 */
	if (mode & 1024):
		flags = flags | 8        /* O_APPEND: 0x400 -> 0x8 */
	if (mode & 2048):
		flags = flags | 4        /* O_NONBLOCK: 0x800 -> 0x4 */
	if (mode & 65536):
		flags = flags | 1048576  /* O_DIRECTORY: 0x10000 -> 0x100000 */
	return flags


/* File IO: */

# open with O_WRONLY|O_CREAT|O_TRUNC (Darwin 0x601 = 1537).
int create_file(char* filename, int permissions):
	return syscall(5, filename, 1537, permissions)

# mode: 0 - read, 1 - write, 2 - readwrite (plus O_CREAT etc., which
# callers pass as Linux values; see darwin_open_flags).
int open(char *filename, int mode, int permissions):
	return syscall(5, filename, darwin_open_flags(mode), permissions)

int write(int file, char* s, int length):
	return syscall(4, file, s, length)

int read(int file, char* buf, int size):
	return syscall(3, file, buf, size)

int close(int file):
	return syscall(6, file, 0, 0)

# reference: 0 - beginning, 1 - current position, 2 - end of file
int seek(int file, int offset, int reference):
	return syscall(199, file, offset, reference)

# Directory syscalls:
int mkdir(char* path, int mode):
	return syscall(136, path, mode, 0)

int rmdir(char* path):
	return syscall(137, path, 0, 0)

int unlink(char* path):
	return syscall(10, path, 0, 0)

int rename(char* oldpath, char* newpath):
	return syscall(128, oldpath, newpath, 0)

# getdirentries64 (344): reads from the fd's offset like the Linux
# getdents flavors; the extra off_t* out-parameter receives the new
# position. NOTE: the Darwin record layout differs from both Linux
# variants (d_ino u64, d_seekoff u64, d_reclen u16, d_namlen u16,
# d_type u8, name), so directory listers need Darwin-aware parsing
# before they run natively.
int getdents(int file, char* buf, int count):
	int position = 0
	return syscall7(344, file, buf, count, cast(int, &position), 0, 0)

int sys_fcntl(int fd, int cmd, int arg):
	return syscall(92, fd, cmd, arg)

# Darwin has no getcwd syscall; libc builds it on fcntl(F_GETPATH = 50,
# xnu bsd/sys/fcntl.h), which fills buf with the fd's path. buf must have
# room for MAXPATHLEN (1024) bytes.
int getcwd(char* buf, int size):
	int fd = open(c".", 0, 0)
	if (fd < 0):
		return fd
	int result = sys_fcntl(fd, 50, cast(int, buf))
	close(fd)
	return result

# No time(2): gettimeofday (116) with a null timezone; the third XNU
# argument (mach_absolute_time out-pointer) is unused.
int linux_time(int* out):
	darwin_timeval tv
	tv.tv_sec = 0
	tv.tv_usec = 0
	syscall(116, cast(int, &tv), 0, 0)
	if (out != 0):
		*out = tv.tv_sec
	return tv.tv_sec

/* memory and threading */
# No brk on Darwin. Returning 0 makes lib/memory.w's first growth check
# (brk(target) == target) fail cleanly, flipping the allocator into its
# mmap mode permanently; the initial malloc_heap_ptr = brk(0) stays 0, so
# no live block can sit below the failed break.
int brk(char* addr):
	return 0

# mmap (197). Darwin renumbers MAP_ANON (0x1000, Linux 0x20); MAP_SHARED,
# MAP_PRIVATE and MAP_FIXED match Linux. The x86-only MAP_32BIT (0x40) is
# dropped. fd must be -1 for anonymous mappings; the offset is in bytes.
int mmap(int addr, int length, int prot, int flags):
	int darwin_flags = flags & 19 /* MAP_SHARED|MAP_PRIVATE|MAP_FIXED */
	if (flags & 32):
		darwin_flags = darwin_flags | 4096 /* MAP_ANON */
	return syscall7(197, addr, length, prot, darwin_flags, -1, 0)

# munmap (73): releases a mapping created by mmap. addr must be page-aligned.
int munmap(int addr, int length):
	return syscall(73, addr, length, 0)

# No clone on Darwin (threads go through bsdthread_create, a later stage).
int sys_clone(int flags, int child_stack):
	return 0 - 38

# poll (230): fds points at an array of 8-byte pollfd records.
# timeout_ms < 0 blocks forever; 0 returns immediately.
int sys_poll(int fds, int nfds, int timeout_ms):
	return syscall(230, fds, nfds, timeout_ms)

# ioctl (54): request values like TCGETS/TCSETS come from lib/termios.w
# and are Linux-numbered; terminal control needs Darwin request values
# before it works natively.
int sys_ioctl(int fd, int request, int arg):
	return syscall(54, fd, request, arg)

# mincore (78): one residency byte per page in vec.
int sys_mincore(int addr, int length, int vec):
	return syscall(78, addr, length, vec)

# Darwin has no nanosleep syscall; sleep on select (93) with an empty fd
# set and the interval as the timeout, the classic BSD idiom.
int darwin_sleep(int sec, int nsec):
	darwin_timeval tv
	tv.tv_sec = sec
	tv.tv_usec = nsec / 1000
	return syscall7(93, 0, 0, 0, 0, cast(int, &tv), 0)

# req/rem point at { long seconds; long nanoseconds }; rem is ignored.
int sys_nanosleep(int req, int rem):
	int* r = cast(int*, req)
	return darwin_sleep(r[0], r[1])

# Darwin has no clock_gettime syscall; both wrappers read the wall clock
# via gettimeofday (116) whatever clock_id asks for. Good enough for the
# relative timing lib/time.w does, but NOT truly monotonic.
int sys_clock_gettime(int clock_id, int ts):
	darwin_timeval tv
	tv.tv_sec = 0
	tv.tv_usec = 0
	int err = syscall(116, cast(int, &tv), 0, 0)
	if (err < 0):
		return err
	int* out = cast(int*, ts)
	out[0] = tv.tv_sec
	out[1] = tv.tv_usec * 1000
	return 0

# Raw sigaction (46) takes a struct __sigaction whose sa_tramp field must
# point at a signal-return trampoline; without libc's trampoline the
# kernel would jump to 0 on delivery. Stubbed out until a W trampoline
# exists (only the debugger uses this, and wdbg on arm64 is deferred).
int rt_sigaction(int signum, int* act, int* oldact):
	return 0 - 38


/* Process management */

# fork (2) returns two values on Darwin: x0 = pid, x1 = 1 in the child.
# The syscall_fork stub (code_generator/arm64_asm.w) folds that into the
# child-sees-0 contract.
int fork():
	return syscall_fork()

# argv and envp are NULL-terminated vectors of char* (word-sized entries).
int execve(char* path, char** argv, char** envp):
	return syscall(59, path, argv, envp)

# Reaps a child. pid -1 waits for any child; options 1 is WNOHANG.
int wait4(int pid, int* status, int options, int rusage):
	return syscall7(7, pid, status, options, rusage, 0, 0)

# pipe (42) returns the two fds in x0/x1 instead of writing through a
# pointer; the syscall_pipe stub (code_generator/arm64_asm.w) stores them
# as two 32-bit fds, matching the other targets' contract.
int pipe(int* fds):
	return syscall_pipe(fds)

int dup2(int oldfd, int newfd):
	return syscall(90, oldfd, newfd, 0)

# kill (37) has a third 'posix' argument on Darwin; libc passes 1 for
# POSIX-conformant semantics.
int kill(int pid, int sig):
	return syscall(37, pid, sig, 1)


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


# ptrace is unsupported on Darwin here; the stub keeps the debugger's
# attach module linkable (attach mode is Linux x86/x86-64 only).
int sys_ptrace(int request, int pid, int addr, int data):
	return -1

int chdir(char* path):
	return syscall(12, path, 0, 0)

int getpid():
	return syscall(20, 0, 0, 0)

# req points at a two-word timespec (seconds, nanoseconds). rem may be 0.
int nanosleep(int* req, int* rem):
	return darwin_sleep(req[0], req[1])

# fds points at an array of pollfd structs (8 bytes each).
int poll(int* fds, int nfds, int timeout_ms):
	return syscall(230, fds, nfds, timeout_ms)

# clock_id is ignored; see sys_clock_gettime. out points at a two-word
# timespec.
int clock_gettime(int clock_id, int* out):
	return sys_clock_gettime(clock_id, cast(int, out))


/* Native socket syscalls on Darwin. */
int sys_socket(int family, int socket_type, int protocol):
	return syscall(97, family, socket_type, protocol)


int sys_connect(int sockfd, int addr, int addrlen):
	return syscall(98, sockfd, addr, addrlen)


int sys_accept(int sockfd, int addr, int addrlen):
	return syscall(30, sockfd, addr, addrlen)


int sys_sendto(int sockfd, char* buf, int len, int flags, int addr, int addrlen):
	return syscall7(133, sockfd, buf, len, flags, addr, addrlen)


int sys_bind(int sockfd, int addr, int addrlen):
	return syscall(104, sockfd, addr, addrlen)


int sys_listen(int sockfd, int backlog):
	return syscall(106, sockfd, backlog, 0)


int sys_getsockname(int sockfd, int addr, int addrlen):
	return syscall(32, sockfd, addr, addrlen)


int sys_socketpair(int family, int socket_type, int protocol, int fds):
	return syscall7(135, family, socket_type, protocol, fds, 0, 0)


# recvfrom (29) with a null address doubles as recv.
int sys_recv(int sockfd, char* buf, int len, int flags):
	return syscall7(29, sockfd, buf, len, flags, 0, 0)


int sys_recvfrom(int sockfd, char* buf, int len, int flags, int addr, int addrlen):
	return syscall7(29, sockfd, buf, len, flags, addr, addrlen)


int sys_setsockopt(int sockfd, int level, int optname, int optval, int optlen):
	return syscall7(105, sockfd, level, optname, optval, optlen, 0)

# Darwin has no getrandom syscall, so there is no number to put here.
# Return -38 (ENOSYS-style, like the other stubs) so callers such as
# libs/standard/crypto/random.w take their /dev/urandom fallback path.
int sys_getrandom(char* buf, int buflen, int flags):
	return 0 - 38

# exit (1): terminates the whole process, like libc exit().
void exit(int error_code):
	syscall(1, error_code, 0, 0)

# bsdthread_terminate (361) with no stack to free and no port/semaphore
# to signal: terminates only the calling thread.
void thread_exit(int error_code):
	syscall7(361, 0, 0, 0, 0, 0, 0)
