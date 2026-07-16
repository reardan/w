# x86-64 Linux filesystem primitives for libs/extras/vcs. See the x86
# twin for why this lives outside lib/__arch__. Numbers from
# arch/x86/entry/syscalls/syscall_64.tbl, negative errno returns.

# Atomically replaces newpath with oldpath (rename, syscall 82). Both
# paths must be on the same filesystem. Returns 0 or a negative errno.
int vcs_rename(char* oldpath, char* newpath):
	return syscall(82, oldpath, newpath, 0)


# Removes a file (unlink, syscall 87). See the x86 twin for why this
# wrapper exists.
int vcs_unlink(char* path):
	return syscall(87, path, 0, 0)


# statx (syscall 332): fills a 256-byte struct statx (Linux
# uapi/linux/stat.h) describing `path`, resolved relative to the
# process's current directory (dirfd = AT_FDCWD = -100), following
# symlinks (flags = 0), requesting STATX_BASIC_STATS (mask = 0x7ff =
# 2047 -- the fields plain stat(2) fills). struct statx's layout is
# identical on 32- and 64-bit Linux targets by design (only the
# syscall NUMBER differs -- see the x86 twin), so
# libs/extras/vcs/index.w reads the two fields it needs (stx_size at
# byte 40, stx_mtime.tv_sec at byte 112) with one arch-independent
# parser; verified against glibc's stat(2) on an x86-64 dev host.
# `buf` must be at least 256 bytes. Returns 0 or a negative errno (e.g.
# -2 ENOENT).
int vcs_statx(char* path, char* buf):
	return syscall7(332, -100, path, 0, 2047, buf, 0)
