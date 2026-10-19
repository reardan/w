# x86-64 in-kernel file copy fast paths for libs/standard/fs/shutil.w;
# see the x86 twin for the conventions (NULL offsets, negative errno).


# copy_file_range (326).
int copy_range_file(int in_fd, int out_fd, int count):
	return syscall7(326, in_fd, 0, out_fd, 0, count, 0)


# sendfile (40).
int copy_range_sendfile(int out_fd, int in_fd, int count):
	return syscall7(40, out_fd, in_fd, 0, count, 0, 0)
