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

# Directory syscalls:
int mkdir(char* path, int mode):
	return syscall(39, path, mode, 0)

int rmdir(char* path):
	return syscall(40, path, 0, 0)

int getdents(int file, char* buf, int count):
	return syscall(141, file, buf, count)

int getcwd(char* buf, int size):
	return syscall(183, buf, size, 0)

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

int sys_clone(int flags, int child_stack):
	return syscall(56, flags, child_stack)

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

# exit_group: terminates every thread in the process, like libc exit().
void exit(int error_code):
	syscall(252, error_code, 0, 0)

# exit: terminates only the calling thread.
void thread_exit(int error_code):
	syscall(1, error_code, 0, 0)
