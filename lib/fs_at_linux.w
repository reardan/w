# lib/fs_at.w for x86 and x86-64 Linux (the syscall numbers follow the
# word size). openat2 (437, Linux 5.6+) rejects unknown resolve bits with
# EINVAL and returns ENOSYS on older kernels, so a successful call always
# carried the guarantee.
const int FS_AT_O_PATH = 2097152
const int FS_AT_O_NOFOLLOW = 131072
const int FS_AT_O_CLOEXEC = 524288
const int FS_AT_O_NONBLOCK = 2048
const int FS_AT_AT_EMPTY_PATH = 4096
const int FS_AT_RESOLVE_NO_SYMLINKS = 4
const int FS_AT_RESOLVE_BENEATH = 8


# x86-64 number when the word is 8 bytes, else the i386 one.
int fs_at_linux_syscall(int x64, int x86):
	if (__word_size__ == 8): return x64
	return x86


# struct open_how is three u64 fields (flags, mode, resolve); on i386
# each low word is stored and the high words stay zero.
int fs_at_open_beneath(int dirfd, char* path, int flags, int mode):
	char[24] how
	for i in range(24): how[i] = 0
	*cast(int*, &how[0]) = flags | FS_AT_O_CLOEXEC | FS_AT_O_NOFOLLOW
	# The kernel rejects a mode unless the open can create (O_CREAT, O_TMPFILE).
	if (flags & (64 | 4194304)): *cast(int*, &how[8]) = mode
	*cast(int*, &how[16]) = FS_AT_RESOLVE_NO_SYMLINKS | FS_AT_RESOLVE_BENEATH
	return syscall7(437, dirfd, path, &how[0], 24, 0, 0)


int fs_at_stat(int fd, file_stat* out):
	char* buf = cast(char*, malloc(FILE_STATX_BUF_SIZE))
	int err = syscall7(fs_at_linux_syscall(332, 383), fd, c"", FS_AT_AT_EMPTY_PATH, FILE_STATX_BASIC_STATS, buf, 0)
	if (err == 0): file_stat_from_statx(buf, out)
	free(buf)
	return err


# O_PATH opens nothing, so a FIFO cannot block and a device driver never
# sees an open until the type check passes. /proc/self/fd/N then reopens
# that same inode for reading.
int fs_at_open_regular(int dirfd, char* path, file_stat* out):
	int handle = fs_at_open_beneath(dirfd, path, FS_AT_O_PATH, 0)
	if (handle < 0): return handle
	int result = fs_at_stat(handle, out)
	if ((result == 0) && (file_is_reg(out) == 0)): result = -22
	if (result == 0):
		char* number = itoa(handle)
		char* reopen = strjoin(c"/proc/self/fd/", number)
		result = open(reopen, FS_AT_O_CLOEXEC | FS_AT_O_NONBLOCK, 0)
		free(reopen)
		free(number)
	close(handle)
	return result


int fs_at_chmod(int fd, int mode):
	return syscall(fs_at_linux_syscall(91, 94), fd, mode, 0)


int fs_at_rename(int dirfd, char* from, char* to):
	if ((fs_at_leaf(from) == 0) || (fs_at_leaf(to) == 0)): return -22
	return syscall7(fs_at_linux_syscall(264, 302), dirfd, from, dirfd, to, 0, 0)


int fs_at_unlink(int dirfd, char* name):
	if (fs_at_leaf(name) == 0): return -22
	return syscall7(fs_at_linux_syscall(263, 301), dirfd, name, 0, 0, 0, 0)


int fs_at_supported():
	int fd = fs_at_open_beneath(-100, c".", 65536, 0)
	if (fd < 0): return 0
	close(fd)
	return 1
