# x86 (i386) 32-bit Linux syscalls: the numbers (from
# arch/x86/entry/syscalls/syscall_32.tbl) for the wrappers shared with
# x86-64 in lib/syscalls_linux_x86.w, plus the one wrapper whose shape
# differs here. In w.w's import graph: seed-era syntax only.

enum linux_syscall:
	SYS_CREAT = 8
	SYS_OPEN = 5
	SYS_WRITE = 4
	SYS_READ = 3
	SYS_CLOSE = 6
	SYS_LSEEK = 19
	SYS_UNLINK = 10
	SYS_FSYNC = 118
	SYS_FDATASYNC = 148
	SYS_MKDIR = 39
	SYS_RMDIR = 40
	SYS_RENAME = 38
	SYS_GETDENTS = 141
	SYS_GETCWD = 183
	SYS_STATX = 383
	SYS_CHMOD = 15
	SYS_UTIMENSAT = 320
	SYS_FCHOWNAT = 298
	SYS_GETUID = 199   # getuid32: the 32-bit-id variant
	SYS_GETGID = 200   # getgid32
	SYS_READLINK = 85
	SYS_SYMLINK = 83
	SYS_TIME = 13   # 32-bit time_t: overflows 2038-01-19; clock_gettime64 (403) is the fix
	SYS_BRK = 45
	SYS_MMAP = 192   # mmap2: offset in 4096-byte pages (old_mmap, 90, wants an arg struct)
	SYS_MUNMAP = 91
	SYS_MPROTECT = 125
	SYS_CLONE = 56   # unchanged from the old wrapper, though i386 clone is 120 (only tests/threading.w calls sys_clone)
	SYS_FUTEX = 240
	SYS_SET_TID_ADDRESS = 258
	SYS_POLL = 168
	SYS_FCNTL = 55
	SYS_IOCTL = 54
	SYS_MINCORE = 218
	SYS_NANOSLEEP = 162
	SYS_CLOCK_GETTIME = 265
	SYS_RT_SIGACTION = 174
	SYS_FORK = 2
	SYS_EXECVE = 11
	SYS_WAIT4 = 114
	SYS_PIPE = 42
	SYS_DUP2 = 63
	SYS_KILL = 37
	SYS_PTRACE = 26
	SYS_CHDIR = 12
	SYS_GETPID = 20
	SYS_SOCKET = 359
	SYS_CONNECT = 362
	SYS_ACCEPT = 364   # accept4: i386 has no plain accept
	SYS_SENDTO = 369
	SYS_BIND = 361
	SYS_LISTEN = 363
	SYS_GETSOCKNAME = 367
	SYS_SOCKETPAIR = 360
	SYS_SENDMSG = 370
	SYS_RECVMSG = 372
	SYS_RECVFROM = 371
	SYS_SETSOCKOPT = 366
	SYS_GETRANDOM = 355
	SYS_INOTIFY_INIT1 = 332
	SYS_INOTIFY_ADD_WATCH = 292
	SYS_INOTIFY_RM_WATCH = 293
	SYS_EXIT_GROUP = 252
	SYS_EXIT = 1
	SYS_EPOLL_CREATE1 = 329
	SYS_EPOLL_CTL = 255
	SYS_EPOLL_WAIT = 256
	SYS_EVENTFD2 = 328


# accept4 with flags 0: i386 gained no plain accept syscall.
int sys_accept(int sockfd, int addr, int addrlen):
	return syscall7(SYS_ACCEPT, sockfd, addr, addrlen, 0, 0, 0)


import lib.syscalls_linux_x86
import lib.win32_stubs
