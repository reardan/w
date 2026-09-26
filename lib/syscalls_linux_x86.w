# Linux syscall wrappers shared by the i386 and x86-64 targets. The two
# kernels expose the same calls with different numbers, so this module
# names every number through the SYS_* enum that
# lib/__arch__/x86/syscalls.w and lib/__arch__/x64/syscalls.w each
# declare before importing it (arch/x86/entry/syscalls/syscall_32.tbl /
# syscall_64.tbl); arguments pass in registers via the syscall/syscall7
# stubs (int 0x80 on i386, the syscall instruction on x86-64). Imported
# only through those two modules, which also keep the one wrapper whose
# shape differs (sys_accept). Everything here is compiled by the seed
# (lib/__arch__/x86 is in w.w's import graph): seed-era syntax only.

/* File IO: */

int create_file(char* filename, int permissions):
	return syscall(SYS_CREAT, filename, permissions, 0)

# mode: 0 - read, 1 - write, 2 - readwrite
int open(char *filename, int mode, int permissions):
	return syscall(SYS_OPEN, filename, mode, permissions)

int write(int file, char* s, int length):
	return syscall(SYS_WRITE, file, s, length)

int read(int file, char* buf, int size):
	return syscall(SYS_READ, file, buf, size)

int close(int file):
	return syscall(SYS_CLOSE, file, 0, 0)

# reference: 0 - beginning, 1 - current position, 2 - end of file
int seek(int file, int offset, int reference):
	return syscall(SYS_LSEEK, file, offset, reference)

int unlink(char* path):
	return syscall(SYS_UNLINK, path, 0, 0)

# fsync: flushes the file's data and metadata to stable storage.
# Returns 0, or a negative errno (e.g. -9 EBADF on a closed fd).
int fsync(int file):
	return syscall(SYS_FSYNC, file, 0, 0)

# fdatasync: like fsync, but may skip metadata-only updates.
int fdatasync(int file):
	return syscall(SYS_FDATASYNC, file, 0, 0)

# Directory syscalls:
int mkdir(char* path, int mode):
	return syscall(SYS_MKDIR, path, mode, 0)

int rmdir(char* path):
	return syscall(SYS_RMDIR, path, 0, 0)

int rename(char* oldpath, char* newpath):
	return syscall(SYS_RENAME, oldpath, newpath, 0)

int getdents(int file, char* buf, int count):
	return syscall(SYS_GETDENTS, file, buf, count)

int getcwd(char* buf, int size):
	return syscall(SYS_GETCWD, buf, size, 0)

# File metadata / mode / links (see lib/stat.w for the portable parsers).

# AT_FDCWD for *at syscalls that take a dirfd.
int at_fdcwd():
	return 0 - 100


# AT_SYMLINK_NOFOLLOW for lstat-style lookups.
const int at_symlink_nofollow = 256


# statx: fills a 256-byte struct statx (uapi/linux/stat.h). dirfd
# is AT_FDCWD; `flags` is 0 to follow symlinks or AT_SYMLINK_NOFOLLOW to
# not; `mask` is usually STATX_BASIC_STATS (2047). Returns 0 or -errno.
int statx(char* path, int flags, int mask, char* buf):
	return syscall7(SYS_STATX, at_fdcwd(), path, flags, mask, buf, 0)


# chmod: set permission bits on `path`.
int chmod(char* path, int mode):
	return syscall(SYS_CHMOD, path, mode, 0)


# utimensat: set atime/mtime. times == 0 means "now" for both;
# otherwise times points at two word-sized timespecs {atime, mtime}.
int utimensat(char* path, int times, int flags):
	return syscall7(SYS_UTIMENSAT, at_fdcwd(), path, times, flags, 0, 0)


# fchownat: uid/gid of -1 leave that id unchanged.
int fchownat(char* path, int uid, int gid, int flags):
	return syscall7(SYS_FCHOWNAT, at_fdcwd(), path, uid, gid, flags, 0)


int chown(char* path, int uid, int gid):
	return fchownat(path, uid, gid, 0)


int lchown(char* path, int uid, int gid):
	return fchownat(path, uid, gid, at_symlink_nofollow)


# The real uid/gid (i386 uses the 32-bit-id variants; see its SYS_GETUID).
int getuid():
	return syscall(SYS_GETUID, 0, 0, 0)


int getgid():
	return syscall(SYS_GETGID, 0, 0, 0)


# readlink: copy the symlink target into buf (not NUL-terminated).
# Returns the byte count written, or a negative errno.
int readlink(char* path, char* buf, int size):
	return syscall(SYS_READLINK, path, buf, size)


# symlink: create linkpath pointing at target.
int symlink(char* target, char* linkpath):
	return syscall(SYS_SYMLINK, target, linkpath, 0)


# time(2): seconds since the epoch (also stored to *out unless out is 0).
# i386's time_t is 32 bits and overflows in 2038; see its SYS_TIME.
int linux_time(int* out):
	return syscall(SYS_TIME, out, 0, 0)

/* memory and threading */
# The heap allocator built on brk lives in lib/memory.w
int brk(char* addr):
	return syscall(SYS_BRK, addr, 0, 0)

# All six arguments pass in registers (i386 uses mmap2, whose offset is
# in 4096-byte pages; x86-64's mmap takes bytes). fd must be -1 for
# MAP_ANONYMOUS mappings; the offset is 0 here either way.
int mmap(int addr, int length, int prot, int flags):
	return syscall7(SYS_MMAP, addr, length, prot, flags, -1, 0)

# munmap: releases a mapping created by mmap. addr must be page-aligned.
int munmap(int addr, int length):
	return syscall(SYS_MUNMAP, addr, length, 0)

# mprotect: changes page protection (PROT_NONE=0, READ=1, WRITE=2,
# EXEC=4) on an existing mapping. addr and length must be page-aligned.
int mprotect(int addr, int length, int prot):
	return syscall(SYS_MPROTECT, addr, length, prot)

# clone: the trailing 0 pads to syscall's fixed nr + 3 slots (the third
# kernel argument is unused here); without it the nr slot read garbage.
int sys_clone(int flags, int child_stack):
	return syscall(SYS_CLONE, flags, child_stack, 0)

# futex: uaddr points at a 32-bit futex word (the low half of a W word
# on x86-64). futex_op is
# FUTEX_WAIT (0) / FUTEX_WAKE (1), usually with FUTEX_PRIVATE_FLAG (128)
# for the CLONE_VM threads of lib/thread.w. For WAIT, val is the
# expected word value and timeout may be 0 to block forever; for WAKE,
# val is the number of waiters to wake. The unused uaddr2/val3 slots
# pass 0 via syscall7.
int sys_futex(int uaddr, int futex_op, int val, int timeout):
	return syscall7(SYS_FUTEX, uaddr, futex_op, val, timeout, 0, 0)

# set_tid_address: arms the calling thread's clear_child_tid
# pointer. When the thread exits, the kernel writes 0 to the 32-bit
# word at tidptr (the low half of a W word on x86-64) and futex-wakes one waiter on it - the same signal
# CLONE_CHILD_CLEARTID would arm at clone time. lib/thread.w uses it
# so a joiner can wait for the worker to be fully off its stack before
# munmapping it. Returns the caller's tid.
int sys_set_tid_address(int tidptr):
	return syscall(SYS_SET_TID_ADDRESS, tidptr, 0, 0)

# poll: fds points at an array of 8-byte pollfd records.
# timeout_ms < 0 blocks forever; 0 returns immediately.
int sys_poll(int fds, int nfds, int timeout_ms):
	return syscall(SYS_POLL, fds, nfds, timeout_ms)

int sys_fcntl(int fd, int cmd, int arg):
	return syscall(SYS_FCNTL, fd, cmd, arg)

# ioctl: request values like TCGETS/TCSETS come from lib/termios.w.
int sys_ioctl(int fd, int request, int arg):
	return syscall(SYS_IOCTL, fd, request, arg)

# mincore: one residency byte per page in vec; fails with -ENOMEM
# when the range is not fully mapped, which makes it a safe read probe.
int sys_mincore(int addr, int length, int vec):
	return syscall(SYS_MINCORE, addr, length, vec)

# nanosleep: req/rem point at { long seconds; long nanoseconds }
# which matches two W words on both targets.
int sys_nanosleep(int req, int rem):
	return syscall(SYS_NANOSLEEP, req, rem, 0)

# clock_gettime: i386's 32-bit timespec is fine for CLOCK_MONOTONIC
# (seconds since boot), which is this wrapper's intended use.
int sys_clock_gettime(int clock_id, int ts):
	return syscall(SYS_CLOCK_GETTIME, clock_id, ts, 0)

# rt_sigaction: sigsetsize must be _NSIG/8 = 8. On i386, when act has no
# SA_RESTORER the kernel points the signal frame's return address at the
# vdso sigreturn trampoline, so plain W functions work as handlers; the
# x86-64 kernel has no such fallback, so real handlers there need an
# SA_RESTORER trampoline in act.
int rt_sigaction(int signum, int* act, int* oldact):
	return syscall7(SYS_RT_SIGACTION, signum, act, oldact, 8, 0, 0)


/* Process management */

# Returns the child pid in the parent and 0 in the child; the child gets a
# copy-on-write duplicate of the address space and stack.
int fork():
	return syscall(SYS_FORK, 0, 0, 0)

# argv and envp are NULL-terminated vectors of char* (word-sized entries).
# Only returns on failure; on success the process image is replaced.
int execve(char* path, char** argv, char** envp):
	return syscall(SYS_EXECVE, path, argv, envp)

# Reaps a child. pid -1 waits for any child; options 1 is WNOHANG. status
# receives the raw wait status (may be 0 to discard). rusage should be 0.
int wait4(int pid, int* status, int options, int rusage):
	return syscall7(SYS_WAIT4, pid, status, options, rusage, 0, 0)

# The kernel writes two 32-bit fds (read end, write end) to fds on both
# architectures, so callers should read them back with load_int32.
int pipe(int* fds):
	return syscall(SYS_PIPE, fds, 0, 0)

int dup2(int oldfd, int newfd):
	return syscall(SYS_DUP2, oldfd, newfd, 0)

int kill(int pid, int sig):
	return syscall(SYS_KILL, pid, sig, 0)


# sigaltstack is only wired up where lib/crash.w uses it (arm64_darwin).
int sys_sigaltstack(int ss, int old_ss):
	return -1


# ptrace: request/pid/addr/data follow the classic ptrace(2) ABI.
# For PTRACE_PEEK* the raw syscall (unlike the glibc wrapper) writes the
# read word to *data and returns 0, so callers pass a word pointer as data
# and read it back; for PTRACE_POKE* data is the value to write.
int sys_ptrace(int request, int pid, int addr, int data):
	return syscall7(SYS_PTRACE, request, pid, addr, data, 0, 0)

int chdir(char* path):
	return syscall(SYS_CHDIR, path, 0, 0)

int getpid():
	return syscall(SYS_GETPID, 0, 0, 0)

# req points at a timespec whose two fields (seconds, nanoseconds) are
# word-sized: 32-bit on i386, 64-bit on x86-64. rem may be 0.
int nanosleep(int* req, int* rem):
	return syscall(SYS_NANOSLEEP, req, rem, 0)

# fds points at an array of pollfd structs: int fd, short events,
# short revents (8 bytes each on both architectures).
int poll(int* fds, int nfds, int timeout_ms):
	return syscall(SYS_POLL, fds, nfds, timeout_ms)

# clock_id 1 is CLOCK_MONOTONIC. out points at a timespec whose two fields
# (seconds, nanoseconds) are word-sized, like nanosleep's. The i386 variant
# keeps 32-bit fields; clock_gettime64 is the future 2038 fix there.
int clock_gettime(int clock_id, int* out):
	return syscall(SYS_CLOCK_GETTIME, clock_id, out, 0)


/* Socket syscalls, one register-passed syscall per operation (i386 has
had direct ones since Linux 4.3, 2015, replacing the socketcall(2)
multiplexer). recv is recvfrom with a null address on both targets;
sys_accept lives in the per-target module (i386 has only accept4). */
int sys_socket(int family, int socket_type, int protocol):
	return syscall(SYS_SOCKET, family, socket_type, protocol)


int sys_bind(int sockfd, int addr, int addrlen):
	return syscall(SYS_BIND, sockfd, addr, addrlen)


int sys_connect(int sockfd, int addr, int addrlen):
	return syscall(SYS_CONNECT, sockfd, addr, addrlen)


int sys_listen(int sockfd, int backlog):
	return syscall(SYS_LISTEN, sockfd, backlog, 0)


int sys_getsockname(int sockfd, int addr, int addrlen):
	return syscall(SYS_GETSOCKNAME, sockfd, addr, addrlen)


int sys_socketpair(int family, int socket_type, int protocol, int fds):
	return syscall7(SYS_SOCKETPAIR, family, socket_type, protocol, fds, 0, 0)


# sendmsg / recvmsg: msg points at a struct msghdr (seven word-sized
# fields on Linux: name, namelen, iov, iovlen, control, controllen,
# flags). Used for SCM_RIGHTS descriptor passing over AF_UNIX sockets
# (lib/unix_fds.w).
int sys_sendmsg(int sockfd, int msg, int flags):
	return syscall(SYS_SENDMSG, sockfd, msg, flags)


int sys_recvmsg(int sockfd, int msg, int flags):
	return syscall(SYS_RECVMSG, sockfd, msg, flags)


int sys_sendto(int sockfd, char* buf, int len, int flags, int addr, int addrlen):
	return syscall7(SYS_SENDTO, sockfd, buf, len, flags, addr, addrlen)


# recvfrom with a null address doubles as recv.
int sys_recv(int sockfd, char* buf, int len, int flags):
	return syscall7(SYS_RECVFROM, sockfd, buf, len, flags, 0, 0)


# addr/addrlen may be 0 to ignore the sender address; addrlen is an in/out
# pointer to the address buffer size.
int sys_recvfrom(int sockfd, char* buf, int len, int flags, int addr, int addrlen):
	return syscall7(SYS_RECVFROM, sockfd, buf, len, flags, addr, addrlen)


int sys_setsockopt(int sockfd, int level, int optname, int optval, int optlen):
	return syscall7(SYS_SETSOCKOPT, sockfd, level, optname, optval, optlen, 0)

# getrandom: fills buf with up to buflen bytes from the kernel
# CSPRNG. flags 0 blocks until the entropy pool is initialized.
int sys_getrandom(char* buf, int buflen, int flags):
	return syscall(SYS_GETRANDOM, buf, buflen, flags)


/* inotify: filesystem change notification (see lib/inotify.w for the
constants and the variable-length event-record parser). */

# inotify_init1: returns an inotify fd; flags is 0 or O_NONBLOCK
# and/or O_CLOEXEC.
int sys_inotify_init1(int flags):
	return syscall(SYS_INOTIFY_INIT1, flags, 0, 0)


# inotify_add_watch: returns a watch descriptor for path, or a
# negative errno. Re-adding a watched path updates its mask in place.
int sys_inotify_add_watch(int fd, char* path, int mask):
	return syscall(SYS_INOTIFY_ADD_WATCH, fd, path, mask)


# inotify_rm_watch: removes a watch; the kernel queues a final
# IN_IGNORED event for it.
int sys_inotify_rm_watch(int fd, int wd):
	return syscall(SYS_INOTIFY_RM_WATCH, fd, wd, 0)

# exit_group: terminates every thread in the process, like libc exit().
void exit(int error_code):
	syscall(SYS_EXIT_GROUP, error_code, 0, 0)

# exit: terminates only the calling thread.
void thread_exit(int error_code):
	syscall(SYS_EXIT, error_code, 0, 0)


/* epoll and eventfd (lib/event_loop.w's readiness backend, lib/task_runtime.w's
   cross-thread wakeups). epoll_event is {u32 events; u64 data}: packed (12 bytes) on i386 and x86-64. */

int epoll_event_bytes():
	return 12


# Byte offset of the u64 data field inside one epoll_event.
int epoll_event_data_offset():
	return 4


int epoll_create1(int flags):
	return syscall(SYS_EPOLL_CREATE1, flags, 0, 0)


int epoll_ctl(int epfd, int op, int fd, int event):
	return syscall7(SYS_EPOLL_CTL, epfd, op, fd, event, 0, 0)


int epoll_wait(int epfd, int events, int maxevents, int timeout_ms):
	return syscall7(SYS_EPOLL_WAIT, epfd, events, maxevents, timeout_ms, 0, 0)


int eventfd2(int initval, int flags):
	return syscall(SYS_EVENTFD2, initval, flags, 0)
