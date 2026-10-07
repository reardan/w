/*
Injectable file operations (docs/projects/simulation.md, issue #514
stage W4).

file_ops is a table of functions plus a self pointer, so storage code
written against it runs unchanged on the real filesystem
(file_ops_real_new) or on lib/fake_fs.w's crash-simulating fake. Every
operation fills a caller-owned io_result (lib/io.w) and returns its
IO_* status; native_error keeps the platform errno.

Completion levels are distinct and never implied by one another:

- write-completed: file_ops_write returned IO_OK. The bytes are visible
  to later reads through any descriptor, but a crash may lose them, or
  keep only a prefix of them.
- sync-completed: file_ops_sync (fsync) or file_ops_datasync returned
  IO_OK. The file's data written before the call survives a crash.
- a name created, renamed or unlinked in a directory survives a crash
  only once file_ops_sync_dir on that directory returned IO_OK; syncing
  the file is not enough. A failed sync promises nothing: the data may
  or may not be durable, and on Linux a retry can report success for
  pages the kernel already dropped (treat a sync failure as fatal for
  that file's unsynced data).

Like lib/io.w's low-level calls, read and write may move fewer bytes
than asked and may report IO_INTERRUPTED or IO_WOULD_BLOCK;
file_ops_write_all / file_ops_read_exact / file_ops_read_to_end loop
over short transfers and retry IO_INTERRUPTED, and return every other
non-OK status with the transferred prefix. A read at end of file
reports IO_EOF with transferred 0.

Open flags are named here (Linux generic values; the arm64_darwin
syscall layer translates them). Paths are '/'-separated; the directory
of "a/b" is "a", of "b" it is ".".

The real adapter needs no state and allocates nothing per call except
for sync_dir, which opens the directory read-only, fsyncs and closes
it. Seek and truncate support single-owner storage cursors. Concurrent
positional I/O remains in lib/fs.w.
*/
import lib.lib
import lib.io
import lib.fs


const int FILE_OPS_READ = 0          # O_RDONLY
const int FILE_OPS_WRITE = 1         # O_WRONLY
const int FILE_OPS_READ_WRITE = 2    # O_RDWR
const int FILE_OPS_CREATE = 64       # O_CREAT
const int FILE_OPS_EXCLUSIVE = 128   # O_EXCL
const int FILE_OPS_TRUNCATE = 512    # O_TRUNC
const int FILE_OPS_APPEND = 1024     # O_APPEND
const int FILE_OPS_CLOEXEC = 524288  # O_CLOEXEC, always added by the real adapter


# self, path, flags, mode, fd out, result
type file_ops_open_fn = fn(void*, char*, int, int, int*, io_result*) -> int
# self, fd, result (close, sync, datasync)
type file_ops_fd_fn = fn(void*, int, io_result*) -> int
# self, fd, buffer, length, result (read, write)
type file_ops_io_fn = fn(void*, int, char*, int, io_result*) -> int
# self, path, result (unlink, sync_dir)
type file_ops_path_fn = fn(void*, char*, io_result*) -> int
# self, from, to, result (rename)
type file_ops_path2_fn = fn(void*, char*, char*, io_result*) -> int
# self, path, mode, result (mkdir)
type file_ops_mkdir_fn = fn(void*, char*, int, io_result*) -> int


type file_ops_seek_fn = fn(void*, int, int, int, io_result*) -> int
type file_ops_truncate_fn = fn(void*, int, int, io_result*) -> int


struct file_ops:
	void* self
	file_ops_open_fn* open
	file_ops_fd_fn* close
	file_ops_io_fn* read
	file_ops_io_fn* write
	file_ops_fd_fn* sync
	file_ops_fd_fn* datasync
	file_ops_path2_fn* rename
	file_ops_path_fn* unlink
	file_ops_mkdir_fn* mkdir
	file_ops_path_fn* sync_dir
	file_ops_seek_fn* seek
	file_ops_truncate_fn* truncate


/* Dispatch. */

# Opens path; on IO_OK fd_out holds the descriptor (else -1).
int file_ops_open(file_ops* ops, char* path, int flags, int mode, int* fd_out, io_result* r):
	return ops.open(ops.self, path, flags, mode, fd_out, r)


# Releases fd whatever the status (never retry a failed close).
int file_ops_close(file_ops* ops, int fd, io_result* r):
	return ops.close(ops.self, fd, r)


int file_ops_read(file_ops* ops, int fd, char* buffer, int length, io_result* r):
	return ops.read(ops.self, fd, buffer, length, r)


int file_ops_write(file_ops* ops, int fd, char* buffer, int length, io_result* r):
	return ops.write(ops.self, fd, buffer, length, r)


# fsync: IO_OK = sync-completed for everything written to fd before.
int file_ops_sync(file_ops* ops, int fd, io_result* r):
	return ops.sync(ops.self, fd, r)


# fdatasync: as file_ops_sync, but may skip metadata a read does not need.
int file_ops_datasync(file_ops* ops, int fd, io_result* r):
	return ops.datasync(ops.self, fd, r)


int file_ops_rename(file_ops* ops, char* from, char* to, io_result* r):
	return ops.rename(ops.self, from, to, r)


int file_ops_unlink(file_ops* ops, char* path, io_result* r):
	return ops.unlink(ops.self, path, r)


int file_ops_mkdir(file_ops* ops, char* path, int mode, io_result* r):
	return ops.mkdir(ops.self, path, mode, r)


# Makes the directory's entries (creates, renames, unlinks) durable.
int file_ops_sync_dir(file_ops* ops, char* path, io_result* r):
	return ops.sync_dir(ops.self, path, r)


# On success transferred is the resulting cursor position.
int file_ops_seek(file_ops* ops, int fd, int offset, int whence, io_result* r):
	if (cast(int, ops.seek) == 0): return io_result_set(r, 0, IO_UNSUPPORTED, 0)
	return ops.seek(ops.self, fd, offset, whence, r)


int file_ops_truncate(file_ops* ops, int fd, int length, io_result* r):
	if (length < 0): return io_result_set(r, 0, IO_IO_ERROR, FS_EINVAL)
	if (cast(int, ops.truncate) == 0): return io_result_set(r, 0, IO_UNSUPPORTED, 0)
	return ops.truncate(ops.self, fd, length, r)


/* Loops over short transfers. */

# Writes all length bytes: short writes continue, IO_INTERRUPTED is
# retried, a zero-byte write is IO_IO_ERROR. transferred is the
# confirmed prefix whatever the status.
int file_ops_write_all(file_ops* ops, int fd, char* source, int length, io_result* r):
	if (length < 0): return io_result_set(r, 0, IO_IO_ERROR, FS_EINVAL)
	int total = 0
	io_result step
	while (total < length):
		int status = file_ops_write(ops, fd, source + total, length - total, &step)
		if (status == IO_INTERRUPTED): continue
		if (status != IO_OK): return io_result_set(r, total + step.transferred, status, step.native_error)
		if (step.transferred <= 0 || step.transferred > length - total): return io_result_set(r, total, IO_IO_ERROR, 0)
		total = total + step.transferred
	return io_result_set(r, total, IO_OK, 0)


# Reads exactly length bytes; IO_EOF with the short count when the file
# ends first. IO_INTERRUPTED is retried.
int file_ops_read_exact(file_ops* ops, int fd, char* destination, int length, io_result* r):
	if (length < 0): return io_result_set(r, 0, IO_IO_ERROR, FS_EINVAL)
	int total = 0
	io_result step
	while (total < length):
		int status = file_ops_read(ops, fd, destination + total, length - total, &step)
		if (status == IO_INTERRUPTED): continue
		if (status != IO_OK): return io_result_set(r, total + step.transferred, status, step.native_error)
		if (step.transferred <= 0 || step.transferred > length - total): return io_result_set(r, total, IO_IO_ERROR, 0)
		total = total + step.transferred
	return io_result_set(r, total, IO_OK, 0)


# Reads until end of file or capacity bytes: IO_OK with the count read
# (reaching EOF is success here; capacity full is too, without probing
# further). IO_INTERRUPTED is retried.
int file_ops_read_to_end(file_ops* ops, int fd, char* destination, int capacity, io_result* r):
	if (capacity < 0): return io_result_set(r, 0, IO_IO_ERROR, FS_EINVAL)
	int total = 0
	io_result step
	while (total < capacity):
		int status = file_ops_read(ops, fd, destination + total, capacity - total, &step)
		if (status == IO_INTERRUPTED): continue
		if (status == IO_EOF): break
		if (status != IO_OK): return io_result_set(r, total + step.transferred, status, step.native_error)
		if (step.transferred <= 0 || step.transferred > capacity - total): return io_result_set(r, total, IO_IO_ERROR, 0)
		total = total + step.transferred
	return io_result_set(r, total, IO_OK, 0)


# "a/b/c" -> "a/b", "c" -> ".", "/c" -> "/". Returns a malloc'd string.
char* file_ops_parent(char* path):
	int n = strlen(path)
	int cut = -1
	for i in range(n):
		if (path[i] == '/'): cut = i
	if (cut < 0):
		char* dot = cast(char*, malloc(2))
		dot[0] = '.'
		dot[1] = 0
		return dot
	if (cut == 0): cut = 1
	char* out = cast(char*, malloc(cut + 1))
	for i in range(cut): out[i] = path[i]
	out[cut] = 0
	return out


/* The real adapter: Linux syscalls via lib/io.w. */

int file_ops_real_open(void* self, char* path, int flags, int mode, int* fd_out, io_result* r):
	while (1):
		int fd = open(path, flags | FILE_OPS_CLOEXEC, mode)
		if (fd == (0 - IO_ERRNO_EINTR)): continue
		if (fd < 0):
			fd_out[0] = -1
			return io_result_from_syscall(r, fd)
		fd_out[0] = fd
		return io_result_set(r, 0, IO_OK, 0)
	return IO_IO_ERROR


int file_ops_real_close(void* self, int fd, io_result* r):
	return io_close(fd, r)


int file_ops_real_read(void* self, int fd, char* buffer, int length, io_result* r):
	return io_read_some(fd, buffer, length, r)


int file_ops_real_write(void* self, int fd, char* buffer, int length, io_result* r):
	return io_write_some(fd, buffer, length, r)


# A raw status-only syscall return (0 or -errno), EINTR retried.
int file_ops_real_status(io_result* r, int ret):
	if (ret >= 0): return io_result_set(r, 0, IO_OK, 0)
	return io_result_from_syscall(r, ret)


int file_ops_real_sync(void* self, int fd, io_result* r):
	int ret = fsync(fd)
	while (ret == (0 - IO_ERRNO_EINTR)): ret = fsync(fd)
	return file_ops_real_status(r, ret)


int file_ops_real_datasync(void* self, int fd, io_result* r):
	int ret = fdatasync(fd)
	while (ret == (0 - IO_ERRNO_EINTR)): ret = fdatasync(fd)
	return file_ops_real_status(r, ret)


int file_ops_real_rename(void* self, char* from, char* to, io_result* r):
	return file_ops_real_status(r, rename(from, to))


int file_ops_real_unlink(void* self, char* path, io_result* r):
	return file_ops_real_status(r, unlink(path))


int file_ops_real_mkdir(void* self, char* path, int mode, io_result* r):
	return file_ops_real_status(r, mkdir(path, mode))


# open(dir, O_RDONLY) + fsync + close. A close failure after a good
# fsync is reported too: durability was established, but the caller
# should know the descriptor misbehaved.
int file_ops_real_sync_dir(void* self, char* path, io_result* r):
	int fd = 0
	if (file_ops_real_open(self, path, FILE_OPS_READ, 0, &fd, r) != IO_OK): return r.status
	int status = file_ops_real_sync(self, fd, r)
	io_result closed
	io_close(fd, &closed)
	if (status != IO_OK): return status
	return io_result_set(r, 0, closed.status, closed.native_error)


# Seek is for single-owner storage cursors, not concurrent positional I/O.
int file_ops_real_seek(void* self, int fd, int offset, int whence, io_result* r):
	return io_result_from_syscall(r, seek(fd, offset, whence))


int file_ops_real_truncate(void* self, int fd, int length, io_result* r):
	return fs_ftruncate(fd, length, r)


file_ops* file_ops_new(void* self):
	file_ops* ops = new file_ops()
	ops.self = self
	return ops


# The real filesystem. Free with free().
file_ops* file_ops_real_new():
	file_ops* ops = file_ops_new(0)
	ops.open = file_ops_real_open
	ops.close = file_ops_real_close
	ops.read = file_ops_real_read
	ops.write = file_ops_real_write
	ops.sync = file_ops_real_sync
	ops.datasync = file_ops_real_datasync
	ops.rename = file_ops_real_rename
	ops.unlink = file_ops_real_unlink
	ops.mkdir = file_ops_real_mkdir
	ops.sync_dir = file_ops_real_sync_dir
	ops.seek = file_ops_real_seek
	ops.truncate = file_ops_real_truncate
	return ops
