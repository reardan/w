# lib/fs.w openat flags use Linux x86 numbering. ARM64 inherits four
# historical ARM assignments instead (arch/arm64/include/uapi/asm/fcntl.h).
# The raw open wrapper keeps its existing native-flag ABI for lib/dir.w.
int arm64_fs_open_flags(int flags):
	int native = flags & ~(16384 | 32768 | 65536 | 131072)
	if (flags & 16384): native = native | 65536  # O_DIRECT
	if (flags & 32768): native = native | 131072 # O_LARGEFILE
	if (flags & 65536): native = native | 16384  # O_DIRECTORY
	if (flags & 131072): native = native | 32768 # O_NOFOLLOW
	return native
