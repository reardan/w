# x86-64 statfs (137) wrapper for lib/stat.w's file_statfs; see the x86
# twin for why this lives outside syscalls.w. The 64-bit generic struct
# statfs is 120 bytes of word-sized (__fsword_t) fields:
#    0 f_type    8 f_bsize   16 f_blocks  24 f_bfree  32 f_bavail
#   40 f_files  48 f_ffree   56 f_fsid    64 f_namelen ...
# so every field of interest is a straight word-indexed load.


int STATFS_BUF_SIZE():
	return 128


# Fill out[0..5] with bsize, blocks, bfree, bavail, files, ffree for
# the filesystem containing path. buf is STATFS_BUF_SIZE() scratch
# bytes for the raw kernel struct. Returns 0 or a negative errno.
int statfs_fill(char* path, char* buf, int* out):
	int err = syscall(137, path, buf, 0)
	if (err != 0):
		return err
	int* fields = cast(int*, buf)
	out[0] = fields[1]
	out[1] = fields[2]
	out[2] = fields[3]
	out[3] = fields[4]
	out[4] = fields[5]
	out[5] = fields[6]
	return 0
