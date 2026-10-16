# Linux/Android AArch64 in-kernel file copy fast paths for
# libs/standard/fs/shutil.w; see lib/__arch__/x86/copy_range.w for the
# conventions (NULL offsets, negative errno).


# copy_file_range (285).
int copy_range_file(int in_fd, int out_fd, int count):
	return syscall7(285, in_fd, 0, out_fd, 0, count, 0)


# sendfile (71).
int copy_range_sendfile(int out_fd, int in_fd, int count):
	return syscall7(71, out_fd, in_fd, 0, count, 0, 0)
