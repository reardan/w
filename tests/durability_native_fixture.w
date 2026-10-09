# Native syscall qualification. Process termination tests exercise recovery
# with a live kernel; they cannot establish power-loss/device guarantees.
import lib.assert
import lib.fs

void durability_reap(int pid, int killed):
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	if (killed): assert_equal(9, status & 127)
	else: assert_equal(0, status)

int durability_open(char* path):
	io_result r
	int fd = fs_open(path, FS_O_RDWR | FS_O_CREAT | FS_O_TRUNC, 384, &r)
	assert1(fd >= 0)
	return fd

void durability_concurrent_positions():
	int fd = durability_open(c"positions")
	int offset = 5 * 1024 * 1024 * 1024
	io_result r
	assert_equal(IO_OK, fs_pwrite_all(fd, c"far", 3, offset, &r))
	assert_equal(offset + 3, seek(fd, 0, 2))
	assert_equal(7, seek(fd, 7, 0))
	int worker = fork()
	assert1(worker >= 0)
	if (worker == 0):
		for i in range(20000):
			assert_equal(IO_OK, fs_pwrite_all(fd, c"child", 5, offset + 16, &r))
		exit(0)
	for i in range(20000):
		assert_equal(IO_OK, fs_pwrite_all(fd, c"parent", 6, offset + 32, &r))
	durability_reap(worker, 0)
	assert_equal(7, seek(fd, 0, 1))
	char[8] buf
	assert_equal(IO_OK, fs_pread_exact(fd, &buf[0], 5, offset + 16, &r))
	assert_bytes_equal(c"child", &buf[0], 5)
	assert_equal(IO_OK, fs_pread_exact(fd, &buf[0], 6, offset + 32, &r))
	assert_bytes_equal(c"parent", &buf[0], 6)
	assert_equal(IO_OK, fs_ftruncate(fd, 1, &r))
	assert_equal(1, seek(fd, 0, 2))
	assert_equal(IO_IO_ERROR, fs_pwrite(fd, c"x", 1, -1, &r))
	assert_equal(22, r.native_error)
	assert_equal(IO_IO_ERROR, fs_pwrite(fd, c"x", 2, (1 << 63) - 1, &r))
	close(fd)
	unlink(c"positions")

void durability_ownership():
	io_result r
	int dirfd = fs_open(c".", FS_O_RDONLY | FS_O_DIRECTORY, 0, &r)
	assert1(dirfd >= 0)
	int fd = fs_openat(dirfd, c"exclusive", FS_O_RDWR | FS_O_CREAT | FS_O_EXCL, 384, &r)
	assert1(fd >= 0)
	assert_equal(-1, fs_create_exclusive(c"exclusive", 384, &r))
	assert_equal(1, fs_result_exists(&r))
	close(fd)
	assert_equal(-1, fs_open(c"exclusive", FS_O_RDONLY | FS_O_DIRECTORY, 0, &r))
	assert_equal(20, r.native_error)
	close(dirfd)
	unlink(c"exclusive")
	int* ready = cast(int*, mmap(0, 16384, 3, 33))
	assert1(cast(int, ready) > 0)
	int worker = fork()
	assert1(worker >= 0)
	if (worker == 0):
		assert1(fs_lock_acquire(c"owner", &r) >= 0)
		atomic_store(ready, 1)
		while (1): pass
	while (atomic_load(ready) == 0): pass
	assert_equal(-1, fs_lock_acquire(c"owner", &r))
	assert_equal(IO_WOULD_BLOCK, r.status)
	assert_equal(IO_ERRNO_EAGAIN, r.native_error)
	assert_equal(0, kill(worker, 9))
	durability_reap(worker, 1)
	fd = fs_lock_acquire(c"owner", &r)
	assert1(fd >= 0)
	assert_equal(IO_OK, fs_lock_release(fd, &r))
	unlink(c"owner")
	munmap(cast(int, ready), 16384)

# Stop the writer at each boundary around sync, rename and directory sync.
# Parent acknowledges publication by reading the actual destination; a killed
# writer has no success result that the recovery path could accidentally trust.
void durability_crash_boundaries():
	int* ready = cast(int*, mmap(0, 16384, 3, 33))
	assert1(cast(int, ready) > 0)
	io_result r
	for stage in range(1, 6):
		int fd = durability_open(c"target")
		assert_equal(IO_OK, fs_pwrite_all(fd, c"old", 3, 0, &r))
		assert_equal(IO_OK, fs_fsync(fd, &r))
		close(fd)
		assert_equal(IO_OK, fs_sync_dir(c".", &r))
		atomic_store_relaxed(ready, 0)
		int worker = fork()
		assert1(worker >= 0)
		if (worker == 0):
			int temp = fs_create_exclusive(c"temporary", 384, &r)
			assert1(temp >= 0)
			assert_equal(IO_OK, fs_pwrite_all(temp, c"new", 3, 0, &r))
			if (stage >= 2): assert_equal(IO_OK, fs_fsync(temp, &r))
			if (stage >= 3): close(temp)
			if (stage >= 4): assert_equal(0, rename(c"temporary", c"target"))
			if (stage >= 5): assert_equal(IO_OK, fs_sync_dir(c".", &r))
			atomic_store(ready, stage)
			while (1): pass
		while (atomic_load(ready) != stage): pass
		assert_equal(0, kill(worker, 9))
		durability_reap(worker, 1)
		char[4] buf
		fd = fs_open(c"target", FS_O_RDONLY, 0, &r)
		assert1(fd >= 0)
		assert_equal(IO_OK, fs_pread_exact(fd, &buf[0], 3, 0, &r))
		if (stage < 4): assert_bytes_equal(c"old", &buf[0], 3)
		else: assert_bytes_equal(c"new", &buf[0], 3)
		close(fd)
		unlink(c"temporary")
		# Recovery re-establishes directory durability even for ambiguous rename.
		assert_equal(IO_OK, fs_sync_dir(c".", &r))
		fs_replace_report report
		assert_equal(IO_OK, fs_replace_durable(c"target", c"recovered", 9, &report))
		assert_equal(1, report.renamed)
		assert_equal(FS_STAGE_NONE, report.stage)
	unlink(c"target")
	munmap(cast(int, ready), 16384)

int main():
	assert_equal(8, __word_size__)
	durability_concurrent_positions()
	durability_ownership()
	durability_crash_boundaries()
	# Native error and report fields at failures before publication.
	io_result r
	assert_equal(IO_IO_ERROR, fs_fsync(-1, &r))
	assert_equal(9, r.native_error)
	fs_replace_report report
	assert_equal(IO_IO_ERROR, fs_replace_durable(c"missing/target", c"x", 1, &report))
	assert_equal(FS_STAGE_OPEN_TEMP, report.stage)
	assert_equal(0, report.renamed)
	mkdir(c"directory", 448)
	assert_equal(IO_IO_ERROR, fs_replace_durable(c"directory", c"x", 1, &report))
	assert_equal(FS_STAGE_RENAME, report.stage)
	assert_equal(0, report.renamed)
	rmdir(c"directory")
	return 0
