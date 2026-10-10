/*
File durability primitives: positional I/O, truncate, exclusive create,
directory-relative open, directory sync, process-lifetime file locks
and durable replace (docs/projects/reliable_services.md, stage W1).

Every operation fills a caller-owned io_result (lib/io.w) and returns
its status (open-like calls return the descriptor, or -1 with the
status in r). The platform errno is kept in r.native_error.

Architecture adapters: Linux x86/x64/ARM64 and ARM64 Darwin. Native
ARM64 qualification is tracked in docs/projects/durability_ports.md;
Darwin/APFS has native process-crash coverage on Apple Silicon.
Implementation and cross-compilation do not establish hardware durability.
Windows and wasm remain explicitly unsupported. Positional I/O is never
seek + write. Flags below use the portable Linux x86 numbering; Darwin
translates them in its syscall adapter.

Offsets are word-sized signed byte offsets: 63 bits on 64-bit targets,
31 bits on i386. Range overflow is rejected before invoking the kernel.

Durability requires a local filesystem and device that honor both file
and directory barriers and same-directory atomic rename. Darwin requires
fsync followed by F_FULLFSYNC, including the directory barrier: failure
is preserved, never silently downgraded to fsync. A filesystem that cannot provide the barrier
returns IO_UNSUPPORTED or IO_IO_ERROR, with publication stage retained.
Network filesystems and devices that lie about flush completion are outside
the guarantee. Process-crash tests are not power-loss qualification.

Status summary beyond lib/io.w's categories:
- exclusive create of an existing path: IO_IO_ERROR with native_error
  FS_EEXIST (17); fs_result_exists(r) tests for it.
- lock contention in fs_lock_acquire: IO_WOULD_BLOCK (EWOULDBLOCK).
- invalid offsets/lengths (negative, or offset + length overflowing a
  word): IO_IO_ERROR with native_error FS_EINVAL (22), nothing touched.
- directory fsync refused by the filesystem: IO_UNSUPPORTED (22).
*/
import lib.lib
import lib.io
import lib.path


# Portable open flags; architecture adapters translate native differences.
const int FS_O_RDONLY = 0
const int FS_O_WRONLY = 1
const int FS_O_RDWR = 2
const int FS_O_CREAT = 64
const int FS_O_EXCL = 128
const int FS_O_TRUNC = 512
const int FS_O_DIRECTORY = 65536
const int FS_O_CLOEXEC = 524288

# The *at dirfd naming the current working directory.
const int FS_AT_FDCWD = -100

# flock(2) operations.
const int FS_LOCK_SH = 1
const int FS_LOCK_EX = 2
const int FS_LOCK_NB = 4
const int FS_LOCK_UN = 8

const int FS_EEXIST = 17
const int FS_EINVAL = 22

# Default permission bits for files this module creates (rw-r--r--,
# before umask).
const int FS_DEFAULT_MODE = 420


/* Opening */

# openat(2): returns the descriptor, or -1 with r describing the error.
int fs_openat(int dirfd, char* path, int flags, int mode, io_result* r):
	int fd = sys_openat(dirfd, path, flags, mode)
	io_result_from_syscall(r, fd)
	if (fd < 0): return -1
	r.transferred = 0
	return fd


int fs_open(char* path, int flags, int mode, io_result* r):
	return fs_openat(FS_AT_FDCWD, path, flags, mode, r)


# Creates path read-write, failing if anything already exists there --
# one O_CREAT|O_EXCL openat, so there is no check-then-create race.
# Returns the descriptor, or -1 (fs_result_exists(r) on a conflict).
int fs_create_exclusive(char* path, int mode, io_result* r):
	return fs_open(path, FS_O_RDWR | FS_O_CREAT | FS_O_EXCL | FS_O_CLOEXEC, mode, r)


# 1 when r failed because the path already exists.
int fs_result_exists(io_result* r):
	return (r.status != IO_OK) && (r.native_error == FS_EEXIST)


/* Positional I/O: never moves the descriptor's shared file position. */

# Validates a positional request: a non-negative offset and length whose
# sum fits a word. Returns IO_OK or fills r with EINVAL.
int fs_check_range(int offset, int length, io_result* r):
	if ((offset < 0) || (length < 0)): return io_result_set(r, 0, IO_IO_ERROR, FS_EINVAL)
	# Both are non-negative, so a wrapped sum is negative.
	if ((offset + length) < 0): return io_result_set(r, 0, IO_IO_ERROR, FS_EINVAL)
	return io_result_set(r, 0, IO_OK, 0)


# One pread at offset; may be partial. EINTR is retried; reading at or
# past end of file is IO_EOF with transferred 0.
int fs_pread(int fd, char* destination, int length, int offset, io_result* r):
	if (fs_check_range(offset, length, r) != IO_OK): return r.status
	if (length == 0): return IO_OK
	while (1):
		int n = sys_pread(fd, destination, length, offset)
		if (n == (0 - IO_ERRNO_EINTR)): continue
		if (n == 0): return io_result_set(r, 0, IO_EOF, 0)
		return io_result_from_syscall(r, n)
	return IO_IO_ERROR


# One pwrite at offset; may be partial. EINTR is retried.
int fs_pwrite(int fd, char* source, int length, int offset, io_result* r):
	if (fs_check_range(offset, length, r) != IO_OK): return r.status
	if (length == 0): return IO_OK
	while (1):
		int n = sys_pwrite(fd, source, length, offset)
		if (n == (0 - IO_ERRNO_EINTR)): continue
		return io_result_from_syscall(r, n)
	return IO_IO_ERROR


# Reads length bytes at offset unless the file ends or a read fails
# first: IO_EOF with transferred < length when it ends early.
int fs_pread_exact(int fd, char* destination, int length, int offset, io_result* r):
	if (fs_check_range(offset, length, r) != IO_OK): return r.status
	int total = 0
	io_result step
	while (total < length):
		int status = fs_pread(fd, destination + total, length - total, offset + total, &step)
		if (status != IO_OK): return io_result_set(r, total, status, step.native_error)
		total = total + step.transferred
	return io_result_set(r, total, IO_OK, 0)


# Writes all length bytes at offset, advancing only by confirmed
# progress; zero progress while bytes remain is IO_IO_ERROR. On failure
# transferred is the prefix written (no rollback).
int fs_pwrite_all(int fd, char* source, int length, int offset, io_result* r):
	if (fs_check_range(offset, length, r) != IO_OK): return r.status
	int total = 0
	io_result step
	while (total < length):
		int status = fs_pwrite(fd, source + total, length - total, offset + total, &step)
		if (status != IO_OK): return io_result_set(r, total, status, step.native_error)
		if (step.transferred <= 0): return io_result_set(r, total, IO_IO_ERROR, 0)
		total = total + step.transferred
	return io_result_set(r, total, IO_OK, 0)


/* Size and sync */

# Sets the file's size (extending with zeros or discarding the tail).
# Makes no durability claim: follow with fs_fsync.
int fs_ftruncate(int fd, int length, io_result* r):
	if (length < 0): return io_result_set(r, 0, IO_IO_ERROR, FS_EINVAL)
	while (1):
		int ret = sys_ftruncate(fd, length)
		if (ret == (0 - IO_ERRNO_EINTR)): continue
		return io_result_from_syscall(r, ret)
	return IO_IO_ERROR


# fsync(2). EINVAL (the descriptor cannot be synced, e.g. a pipe, or a
# filesystem that refuses directory sync) is IO_UNSUPPORTED: never
# reported as success. Not retried after a failure on purpose -- Linux
# may already have dropped the dirty pages.
int fs_fsync(int fd, io_result* r):
	int ret = fsync(fd)
	if (ret == (0 - FS_EINVAL)): return io_result_set(r, 0, IO_UNSUPPORTED, FS_EINVAL)
	return io_result_from_syscall(r, ret)


# Makes the directory's entries (creates, renames, unlinks inside it)
# durable. IO_OK means directory-entry durability was established;
# anything else means it was not (IO_UNSUPPORTED where the filesystem
# refuses directory fsync).
int fs_sync_dir(char* dir_path, io_result* r):
	int fd = fs_open(dir_path, FS_O_RDONLY | FS_O_DIRECTORY | FS_O_CLOEXEC, 0, r)
	if (fd < 0): return r.status
	int status = fs_fsync(fd, r)
	io_result closed
	io_close(fd, &closed)
	return status


# fs_sync_dir on the directory containing path.
int fs_sync_parent_dir(char* path, io_result* r):
	char* parent = path_dirname(path)
	int status = fs_sync_dir(parent, r)
	free(parent)
	return status


/* Process-lifetime locks */

# Opens (creating if needed) the lock file at path and takes an
# exclusive, non-blocking flock on it. Returns the lock's descriptor
# (keep it open for as long as the lock must be held), or -1:
# IO_WOULD_BLOCK when another open file description holds the lock (a
# different process, or another fs_lock_acquire in this one), another
# status when the file cannot be opened or locked. The lock is released
# by fs_lock_release, or by the kernel when the process exits. It is
# advisory: it only excludes other fs_lock_acquire / flock users.
int fs_lock_acquire(char* path, io_result* r):
	int fd = fs_open(path, FS_O_RDWR | FS_O_CREAT | FS_O_CLOEXEC, FS_DEFAULT_MODE, r)
	if (fd < 0): return -1
	int ret = sys_flock(fd, FS_LOCK_EX | FS_LOCK_NB)
	while (ret == (0 - IO_ERRNO_EINTR)): ret = sys_flock(fd, FS_LOCK_EX | FS_LOCK_NB)
	if (ret < 0):
		io_result_from_syscall(r, ret)
		io_result closed
		io_close(fd, &closed)
		return -1
	io_result_set(r, 0, IO_OK, 0)
	return fd


# Releases a lock from fs_lock_acquire by closing its descriptor.
int fs_lock_release(int fd, io_result* r):
	return io_close(fd, r)


/* Durable replace */

# Stages of fs_replace_durable, in order.
const int FS_STAGE_NONE = 0
const int FS_STAGE_OPEN_TEMP = 1
const int FS_STAGE_WRITE = 2
const int FS_STAGE_SYNC_FILE = 3
const int FS_STAGE_CLOSE = 4
const int FS_STAGE_RENAME = 5
const int FS_STAGE_SYNC_DIR = 6


struct fs_replace_report:
	int status        # IO_* of the failing stage; IO_OK when fully durable
	int native_error  # its positive errno (0 when none applies)
	int stage         # FS_STAGE_* that failed; FS_STAGE_NONE on success
	int renamed       # 1 once the rename succeeded: path names the new contents
	int transferred   # bytes written to the temp file


char* fs_stage_name(int stage):
	if (stage == FS_STAGE_NONE): return c"none"
	if (stage == FS_STAGE_OPEN_TEMP): return c"open_temp"
	if (stage == FS_STAGE_WRITE): return c"write"
	if (stage == FS_STAGE_SYNC_FILE): return c"sync_file"
	if (stage == FS_STAGE_CLOSE): return c"close"
	if (stage == FS_STAGE_RENAME): return c"rename"
	return c"sync_dir"


# Next temp-file sequence number (per process; the pid separates
# processes and O_EXCL is the backstop against stale leftovers).
int fs_replace_sequence


# The temp sibling name for path: "<path>.tmp.<pid>.<sequence>", in the
# same directory so the rename cannot cross filesystems. malloc'd.
char* fs_replace_temp_path(char* path, int pid, int sequence):
	char* pid_text = itoa(pid)
	char* sequence_text = itoa(sequence)
	int length = strlen(path) + 5 + strlen(pid_text) + 1 + strlen(sequence_text)
	char* result = cast(char*, malloc(length + 1))
	char* cur = strcpy(result, path)
	cur = strcpy(cur, c".tmp.")
	cur = strcpy(cur, pid_text)
	cur = strcpy(cur, c".")
	strcpy(cur, sequence_text)
	free(pid_text)
	free(sequence_text)
	return result


int fs_replace_fail(fs_replace_report* rep, int stage, int status, int native_error):
	rep.stage = stage
	rep.status = status
	rep.native_error = native_error
	return status


# Atomically and durably replaces path's contents with length bytes of
# data, created with mode: create a temp sibling with O_EXCL, write it
# all, fsync it, close it (checked), rename it over path, then fsync the
# parent directory. Returns IO_OK only when every step succeeded, i.e.
# the new contents survive a crash.
#
# On failure rep says which stage failed and whether the rename already
# happened:
# - renamed == 0 (open_temp .. rename): path is untouched (still the old
#   contents, or still absent) and the temp file has been removed.
# - renamed == 1 (sync_dir): path already names the NEW contents and
#   readers may see them, but whether the rename survives a crash is
#   unknown. This is not an ordinary "unchanged" failure -- the caller
#   must not assume the old contents are still in place.
int fs_replace_durable_mode(char* path, char* data, int length, int mode, fs_replace_report* rep):
	rep.status = IO_OK
	rep.native_error = 0
	rep.stage = FS_STAGE_NONE
	rep.renamed = 0
	rep.transferred = 0
	if (length < 0): return fs_replace_fail(rep, FS_STAGE_WRITE, IO_IO_ERROR, FS_EINVAL)
	io_result r
	char* temp = 0
	int fd = -1
	int pid = getpid()
	int attempt = 0
	while (attempt < 16):
		attempt = attempt + 1
		temp = fs_replace_temp_path(path, pid, fs_replace_sequence)
		fs_replace_sequence = fs_replace_sequence + 1
		fd = fs_open(temp, FS_O_WRONLY | FS_O_CREAT | FS_O_EXCL | FS_O_CLOEXEC, mode, &r)
		if (fd >= 0): break
		free(temp)
		temp = 0
		# Only a leftover temp file with this exact name is worth retrying.
		if (fs_result_exists(&r) == 0): break
	if (fd < 0): return fs_replace_fail(rep, FS_STAGE_OPEN_TEMP, r.status, r.native_error)

	int stage = FS_STAGE_WRITE
	int status = io_write_all(fd, data, length, &r)
	rep.transferred = r.transferred
	if (status == IO_OK):
		stage = FS_STAGE_SYNC_FILE
		status = fs_fsync(fd, &r)
	if (status != IO_OK):
		io_result closed
		io_close(fd, &closed)
	else:
		stage = FS_STAGE_CLOSE
		status = io_close(fd, &r)
	if (status == IO_OK):
		stage = FS_STAGE_RENAME
		status = io_result_from_syscall(&r, rename(temp, path))
	if (status != IO_OK):
		unlink(temp)
		free(temp)
		return fs_replace_fail(rep, stage, status, r.native_error)
	free(temp)
	rep.renamed = 1

	status = fs_sync_parent_dir(path, &r)
	if (status != IO_OK): return fs_replace_fail(rep, FS_STAGE_SYNC_DIR, status, r.native_error)
	return IO_OK


# fs_replace_durable_mode with FS_DEFAULT_MODE (rw-r--r--, before umask).
int fs_replace_durable(char* path, char* data, int length, fs_replace_report* rep):
	return fs_replace_durable_mode(path, data, length, FS_DEFAULT_MODE, rep)


# The durable counterpart of lib/file.w's file_write_text: writes length
# bytes through fs_replace_durable. Returns IO_OK once the contents are
# crash-durable; otherwise the failing status (r.transferred = bytes
# written to the temp file). Callers that must distinguish "renamed but
# directory sync failed" from "unchanged" use fs_replace_durable.
int file_write_durable(char* path, char* data, int length, io_result* r):
	fs_replace_report rep
	int status = fs_replace_durable(path, data, length, &rep)
	return io_result_set(r, rep.transferred, status, rep.native_error)
