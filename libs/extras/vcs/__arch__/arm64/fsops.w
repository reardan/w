# AArch64 Linux filesystem primitives for libs/extras/vcs. See the x86
# twin for why this lives outside lib/__arch__. The generic syscall
# table has no plain rename; renameat2 (276) with AT_FDCWD (-100) for
# both directory fds and flags 0 is the equivalent. Negative errno
# returns, like lib/__arch__/arm64/syscalls.w.

# Atomically replaces newpath with oldpath (renameat2, syscall 276).
# Both paths must be on the same filesystem. Returns 0 or a negative
# errno.
int vcs_rename(char* oldpath, char* newpath):
	return syscall7(276, -100, oldpath, -100, newpath, 0, 0)


# Removes a file (unlinkat, syscall 35, flags 0). lib/__arch__/arm64
# wraps unlinkat only as rmdir (AT_REMOVEDIR); the store needs the
# plain-file form for temp cleanup.
int vcs_unlink(char* path):
	return syscall(35, -100, path, 0)
