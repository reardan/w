# lib/fs.w's native layer on POSIX kernels (Linux, Android and Darwin;
# wasm's ENOSYS stubs ride along). Each target's syscall adapter already
# returns a count or a negative errno, so these forward unchanged and
# lib/fs.w keeps one code path. Windows has its own layer:
# lib/__arch__/win64/fs_native.w.


# fs_sync_dir opens the directory read-only (FS_O_RDONLY) and fsyncs it.
const int FS_NATIVE_DIR_SYNC_ACCESS = 0

# fs_replace_durable's final barrier is an fsync of the parent directory.
const int FS_NATIVE_PUBLISH_SYNCS_DIR = 1


int fs_native_openat(int dirfd, char* path, int flags, int mode):
	return sys_openat(dirfd, path, flags, mode)


int fs_native_pread(int fd, char* buf, int count, int offset):
	return sys_pread(fd, buf, count, offset)


int fs_native_pwrite(int fd, char* buf, int count, int offset):
	return sys_pwrite(fd, buf, count, offset)


int fs_native_ftruncate(int fd, int length):
	return sys_ftruncate(fd, length)


int fs_native_flock(int fd, int operation):
	return sys_flock(fd, operation)


int fs_native_fsync(int fd):
	return fsync(fd)


int fs_native_close(int fd):
	return close(fd)


# Atomically replaces newpath (same directory, so never across devices).
int fs_native_rename(char* oldpath, char* newpath):
	return rename(oldpath, newpath)


int fs_native_unlink(char* path):
	return unlink(path)
