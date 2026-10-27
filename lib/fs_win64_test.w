# wbuild: arch_only=win64 timeout=120000
# lib/fs.w on Windows x64 (#608): the Windows contract documented in
# docs/projects/durability_ports.md, not POSIX parity. Run under wine in
# tests_win64; wine maps these calls onto the host's POSIX filesystem,
# so passing here checks the adapter and its error mapping, not NTFS or
# device durability. Child processes are this same executable started
# with "--filter test_fs_win64_zchild --fs-child <role> ...".
import lib.testing
import lib.fs
import lib.file
import lib.process
import lib.str

c_lib "kernel32.dll"
extern int GetModuleFileNameA(int module, char* buffer, int size)
extern int GetHandleInformation(int handle, int* flags)
extern int DeviceIoControl(int handle, int code, char* input, int input_size, char* output, int output_size, int* returned, int overlapped)


char* fs_win_path(char* name):
	return strjoin(c"bin/fs_win64_", name)


int fs_win_open_rw(char* path):
	io_result r
	int fd = fs_open(path, FS_O_RDWR | FS_O_CREAT | FS_O_TRUNC | FS_O_CLOEXEC, FS_DEFAULT_MODE, &r)
	asserts(c"fs_open failed", fd >= 0)
	assert_equal(IO_OK, r.status)
	return fd


# The handle's file pointer, through a plain seek (SetFilePointer).
int fs_win_position(int fd):
	return seek(fd, 0, 1)


int fs_win_word_max():
	return (1 << 62) - 1 + (1 << 62)


void test_fs_win64_positional_io_and_file_pointer():
	int fd = fs_win_open_rw(fs_win_path(c"positional.bin"))
	io_result r
	assert_equal(IO_OK, fs_pwrite_all(fd, c"hello", 5, 0, &r))
	assert_equal(5, r.transferred)
	assert_equal(IO_OK, fs_pwrite_all(fd, c"J", 1, 0, &r))
	# Windows contract: a positional transfer on a synchronous handle
	# also leaves the handle's file pointer at its end.
	assert_equal(1, fs_win_position(fd))
	char* buf = cast(char*, malloc(16))
	assert_equal(IO_OK, fs_pread_exact(fd, buf, 4, 1, &r))
	assert_equal(5, fs_win_position(fd))
	buf[4] = 0
	assert_strings_equal(c"ello", buf)
	assert_equal(IO_OK, fs_pread_exact(fd, buf, 5, 0, &r))
	buf[5] = 0
	assert_strings_equal(c"Jello", buf)
	# Reading past the end: EOF with the bytes that existed.
	assert_equal(IO_EOF, fs_pread_exact(fd, buf, 8, 3, &r))
	assert_equal(2, r.transferred)
	assert_equal(IO_EOF, fs_pread(fd, buf, 8, 100, &r))
	assert_equal(0, r.transferred)
	free(buf)
	assert_equal(IO_OK, fs_close(fd, &r))


void test_fs_win64_rejects_bad_ranges():
	int fd = fs_win_open_rw(fs_win_path(c"ranges.bin"))
	io_result r
	char* buf = cast(char*, malloc(8))
	assert_equal(IO_IO_ERROR, fs_pwrite_all(fd, c"x", 1, -1, &r))
	assert_equal(FS_EINVAL, r.native_error)
	assert_equal(IO_IO_ERROR, fs_pread(fd, buf, 1, -5, &r))
	assert_equal(FS_EINVAL, r.native_error)
	assert_equal(IO_IO_ERROR, fs_pwrite_all(fd, c"abcd", 4, fs_win_word_max() - 2, &r))
	assert_equal(FS_EINVAL, r.native_error)
	assert_equal(0, r.transferred)
	# The adapter refuses negative offsets itself too.
	assert_equal(-22, fs_native_pwrite(fd, c"x", 1, -1))
	assert_equal(0, seek(fd, 0, 2))
	assert_equal(IO_OK, fs_pwrite_all(-1, c"", 0, 0, &r))
	free(buf)
	fs_close(fd, &r)


void test_fs_win64_sparse_write_beyond_4gib():
	char* path = fs_win_path(c"sparse.bin")
	int fd = fs_win_open_rw(path)
	# FSCTL_SET_SPARSE (0x900c4) keeps NTFS from zero-filling 5 GiB.
	int returned = 0
	DeviceIoControl(fd, 589988, 0, 0, 0, 0, &returned, 0)
	io_result r
	int offset = 5 * 1024 * 1024 * 1024
	assert_equal(IO_OK, fs_pwrite_all(fd, c"far away", 8, offset, &r))
	assert_equal(8, r.transferred)
	char* buf = cast(char*, malloc(16))
	assert_equal(IO_OK, fs_pread_exact(fd, buf, 8, offset, &r))
	buf[8] = 0
	assert_strings_equal(c"far away", buf)
	assert_equal(IO_OK, fs_pread_exact(fd, buf, 4, offset - 4, &r))
	for i in range(4): assert_equal(0, buf[i])
	# Truncate back down without moving the file pointer.
	int before = fs_win_position(fd)
	assert_equal(IO_OK, fs_ftruncate(fd, 3, &r))
	assert_equal(before, fs_win_position(fd))
	assert_equal(IO_EOF, fs_pread(fd, buf, 1, 3, &r))
	assert_equal(IO_IO_ERROR, fs_ftruncate(fd, -1, &r))
	assert_equal(FS_EINVAL, r.native_error)
	free(buf)
	fs_close(fd, &r)
	fs_native_unlink(path)


void test_fs_win64_ftruncate_extends_and_reports_errors():
	int fd = fs_win_open_rw(fs_win_path(c"truncate.bin"))
	io_result r
	assert_equal(IO_OK, fs_ftruncate(fd, 100, &r))
	assert_equal(100, seek(fd, 0, 2))
	fs_close(fd, &r)
	assert_equal(IO_IO_ERROR, fs_ftruncate(-1, 10, &r))
	assert_equal(9, r.native_error)  # EBADF


void test_fs_win64_create_exclusive_conflicts():
	char* path = fs_win_path(c"exclusive.bin")
	fs_native_unlink(path)
	io_result r
	int fd = fs_create_exclusive(path, FS_DEFAULT_MODE, &r)
	asserts(c"first exclusive create failed", fd >= 0)
	assert_equal(IO_OK, r.status)
	assert_equal(-1, fs_create_exclusive(path, FS_DEFAULT_MODE, &r))
	assert_equal(IO_IO_ERROR, r.status)
	assert_equal(FS_EEXIST, r.native_error)
	assert_equal(1, fs_result_exists(&r))
	asserts(c"exists is ERROR_FILE_EXISTS", (fs_win32_last_error == 80) || (fs_win32_last_error == 183))
	fs_close(fd, &r)
	assert_equal(0, fs_native_unlink(path))
	fd = fs_create_exclusive(path, FS_DEFAULT_MODE, &r)
	asserts(c"exclusive create after unlink failed", fd >= 0)
	fs_close(fd, &r)
	fs_native_unlink(path)


void test_fs_win64_openat_relative_to_directory():
	mkdir(fs_win_path(c"dir"), 493)
	mkdir(fs_win_path(c"dir/sub"), 493)
	io_result r
	int dirfd = fs_open(fs_win_path(c"dir"), FS_O_RDONLY | FS_O_DIRECTORY | FS_O_CLOEXEC, 0, &r)
	asserts(c"open dir failed", dirfd >= 0)
	int fd = fs_openat(dirfd, c"inner.txt", FS_O_WRONLY | FS_O_CREAT | FS_O_TRUNC | FS_O_CLOEXEC, FS_DEFAULT_MODE, &r)
	asserts(c"openat failed", fd >= 0)
	assert_equal(IO_OK, fs_pwrite_all(fd, c"inside", 6, 0, &r))
	fs_close(fd, &r)
	# Nested, with "." components and forward slashes.
	fd = fs_openat(dirfd, c"./sub//deep.txt", FS_O_RDWR | FS_O_CREAT | FS_O_EXCL | FS_O_CLOEXEC, FS_DEFAULT_MODE, &r)
	asserts(c"nested openat failed", fd >= 0)
	fs_close(fd, &r)
	assert_equal(-1, fs_openat(dirfd, c"sub/deep.txt", FS_O_RDWR | FS_O_CREAT | FS_O_EXCL, FS_DEFAULT_MODE, &r))
	assert_equal(FS_EEXIST, r.native_error)
	# ".." cannot be resolved below a directory handle.
	assert_equal(-1, fs_openat(dirfd, c"../escape.txt", FS_O_RDONLY, 0, &r))
	assert_equal(FS_EINVAL, r.native_error)
	assert_equal(-1, fs_openat(dirfd, c"missing.txt", FS_O_RDONLY, 0, &r))
	assert_equal(2, r.native_error)  # ENOENT
	fs_close(dirfd, &r)
	char* text = file_read_text(fs_win_path(c"dir/inner.txt"))
	assert_strings_equal(c"inside", text)
	free(text)
	# O_DIRECTORY on a regular file fails (ENOTDIR).
	assert_equal(-1, fs_open(fs_win_path(c"dir/inner.txt"), FS_O_RDONLY | FS_O_DIRECTORY, 0, &r))
	assert_equal(20, r.native_error)
	# A write open of a directory is EISDIR, as on Linux.
	assert_equal(-1, fs_open(fs_win_path(c"dir"), FS_O_WRONLY, 0, &r))
	assert_equal(21, r.native_error)
	# A bad directory handle is EBADF.
	assert_equal(-1, fs_openat(-1, c"relative", FS_O_RDONLY, 0, &r))
	assert_equal(9, r.native_error)
	fs_native_unlink(fs_win_path(c"dir/sub/deep.txt"))
	fs_native_unlink(fs_win_path(c"dir/inner.txt"))
	rmdir(fs_win_path(c"dir/sub"))
	rmdir(fs_win_path(c"dir"))


void test_fs_win64_utf8_paths():
	# "bin/fs_win64_é.txt": UTF-8 in, UTF-16 to the W entry points.
	char* path = fs_win_path(c"\xc3\xa9.txt")
	fs_replace_report rep
	assert_equal(IO_OK, fs_replace_durable(path, c"accent", 6, &rep))
	io_result r
	int fd = fs_open(path, FS_O_RDONLY | FS_O_CLOEXEC, 0, &r)
	asserts(c"utf-8 path did not round-trip", fd >= 0)
	char[8] buf
	assert_equal(IO_OK, fs_pread_exact(fd, &buf[0], 6, 0, &r))
	fs_close(fd, &r)
	assert_equal(0, fs_native_unlink(path))
	# Invalid UTF-8 is refused before reaching the filesystem.
	assert_equal(-1, fs_open(c"bin/fs_win64_\xff.txt", FS_O_RDONLY, 0, &r))
	assert_equal(84, r.native_error)  # EILSEQ
	assert_equal(1113, fs_win32_last_error)  # ERROR_NO_UNICODE_TRANSLATION


void test_fs_win64_inheritance_follows_cloexec():
	io_result r
	int fd = fs_win_open_rw(fs_win_path(c"inherit.bin"))
	int flags = 0
	assert1(GetHandleInformation(fd, &flags) != 0)
	assert_equal(0, flags & 1)  # HANDLE_FLAG_INHERIT
	fs_close(fd, &r)
	fd = fs_open(fs_win_path(c"inherit.bin"), FS_O_RDWR, 0, &r)
	asserts(c"open without cloexec failed", fd >= 0)
	assert1(GetHandleInformation(fd, &flags) != 0)
	assert_equal(1, flags & 1)
	fs_close(fd, &r)


void test_fs_win64_sync_reports_status():
	io_result r
	int fd = fs_win_open_rw(fs_win_path(c"sync.bin"))
	assert_equal(IO_OK, fs_pwrite_all(fd, c"x", 1, 0, &r))
	assert_equal(IO_OK, fs_fsync(fd, &r))
	fs_close(fd, &r)
	# Directory flush: established or explicitly unsupported, never a
	# silent success on failure.
	int status = fs_sync_dir(c"bin", &r)
	asserts(c"directory sync must be ok or unsupported", (status == IO_OK) || (status == IO_UNSUPPORTED))
	asserts(c"missing dir must fail", fs_sync_dir(fs_win_path(c"no_such_dir"), &r) != IO_OK)
	assert_equal(2, r.native_error)  # ENOENT
	# A pipe cannot be flushed to storage: unsupported, not ok (and not
	# FlushFileBuffers' block-until-drained pipe semantics).
	int* fds = cast(int*, malloc(8))
	assert_equal(0, pipe(fds))
	int rd = load_int32(cast(char*, fds))
	int wr = load_int32(cast(char*, fds) + 4)
	assert_equal(IO_UNSUPPORTED, fs_fsync(wr, &r))
	assert_equal(FS_EINVAL, r.native_error)
	close(rd)
	close(wr)
	free(fds)
	assert_equal(IO_IO_ERROR, fs_fsync(-1, &r))
	assert_equal(9, r.native_error)


void test_fs_win64_lock_contention():
	char* path = fs_win_path(c"lock")
	io_result r
	int first = fs_lock_acquire(path, &r)
	asserts(c"first lock failed", first >= 0)
	assert_equal(IO_OK, r.status)
	# Locks belong to the handle: a second handle in this process
	# contends like another process would.
	assert_equal(-1, fs_lock_acquire(path, &r))
	assert_equal(IO_WOULD_BLOCK, r.status)
	assert_equal(IO_ERRNO_EAGAIN, r.native_error)
	assert_equal(33, fs_win32_last_error)  # ERROR_LOCK_VIOLATION
	# The locked byte lies far beyond the data: the file stays usable.
	int other = fs_open(path, FS_O_RDWR | FS_O_CLOEXEC, 0, &r)
	asserts(c"lock file reopen failed", other >= 0)
	assert_equal(IO_OK, fs_pwrite_all(other, c"pid", 3, 0, &r))
	fs_close(other, &r)
	assert_equal(IO_OK, fs_lock_release(first, &r))
	int again = fs_lock_acquire(path, &r)
	asserts(c"lock after release failed", again >= 0)
	fs_lock_release(again, &r)
	assert_equal(-1, fs_lock_acquire(fs_win_path(c"no_such_dir/x.lock"), &r))
	assert_equal(2, r.native_error)


void test_fs_win64_replace_durable_happy_path():
	char* path = fs_win_path(c"replace.txt")
	assert_equal(1, file_write_text(path, c"old contents"))
	fs_replace_report rep
	assert_equal(IO_OK, fs_replace_durable(path, c"new contents", 12, &rep))
	assert_equal(FS_STAGE_NONE, rep.stage)
	assert_equal(1, rep.renamed)
	assert_equal(12, rep.transferred)
	char* text = file_read_text(path)
	assert_strings_equal(c"new contents", text)
	free(text)
	char* temp = fs_replace_temp_path(path, getpid(), fs_replace_sequence - 1)
	assert_equal(0, path_exists(temp))
	free(temp)
	io_result r
	fs_native_unlink(fs_win_path(c"replace_new.txt"))
	assert_equal(IO_OK, file_write_durable(fs_win_path(c"replace_new.txt"), c"abc", 3, &r))
	assert_equal(3, r.transferred)


void test_fs_win64_replace_durable_open_temp_failure():
	fs_replace_report rep
	int status = fs_replace_durable(fs_win_path(c"no_such_dir/target.txt"), c"x", 1, &rep)
	assert_equal(IO_IO_ERROR, status)
	assert_equal(FS_STAGE_OPEN_TEMP, rep.stage)
	assert_equal(2, rep.native_error)  # ENOENT
	assert_equal(0, rep.renamed)


void test_fs_win64_replace_durable_rename_failure_cleans_up():
	# MoveFileExW refuses to replace a directory (ERROR_ACCESS_DENIED)
	# after the temp file was written, flushed and closed.
	char* path = fs_win_path(c"replace_dir")
	mkdir(path, 493)
	fs_replace_report rep
	int status = fs_replace_durable(path, c"payload", 7, &rep)
	asserts(c"rename over a directory must fail", status != IO_OK)
	assert_equal(FS_STAGE_RENAME, rep.stage)
	assert_equal(13, rep.native_error)  # EACCES
	assert_equal(5, fs_win32_last_error)
	assert_equal(0, rep.renamed)
	assert_equal(7, rep.transferred)
	char* temp = fs_replace_temp_path(path, getpid(), fs_replace_sequence - 1)
	assert_equal(0, path_exists(temp))
	free(temp)
	assert_equal(0, rmdir(path))


void test_fs_win64_replace_durable_retries_stale_temp_name():
	char* path = fs_win_path(c"replace_stale.txt")
	char* stale = fs_replace_temp_path(path, getpid(), fs_replace_sequence)
	assert_equal(1, file_write_text(stale, c"stale"))
	fs_replace_report rep
	assert_equal(IO_OK, fs_replace_durable(path, c"fresh", 5, &rep))
	char* text = file_read_text(stale)
	assert_strings_equal(c"stale", text)
	free(text)
	fs_native_unlink(stale)


void test_fs_win64_error_mapping():
	assert_equal(2, fs_native_errno_from_win32(3))     # path not found
	assert_equal(13, fs_native_errno_from_win32(5))    # access denied
	assert_equal(16, fs_native_errno_from_win32(32))   # sharing violation
	assert_equal(11, fs_native_errno_from_win32(33))   # lock violation
	assert_equal(28, fs_native_errno_from_win32(112))  # disk full
	assert_equal(17, fs_native_errno_from_win32(183))  # already exists
	assert_equal(95, fs_native_errno_from_win32(50))   # not supported
	assert_equal(5, fs_native_errno_from_win32(1117))  # device I/O error
	assert_equal(IO_NO_SPACE, io_status_from_errno(fs_native_errno_from_win32(39)))
	assert_equal(IO_UNSUPPORTED, io_status_from_errno(fs_native_errno_from_win32(1)))


/* Child processes */

char* fs_win_self():
	char* buffer = cast(char*, malloc(1024))
	int n = GetModuleFileNameA(0, buffer, 1024)
	asserts(c"GetModuleFileNameA failed", (n > 0) && (n < 1024))
	return buffer


process* fs_win_spawn(char* role, char* a, char* b):
	char* self = fs_win_self()
	char** argv = strv_new(7)
	strv_set(argv, 0, self)
	strv_set(argv, 1, c"--filter")
	strv_set(argv, 2, c"test_fs_win64_zchild")
	strv_set(argv, 3, c"--fs-child")
	strv_set(argv, 4, role)
	strv_set(argv, 5, a)
	strv_set(argv, 6, b)
	spawn_options* options = spawn_options_new()
	options.stdout_mode = process_null
	process* child = process_spawn(self, argv, options)
	asserts(c"spawn failed", child != 0)
	return child


# Polls (10 ms steps) until path exists; 1 on success.
int fs_win_wait_for(char* path, int timeout_ms):
	int waited = 0
	while (waited < timeout_ms):
		if (path_exists(path)): return 1
		Sleep(10)
		waited = waited + 10
	return 0


# Separate processes, separate handles, the same file: each writer
# repeatedly updates and verifies its own range while the parent writes
# a third one. Positional transfers carry their own offsets, so no
# writer can land in another's range.
void test_fs_win64_concurrent_positional_access():
	char* path = fs_win_path(c"concurrent.bin")
	int fd = fs_win_open_rw(path)
	io_result r
	assert_equal(IO_OK, fs_ftruncate(fd, 64, &r))
	process* first = fs_win_spawn(c"writer", path, c"0")
	process* second = fs_win_spawn(c"writer", path, c"1")
	for round in range(2000): assert_equal(IO_OK, fs_pwrite_all(fd, c"PPPPPPPP", 8, 48, &r))
	assert_equal(0, process_wait(first))
	assert_equal(0, process_wait(second))
	char[64] buf
	assert_equal(IO_OK, fs_pread_exact(fd, &buf[0], 56, 0, &r))
	for i in range(8):
		assert_equal('A', buf[i])
		assert_equal(0, buf[i + 8])
		assert_equal('B', buf[i + 16])
		assert_equal('P', buf[i + 48])
	fs_close(fd, &r)
	fs_native_unlink(path)


# A process holding the lock is terminated; Windows then releases its
# locks asynchronously, so the parent polls for the lock instead of
# expecting it the instant the process exits.
void test_fs_win64_lock_released_after_process_death():
	char* path = fs_win_path(c"crash.lock")
	char* ready = fs_win_path(c"crash.ready")
	fs_native_unlink(ready)
	process* child = fs_win_spawn(c"lock", path, ready)
	asserts(c"lock owner never became ready", fs_win_wait_for(ready, 30000))
	io_result r
	assert_equal(-1, fs_lock_acquire(path, &r))
	assert_equal(IO_WOULD_BLOCK, r.status)
	assert_equal(0, process_kill(child, 9))
	process_wait(child)
	int fd = -1
	int waited = 0
	while ((fd < 0) && (waited < 10000)):
		fd = fs_lock_acquire(path, &r)
		if (fd < 0):
			assert_equal(IO_WOULD_BLOCK, r.status)
			Sleep(10)
			waited = waited + 10
	asserts(c"lock survived owner death", fd >= 0)
	assert_equal(IO_OK, fs_lock_release(fd, &r))
	fs_native_unlink(ready)


# The child half of the two tests above; a no-op in the parent run.
void test_fs_win64_zchild():
	char* command = GetCommandLineA()
	int at = index_of(command, c"--fs-child ")
	if (at < 0): return
	list[char*] words = split(command + at + 11)
	char* role = words[0]
	io_result r
	if (strcmp(role, c"writer") == 0):
		int worker = atoi(words[2])
		int fd = fs_open(words[1], FS_O_RDWR | FS_O_CLOEXEC, 0, &r)
		if (fd < 0): exit(2)
		char* data = c"AAAAAAAA"
		if (worker == 1): data = c"BBBBBBBB"
		char[8] buf
		for round in range(2000):
			if (fs_pwrite_all(fd, data, 8, worker * 16, &r) != IO_OK): exit(3)
			if (fs_pread_exact(fd, &buf[0], 8, worker * 16, &r) != IO_OK): exit(4)
			for i in range(8):
				if (buf[i] != data[i]): exit(5)
		exit(0)
	if (strcmp(role, c"lock") == 0):
		if (fs_lock_acquire(words[1], &r) < 0): exit(2)
		fs_replace_report rep
		if (fs_replace_durable(words[2], c"ready", 5, &rep) != IO_OK): exit(3)
		Sleep(-1)
	exit(9)
