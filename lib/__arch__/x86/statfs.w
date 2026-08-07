# x86 (i386) statfs wrapper for lib/stat.w's file_statfs. Deliberately
# a separate module from this directory's syscalls.w: nothing in the
# compiler's seed import closure needs statfs, so keeping it out of
# syscalls.w keeps the addition off the self-host verify path (the same
# placement reasoning as lib/__arch__/*/repl_echo_float64.w).
#
# statfs64 (268) rather than the legacy statfs (99): the classic
# struct's 32-bit block counts overflow on any large filesystem. struct
# statfs64 on i386 is 84 bytes with 4-byte-aligned u64 fields (no
# padding):
#    0 f_type u32     4 f_bsize u32    8 f_blocks u64   16 f_bfree u64
#   24 f_bavail u64  32 f_files u64   40 f_ffree u64    48 f_fsid
#   56 f_namelen     60 f_frsize      64 f_flags        68 f_spare[4]
# The u64 counts are read as their low 32 bits via word-indexed loads
# (4-byte words on this target, little-endian low half first) -- the
# same accepted limit lib/stat.w's header documents for statx here.


int STATFS_BUF_SIZE():
	return 96


# Fill out[0..5] with bsize, blocks, bfree, bavail, files, ffree for
# the filesystem containing path. buf is STATFS_BUF_SIZE() scratch
# bytes for the raw kernel struct. Returns 0 or a negative errno.
int statfs_fill(char* path, char* buf, int* out):
	int err = syscall(268, path, 84, buf)
	if (err != 0):
		return err
	int* fields = cast(int*, buf)
	out[0] = fields[1]
	out[1] = fields[2]
	out[2] = fields[4]
	out[3] = fields[6]
	out[4] = fields[8]
	out[5] = fields[10]
	return 0
