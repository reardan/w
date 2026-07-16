# x86 (i386) 32-bit Linux filesystem primitives for libs/extras/vcs.
# rename(2) is the atomic-replace primitive the loose-object store's
# write-to-temp + rename protocol needs; lib/__arch__ does not wrap it,
# and libs/extras/vcs must stay out of the seed import graph, so the
# wrapper lives here. Conventions follow lib/__arch__/x86/syscalls.w:
# numbers from arch/x86/entry/syscalls/syscall_32.tbl, negative errno
# return values.

# Atomically replaces newpath with oldpath (rename, syscall 38). Both
# paths must be on the same filesystem. Returns 0 or a negative errno.
int vcs_rename(char* oldpath, char* newpath):
	return syscall(38, oldpath, newpath, 0)


# Removes a file (unlink, syscall 10). Present here because the arm64
# target has no plain unlink wrapper in lib/__arch__, so the store's
# temp-file cleanup goes through this per-arch name on every target.
int vcs_unlink(char* path):
	return syscall(10, path, 0, 0)


# statx (syscall 383): fills a 256-byte struct statx (Linux
# uapi/linux/stat.h) describing `path`, resolved relative to the
# process's current directory (dirfd = AT_FDCWD = -100), following
# symlinks (flags = 0), requesting STATX_BASIC_STATS (mask = 0x7ff =
# 2047 -- the fields plain stat(2) fills). struct statx's layout is
# identical on 32- and 64-bit Linux targets by design (only the
# syscall NUMBER differs -- see the x64 twin), so
# libs/extras/vcs/index.w reads the two fields it needs (stx_size at
# byte 40, stx_mtime.tv_sec at byte 112) with one arch-independent
# parser. `buf` must be at least 256 bytes. Returns 0 or a negative
# errno (e.g. -2 ENOENT).
int vcs_statx(char* path, char* buf):
	return syscall7(383, -100, path, 0, 2047, buf, 0)
