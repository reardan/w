# AArch64 Darwin (XNU) filesystem primitives for libs/extras/vcs. See
# the x86 twin for why this lives outside lib/__arch__. Numbers from
# the BSD table (apple-oss-distributions/xnu, bsd/kern/syscalls.master);
# the syscall stubs convert Darwin's carry-flag errno convention to the
# -errno contract, like lib/__arch__/arm64_darwin/syscalls.w.

# Atomically replaces newpath with oldpath (rename, BSD syscall 128).
# Both paths must be on the same filesystem. Returns 0 or a negative
# errno.
int vcs_rename(char* oldpath, char* newpath):
	return syscall(128, oldpath, newpath, 0)


# Removes a file (unlink, BSD syscall 10). See the x86 twin for why
# this wrapper exists.
int vcs_unlink(char* path):
	return syscall(10, path, 0, 0)
