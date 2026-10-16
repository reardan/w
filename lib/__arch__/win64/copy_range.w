# No in-kernel file copy here: both fast paths report ENOSYS (-38) and
# libs/standard/fs/shutil.w uses its read/write loop (see the x86 twin).


int copy_range_file(int in_fd, int out_fd, int count):
	return 0 - 38


int copy_range_sendfile(int out_fd, int in_fd, int count):
	return 0 - 38
