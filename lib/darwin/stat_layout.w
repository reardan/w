# XNU user64_stat64 (144 bytes) -> Linux statx basic fields (256 bytes).
# Native layout: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/stat.h
# Keep this byte decoder host-testable; it does not issue Darwin syscalls.

void darwin_stat_field(char* native, int source, char* out, int target, int size):
	for i in range(size): out[target + i] = native[source + i]

void darwin_stat_to_statx(char* native, char* out):
	for i in range(256): out[i] = 0
	out[0] = 255
	out[1] = 7  # STATX_BASIC_STATS
	darwin_stat_field(native, 112, out, 4, 4)  # block size
	darwin_stat_field(native, 6, out, 16, 2)   # link count (native u16)
	darwin_stat_field(native, 16, out, 20, 4)  # uid
	darwin_stat_field(native, 20, out, 24, 4)  # gid
	darwin_stat_field(native, 4, out, 28, 2)   # mode (native u16)
	darwin_stat_field(native, 8, out, 32, 8)   # inode
	darwin_stat_field(native, 96, out, 40, 8)  # size
	darwin_stat_field(native, 104, out, 48, 8) # allocated 512-byte blocks
	darwin_stat_field(native, 32, out, 64, 12) # atime seconds + nanoseconds
	darwin_stat_field(native, 64, out, 96, 12) # ctime
	darwin_stat_field(native, 48, out, 112, 12) # mtime
	# Darwin dev_t has an 8-bit major above a 24-bit minor.
	darwin_stat_field(native, 27, out, 128, 1)
	darwin_stat_field(native, 24, out, 132, 3)
	darwin_stat_field(native, 3, out, 136, 1)
	darwin_stat_field(native, 0, out, 140, 3)
