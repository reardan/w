# Darwin has neither copy_file_range nor a file-to-file sendfile, so
# both fast paths report ENOSYS (-38, the Linux number callers test for)
# and libs/standard/fs/shutil.w uses its read/write loop.


int copy_range_file(int in_fd, int out_fd, int count):
	return 0 - 38


int copy_range_sendfile(int out_fd, int in_fd, int count):
	return 0 - 38
