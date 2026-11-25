# lib/fs_at.w for arm64 Darwin (XNU syscall numbers from
# bsd/kern/syscalls.master; flag values from the SDK's sys/fcntl.h).
# O_RESOLVE_BENEATH keeps every lookup, ".." included, beneath dirfd and
# refuses absolute paths; O_NOFOLLOW_ANY refuses a symlink in any
# component. XNU ignores open flags it does not know, so fs_at_supported
# proves both rules on the running kernel instead of trusting the flags.
# O_NOFOLLOW_ANY covers the final component too; XNU rejects it combined
# with O_NOFOLLOW (EINVAL).
import lib.darwin.stat_layout

const int FS_AT_DARWIN_O_NONBLOCK = 4
const int FS_AT_DARWIN_O_RESOLVE_BENEATH = 4096
const int FS_AT_DARWIN_O_NOCTTY = 131072
const int FS_AT_DARWIN_O_DIRECTORY = 1048576
const int FS_AT_DARWIN_O_CLOEXEC = 16777216
const int FS_AT_DARWIN_O_NOFOLLOW_ANY = 536870912


int fs_at_darwin_dirfd(int dirfd):
	if (dirfd == -100): return -2 # AT_FDCWD
	return dirfd


int fs_at_darwin_open(int dirfd, char* path, int native_flags, int mode):
	int confined = native_flags | FS_AT_DARWIN_O_RESOLVE_BENEATH | FS_AT_DARWIN_O_NOFOLLOW_ANY | FS_AT_DARWIN_O_CLOEXEC
	return syscall7(463, fs_at_darwin_dirfd(dirfd), path, confined, mode, 0, 0)


int fs_at_open_beneath(int dirfd, char* path, int flags, int mode):
	if (flags & 2097152): return -22 # Linux O_PATH has no Darwin equivalent
	return fs_at_darwin_open(dirfd, path, darwin_open_flags(flags), mode)


int fs_at_stat(int fd, file_stat* out):
	char[144] native
	int err = syscall(339, fd, &native[0], 0) # fstat64
	if (err != 0): return err
	char* buf = cast(char*, malloc(FILE_STATX_BUF_SIZE))
	darwin_stat_to_statx(&native[0], buf)
	file_stat_from_statx(buf, out)
	free(buf)
	return 0


# Without O_PATH the file is opened before its type is known: O_NONBLOCK
# keeps a FIFO from blocking and O_NOCTTY keeps a terminal from becoming
# the controlling one. Regular-file reads ignore O_NONBLOCK.
int fs_at_open_regular(int dirfd, char* path, file_stat* out):
	int fd = fs_at_darwin_open(dirfd, path, FS_AT_DARWIN_O_NONBLOCK | FS_AT_DARWIN_O_NOCTTY, 0)
	if (fd < 0): return fd
	int result = fs_at_stat(fd, out)
	if ((result == 0) && (file_is_reg(out) == 0)): result = -22
	if (result < 0):
		close(fd)
		return result
	return fd


int fs_at_chmod(int fd, int mode):
	return syscall(124, fd, mode, 0)


int fs_at_rename(int dirfd, char* from, char* to):
	if ((fs_at_leaf(from) == 0) || (fs_at_leaf(to) == 0)): return -22
	int directory = fs_at_darwin_dirfd(dirfd)
	return syscall7(465, directory, from, directory, to, 0, 0)


int fs_at_unlink(int dirfd, char* name):
	if (fs_at_leaf(name) == 0): return -22
	return syscall7(472, fs_at_darwin_dirfd(dirfd), name, 0, 0, 0, 0)


# Both rules must visibly refuse something on this kernel: ".." out of
# /usr (O_RESOLVE_BENEATH, macOS 15+) and the /tmp -> private/tmp
# symlink as an intermediate component (O_NOFOLLOW_ANY, macOS 11+).
# Opening "." beneath "/" must still succeed.
int fs_at_supported():
	int usr = syscall(5, c"/usr", FS_AT_DARWIN_O_DIRECTORY | FS_AT_DARWIN_O_CLOEXEC, 0)
	int root = syscall(5, c"/", FS_AT_DARWIN_O_DIRECTORY | FS_AT_DARWIN_O_CLOEXEC, 0)
	int ok = (usr >= 0) && (root >= 0)
	if (ok):
		int escaped = fs_at_darwin_open(usr, c"..", FS_AT_DARWIN_O_DIRECTORY, 0)
		if (escaped >= 0):
			close(escaped)
			ok = 0
		int linked = fs_at_darwin_open(root, c"tmp/.", FS_AT_DARWIN_O_DIRECTORY, 0)
		if (linked != -62): # ELOOP, not merely a missing /tmp
			if (linked >= 0): close(linked)
			ok = 0
		int itself = fs_at_darwin_open(root, c".", FS_AT_DARWIN_O_DIRECTORY, 0)
		if (itself < 0): ok = 0
		else: close(itself)
	if (usr >= 0): close(usr)
	if (root >= 0): close(root)
	return ok
