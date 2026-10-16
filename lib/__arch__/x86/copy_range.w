# i386 in-kernel file copy fast paths for libs/standard/fs/shutil.w.
# A separate module (not syscalls.w) so the addition stays off the
# compiler's seed import graph, like this directory's statfs.w.
#
# Both calls pass NULL offsets, so the kernel copies from and advances
# each descriptor's own file position; a caller that falls back to
# read/write after a partial transfer continues where the kernel
# stopped. count is a word (31 bits here); callers loop on short copies.


# copy_file_range (377): Linux >= 4.5. Returns bytes copied, 0 at EOF,
# or a negative errno (-ENOSYS, -EXDEV, -EINVAL, ... mean "fall back").
int copy_range_file(int in_fd, int out_fd, int count):
	return syscall7(377, in_fd, 0, out_fd, 0, count, 0)


# sendfile64 (239) between two descriptors (a regular-file out_fd needs
# Linux >= 2.6.33). Same return convention as copy_range_file.
int copy_range_sendfile(int out_fd, int in_fd, int count):
	return syscall7(239, out_fd, in_fd, 0, count, 0, 0)
