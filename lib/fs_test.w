# wbuild: x64
# File durability primitives (lib/fs.w): positional I/O including a
# sparse write beyond 4 GiB on x86-64 (the i386 twin checks its
# documented 2^31 - 1 word limit instead), truncate, exclusive create,
# directory sync, flock contention, and durable replace with its
# failure stages.
import lib.testing
import lib.fs
import lib.file


int fs_test_open_rw(char* path):
	io_result r
	int fd = fs_open(path, FS_O_RDWR | FS_O_CREAT | FS_O_TRUNC | FS_O_CLOEXEC, FS_DEFAULT_MODE, &r)
	asserts(c"fs_open failed", fd >= 0)
	assert_equal(IO_OK, r.status)
	return fd


# The largest word: 2^63 - 1 on x86-64, 2^31 - 1 on i386.
int fs_test_word_max():
	int top = 1 << (__word_size__ * 8 - 1)
	return top - 1


void test_fs_positional_io_keeps_file_position():
	int fd = fs_test_open_rw(c"bin/fs_test_positional.bin")
	assert_equal(5, write(fd, c"hello", 5))
	io_result r
	assert_equal(IO_OK, fs_pwrite_all(fd, c"J", 1, 0, &r))
	assert_equal(1, r.transferred)
	# The shared position is still 5 after a positional write ...
	assert_equal(5, seek(fd, 0, 1))
	char* buf = malloc(16)
	assert_equal(IO_OK, fs_pread_exact(fd, buf, 4, 1, &r))
	assert_equal(4, r.transferred)
	buf[4] = 0
	assert_strings_equal(c"ello", buf)
	# ... and after a positional read.
	assert_equal(5, seek(fd, 0, 1))
	# An ordinary write continues at 5, not where pread/pwrite were.
	assert_equal(1, write(fd, c"!", 1))
	assert_equal(IO_OK, fs_pread_exact(fd, buf, 6, 0, &r))
	buf[6] = 0
	assert_strings_equal(c"Jello!", buf)
	# Reading past the end: EOF with the bytes that existed.
	assert_equal(IO_EOF, fs_pread_exact(fd, buf, 8, 3, &r))
	assert_equal(3, r.transferred)
	assert_equal(IO_EOF, fs_pread(fd, buf, 8, 100, &r))
	assert_equal(0, r.transferred)
	free(buf)
	close(fd)


void test_fs_positional_rejects_bad_ranges():
	int fd = fs_test_open_rw(c"bin/fs_test_ranges.bin")
	io_result r
	char* buf = malloc(8)
	assert_equal(IO_IO_ERROR, fs_pwrite_all(fd, c"x", 1, -1, &r))
	assert_equal(FS_EINVAL, r.native_error)
	assert_equal(IO_IO_ERROR, fs_pread(fd, buf, 1, -5, &r))
	assert_equal(FS_EINVAL, r.native_error)
	assert_equal(IO_IO_ERROR, fs_pwrite(fd, c"x", -1, 0, &r))
	assert_equal(FS_EINVAL, r.native_error)
	# offset + length overflows a word.
	assert_equal(IO_IO_ERROR, fs_pwrite_all(fd, c"abcd", 4, fs_test_word_max() - 2, &r))
	assert_equal(FS_EINVAL, r.native_error)
	assert_equal(0, r.transferred)
	# The wrappers themselves refuse negative offsets.
	assert_equal(-22, sys_pwrite(fd, c"x", 1, -1))
	# Nothing was written.
	assert_equal(0, seek(fd, 0, 2))
	# Empty requests succeed without touching the descriptor.
	assert_equal(IO_OK, fs_pwrite_all(-1, c"", 0, 0, &r))
	assert_equal(IO_OK, fs_pread_exact(-1, buf, 0, 0, &r))
	free(buf)
	close(fd)


void test_fs_sparse_positional_write_at_large_offset():
	char* path = c"bin/fs_test_sparse.bin"
	int fd = fs_test_open_rw(path)
	io_result r
	int offset = 0
	if (__word_size__ == 8):
		# 5 GiB: beyond any 32-bit offset.
		offset = 5 * 1024 * 1024 * 1024
		assert_equal(5, offset / 1073741824)
	else:
		# i386: the documented limit is the word, 2^31 - 1.
		offset = fs_test_word_max() - 8
	assert_equal(IO_OK, fs_pwrite_all(fd, c"far away", 8, offset, &r))
	assert_equal(8, r.transferred)
	assert_equal(0, seek(fd, 0, 1))
	assert_equal(offset + 8, seek(fd, 0, 2))
	char* buf = malloc(16)
	assert_equal(IO_OK, fs_pread_exact(fd, buf, 8, offset, &r))
	buf[8] = 0
	assert_strings_equal(c"far away", buf)
	# The hole reads back as zeros.
	assert_equal(IO_OK, fs_pread_exact(fd, buf, 4, offset - 4, &r))
	for i in range(4): assert_equal(0, buf[i])
	# Truncate back down; no durability claim, just the size.
	assert_equal(IO_OK, fs_ftruncate(fd, 3, &r))
	assert_equal(3, seek(fd, 0, 2))
	assert_equal(IO_IO_ERROR, fs_ftruncate(fd, -1, &r))
	assert_equal(FS_EINVAL, r.native_error)
	free(buf)
	close(fd)
	unlink(path)


void test_fs_ftruncate_extends_and_reports_errors():
	int fd = fs_test_open_rw(c"bin/fs_test_truncate.bin")
	io_result r
	assert_equal(IO_OK, fs_ftruncate(fd, 100, &r))
	assert_equal(100, seek(fd, 0, 2))
	close(fd)
	assert_equal(IO_IO_ERROR, fs_ftruncate(fd, 10, &r))
	assert_equal(9, r.native_error)  # EBADF


void test_fs_create_exclusive_conflicts():
	char* path = c"bin/fs_test_exclusive.bin"
	unlink(path)
	io_result r
	int fd = fs_create_exclusive(path, FS_DEFAULT_MODE, &r)
	asserts(c"first exclusive create failed", fd >= 0)
	assert_equal(IO_OK, r.status)
	assert_equal(0, fs_result_exists(&r))
	assert_equal(-1, fs_create_exclusive(path, FS_DEFAULT_MODE, &r))
	assert_equal(IO_IO_ERROR, r.status)
	assert_equal(FS_EEXIST, r.native_error)
	assert_equal(1, fs_result_exists(&r))
	close(fd)
	unlink(path)
	fd = fs_create_exclusive(path, FS_DEFAULT_MODE, &r)
	asserts(c"exclusive create after unlink failed", fd >= 0)
	close(fd)
	unlink(path)


void test_fs_openat_relative_to_directory():
	mkdir(c"bin/fs_test_dir", 493)
	io_result r
	int dirfd = fs_open(c"bin/fs_test_dir", FS_O_RDONLY | FS_O_DIRECTORY | FS_O_CLOEXEC, 0, &r)
	asserts(c"open dir failed", dirfd >= 0)
	int fd = fs_openat(dirfd, c"inner.txt", FS_O_WRONLY | FS_O_CREAT | FS_O_TRUNC | FS_O_CLOEXEC, FS_DEFAULT_MODE, &r)
	asserts(c"openat failed", fd >= 0)
	assert_equal(IO_OK, io_write_all(fd, c"inside", 6, &r))
	close(fd)
	close(dirfd)
	char* text = file_read_text(c"bin/fs_test_dir/inner.txt")
	assert_strings_equal(c"inside", text)
	free(text)
	# O_DIRECTORY on a regular file fails (ENOTDIR).
	assert_equal(-1, fs_open(c"bin/fs_test_dir/inner.txt", FS_O_RDONLY | FS_O_DIRECTORY, 0, &r))
	assert_equal(20, r.native_error)


void test_fs_sync_dir_reports_status():
	io_result r
	assert_equal(IO_OK, fs_sync_dir(c"bin", &r))
	assert_equal(IO_OK, fs_sync_parent_dir(c"bin/fs_test_anything", &r))
	assert_equal(IO_OK, fs_sync_parent_dir(c"relative_name", &r))
	asserts(c"missing dir must fail", fs_sync_dir(c"bin/fs_test_no_such_dir", &r) != IO_OK)
	assert_equal(2, r.native_error)  # ENOENT
	# fsync of something that cannot be synced is unsupported, not ok.
	int* fds = malloc(8)
	assert_equal(0, pipe(fds))
	int rd = load_int32(cast(char*, fds))
	int wr = load_int32(cast(char*, fds) + 4)
	assert_equal(IO_UNSUPPORTED, fs_fsync(wr, &r))
	assert_equal(FS_EINVAL, r.native_error)
	close(rd)
	close(wr)
	free(fds)


void test_fs_lock_contention():
	char* path = c"bin/fs_test.lock"
	io_result r
	int first = fs_lock_acquire(path, &r)
	asserts(c"first lock failed", first >= 0)
	assert_equal(IO_OK, r.status)
	# flock locks belong to the open file description: a second open in
	# the same process contends like another process would.
	assert_equal(-1, fs_lock_acquire(path, &r))
	assert_equal(IO_WOULD_BLOCK, r.status)
	assert_equal(11, r.native_error)  # EWOULDBLOCK
	assert_equal(IO_OK, fs_lock_release(first, &r))
	int again = fs_lock_acquire(path, &r)
	asserts(c"lock after release failed", again >= 0)
	fs_lock_release(again, &r)
	# A lock file in a missing directory cannot be opened.
	assert_equal(-1, fs_lock_acquire(c"bin/fs_test_no_such_dir/x.lock", &r))
	assert_equal(2, r.native_error)


void test_fs_replace_durable_happy_path():
	char* path = c"bin/fs_test_replace.txt"
	assert_equal(1, file_write_text(path, c"old contents"))
	fs_replace_report rep
	assert_equal(IO_OK, fs_replace_durable(path, c"new contents", 12, &rep))
	assert_equal(FS_STAGE_NONE, rep.stage)
	assert_equal(1, rep.renamed)
	assert_equal(12, rep.transferred)
	char* text = file_read_text(path)
	assert_strings_equal(c"new contents", text)
	free(text)
	# The temp sibling is gone (it was renamed).
	char* temp = fs_replace_temp_path(path, getpid(), fs_replace_sequence - 1)
	assert_equal(0, path_exists(temp))
	free(temp)
	# Creating a file that did not exist works too.
	unlink(c"bin/fs_test_replace_new.txt")
	io_result r
	assert_equal(IO_OK, file_write_durable(c"bin/fs_test_replace_new.txt", c"abc", 3, &r))
	assert_equal(3, r.transferred)
	text = file_read_text(c"bin/fs_test_replace_new.txt")
	assert_strings_equal(c"abc", text)
	free(text)


void test_fs_replace_durable_open_temp_failure():
	fs_replace_report rep
	int status = fs_replace_durable(c"bin/fs_test_no_such_dir/target.txt", c"x", 1, &rep)
	assert_equal(IO_IO_ERROR, status)
	assert_equal(FS_STAGE_OPEN_TEMP, rep.stage)
	assert_equal(2, rep.native_error)  # ENOENT
	assert_equal(0, rep.renamed)
	assert_strings_equal(c"open_temp", fs_stage_name(rep.stage))


void test_fs_replace_durable_rename_failure_cleans_up():
	# Renaming a file over a directory fails (EISDIR) after the temp file
	# was written, synced and closed: the target is untouched and the
	# temp file is removed.
	char* path = c"bin/fs_test_replace_dir"
	mkdir(path, 493)
	fs_replace_report rep
	int status = fs_replace_durable(path, c"payload", 7, &rep)
	asserts(c"rename over a directory must fail", status != IO_OK)
	assert_equal(FS_STAGE_RENAME, rep.stage)
	assert_equal(21, rep.native_error)  # EISDIR
	assert_equal(0, rep.renamed)
	assert_equal(7, rep.transferred)
	char* temp = fs_replace_temp_path(path, getpid(), fs_replace_sequence - 1)
	assert_equal(0, path_exists(temp))
	free(temp)
	assert_equal(0, rmdir(path))


void test_fs_replace_durable_retries_stale_temp_name():
	# A leftover temp file with the next name (e.g. from a crashed process
	# that had the same pid) is skipped via O_EXCL, never overwritten.
	char* path = c"bin/fs_test_replace_stale.txt"
	char* stale = fs_replace_temp_path(path, getpid(), fs_replace_sequence)
	assert_equal(1, file_write_text(stale, c"stale"))
	fs_replace_report rep
	assert_equal(IO_OK, fs_replace_durable(path, c"fresh", 5, &rep))
	char* text = file_read_text(stale)
	assert_strings_equal(c"stale", text)
	free(text)
	text = file_read_text(path)
	assert_strings_equal(c"fresh", text)
	free(text)
	unlink(stale)
	free(stale)
