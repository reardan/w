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
