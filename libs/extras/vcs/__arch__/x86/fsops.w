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
