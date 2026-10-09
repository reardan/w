/*
Checked descriptor I/O with an allocation-free result record.

Every operation fills a caller-owned io_result and also returns its
status, so a call site can branch on the return value and still read how
many bytes moved before a failure:

	io_result r
	if (io_write_all(fd, data, n, &r) != IO_OK):
		# r.transferred bytes reached the descriptor; r.native_error
		# holds the positive platform errno (0 when none applies).

Contracts (docs/projects/reliable_services.md):
- An empty request succeeds without touching the descriptor.
- io_read_exact reports IO_EOF together with the bytes it did read when
  input ends early, so a short file is never mistaken for a full record.
- io_write_all advances only by confirmed progress. A zero-byte write
  while bytes remain is IO_IO_ERROR (native_error 0), not a spin.
- EINTR is retried by these blocking-style loops; EAGAIN is returned as
  IO_WOULD_BLOCK for the caller (or the task adapter in lib.task_io) to
  await. A failure after progress does not roll anything back.

The platform errno is preserved next to the portable category; nothing
here allocates. wresult[T] (lib.result) stays the general recoverable
result type; this record exists because I/O needs a transferred count
alongside the error, and widening wresult would change the '?' lowering.
*/
import lib.lib


# Portable status categories. IO_OK is 0 so `if (status)` tests failure.
const int IO_OK = 0
const int IO_EOF = 1
const int IO_WOULD_BLOCK = 2
const int IO_INTERRUPTED = 3
const int IO_CANCELLED = 4
const int IO_TIMED_OUT = 5
const int IO_NO_SPACE = 6
const int IO_UNSUPPORTED = 7
const int IO_IO_ERROR = 8


# Native errno values; the syscall convention is -errno on every target.
import lib.__arch__.io_errno

struct io_result:
	int transferred     # bytes confirmed moved by this call
	int status          # IO_* category
	int native_error    # positive platform errno, 0 when none applies


# Maps a positive errno to its portable IO_* category.
int io_status_from_errno(int err):
	if (err == 0): return IO_OK
	if (err == IO_ERRNO_EAGAIN): return IO_WOULD_BLOCK
	if (err == IO_ERRNO_EINTR): return IO_INTERRUPTED
	if (err == IO_ERRNO_ECANCELED): return IO_CANCELLED
	if (err == IO_ERRNO_ETIMEDOUT): return IO_TIMED_OUT
	if ((err == IO_ERRNO_ENOSPC) || (err == IO_ERRNO_EDQUOT)): return IO_NO_SPACE
	if ((err == IO_ERRNO_ENOSYS) || (err == IO_ERRNO_EOPNOTSUPP) || (err == IO_ERRNO_ENOTSUP)): return IO_UNSUPPORTED
	return IO_IO_ERROR


char* io_status_name(int status):
	if (status == IO_OK): return c"ok"
	if (status == IO_EOF): return c"eof"
	if (status == IO_WOULD_BLOCK): return c"would_block"
	if (status == IO_INTERRUPTED): return c"interrupted"
	if (status == IO_CANCELLED): return c"cancelled"
	if (status == IO_TIMED_OUT): return c"timed_out"
	if (status == IO_NO_SPACE): return c"no_space"
	if (status == IO_UNSUPPORTED): return c"unsupported"
	return c"io_error"


# Fills r and returns its status.
int io_result_set(io_result* r, int transferred, int status, int native_error):
	r.transferred = transferred
	r.status = status
	r.native_error = native_error
	return status


# Fills r from a raw syscall return (count >= 0, or a negative errno).
# A non-negative return is IO_OK with that count; 0 stays IO_OK so the
# caller decides what zero progress means for its operation.
int io_result_from_syscall(io_result* r, int ret):
	if (ret >= 0): return io_result_set(r, ret, IO_OK, 0)
	return io_result_set(r, 0, io_status_from_errno(0 - ret), 0 - ret)


# One read(2). transferred 0 with IO_EOF means end of input; EINTR is
# retried, EAGAIN reported as IO_WOULD_BLOCK.
int io_read_some(int fd, char* destination, int length, io_result* r):
	if (length <= 0): return io_result_set(r, 0, IO_OK, 0)
	while (1):
		int n = read(fd, destination, length)
		if (n == (0 - IO_ERRNO_EINTR)): continue
		if (n == 0): return io_result_set(r, 0, IO_EOF, 0)
		return io_result_from_syscall(r, n)
	return IO_IO_ERROR


# One write(2). EINTR is retried; a successful write may be partial.
int io_write_some(int fd, char* source, int length, io_result* r):
	if (length <= 0): return io_result_set(r, 0, IO_OK, 0)
	while (1):
		int n = write(fd, source, length)
		if (n == (0 - IO_ERRNO_EINTR)): continue
		return io_result_from_syscall(r, n)
	return IO_IO_ERROR


# Reads exactly length bytes unless input ends or fails first. On early
# end of input returns IO_EOF with transferred < length; on an error the
# transferred count says how much landed in destination.
int io_read_exact(int fd, char* destination, int length, io_result* r):
	int total = 0
	io_result step
	while (total < length):
		int status = io_read_some(fd, destination + total, length - total, &step)
		if (status != IO_OK):
			return io_result_set(r, total, status, step.native_error)
		total = total + step.transferred
	return io_result_set(r, total, IO_OK, 0)


# Writes all length bytes. Stops at the first failure with the confirmed
# prefix in transferred; a zero-byte write while bytes remain is
# IO_IO_ERROR rather than an endless retry.
int io_write_all(int fd, char* source, int length, io_result* r):
	int total = 0
	io_result step
	while (total < length):
		int status = io_write_some(fd, source + total, length - total, &step)
		if (status != IO_OK):
			return io_result_set(r, total, status, step.native_error)
		if (step.transferred <= 0):
			return io_result_set(r, total, IO_IO_ERROR, 0)
		total = total + step.transferred
	return io_result_set(r, total, IO_OK, 0)


# close(2) reporting its error. Never retried: on Linux the descriptor is
# released even when close fails (EINTR included), and a retry could close
# a descriptor another thread just reused. A failure means earlier writes
# may not have reached the file; it never means the fd is still open.
int io_close(int fd, io_result* r):
	return io_result_from_syscall(r, close(fd))
