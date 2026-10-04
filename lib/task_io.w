/*
Awaitable I/O on the task runtime (docs/projects/async.md): retry-on-
EAGAIN loops over lib/net.w that suspend the calling task instead of
blocking the thread, plus a worker-process helper for work that cannot
be made non-blocking.

Descriptors must be non-blocking; task_accept and task_connect_ipv4
set that up on the fds they touch, everything else expects
socket_set_nonblocking (or O_NONBLOCK) to have been applied already.
All results follow the negative-errno convention, including the
runtime's own task_err_cancelled() and task_err_timed_out(); the
*_result variants report through lib/io.w's io_result instead, with the
bytes moved before a failure in r.transferred.

EINTR policy: an interrupted read or write is retried, after checking
the calling task's cancellation and deadline (task_park_check) so an
interrupt storm cannot outlive a cancel. Outside a task it is simply
retried. A zero-byte write while bytes remain is an error (IO_IO_ERROR,
legacy -EIO), never an endless loop.
*/
import lib.lib
import lib.io
import lib.net
import lib.poll
import lib.process
import lib.task


# After EINTR: 0 to retry, or the negative errno (cancellation or an
# expired deadline) that must end the operation instead.
int task_io_interrupted():
	if (task_in_task() == 0): return 0
	return task_park_check(task_current())


# Read up to len bytes. Returns bytes read, 0 on EOF, or a negative
# errno; suspends while the descriptor has nothing to deliver.
int task_read(int fd, char* buf, int len):
	while (1):
		int n = read(fd, buf, len)
		if (n == (0 - IO_ERRNO_EINTR)):
			int stop = task_io_interrupted()
			if (stop < 0):
				return stop
			continue
		if (n != -11): /* EAGAIN */
			return n
		int revents = task_await_fd(fd, poll_in)
		if (revents < 0):
			return revents


# Read exactly n bytes unless EOF or an error cuts the stream short.
# Returns IO_OK (transferred == n), IO_EOF with the short count, or the
# error (IO_CANCELLED / IO_TIMED_OUT for the task runtime's own) with
# the bytes that landed in buf before it.
int task_read_exact_result(int fd, char* buf, int n, io_result* r):
	int total = 0
	while (total < n):
		int count = task_read(fd, buf + total, n - total)
		if (count < 0):
			io_result_from_syscall(r, count)
			r.transferred = total
			return r.status
		if (count == 0):
			return io_result_set(r, total, IO_EOF, 0)
		total = total + count
	return io_result_set(r, total, IO_OK, 0)


# Read exactly n bytes unless EOF or an error cuts the stream short.
# Returns the number of bytes read (n on success) or a negative errno.
int task_read_exact(int fd, char* buf, int n):
	io_result r
	int status = task_read_exact_result(fd, buf, n, &r)
	if ((status == IO_OK) || (status == IO_EOF)): return r.transferred
	return 0 - r.native_error


# Write all len bytes, suspending whenever the descriptor's buffer is
# full. Advances only by confirmed progress. Returns IO_OK, or the
# failure with r.transferred = bytes the descriptor accepted (no
# rollback): IO_CANCELLED / IO_TIMED_OUT from the task runtime, the
# write's own error, or IO_IO_ERROR (native_error 0) for a zero-byte
# write while bytes remain.
int task_write_all_result(int fd, char* buf, int len, io_result* r):
	int total = 0
	while (total < len):
		int n = write(fd, buf + total, len - total)
		if (n == (0 - IO_ERRNO_EINTR)):
			int stop = task_io_interrupted()
			if (stop < 0):
				io_result_from_syscall(r, stop)
				r.transferred = total
				return r.status
		else if (n == -11): /* EAGAIN */
			int revents = task_await_fd(fd, poll_out)
			if (revents < 0):
				io_result_from_syscall(r, revents)
				r.transferred = total
				return r.status
		else if (n < 0):
			io_result_from_syscall(r, n)
			r.transferred = total
			return r.status
		else if (n == 0):
			return io_result_set(r, total, IO_IO_ERROR, 0)
		else: total = total + n
	return io_result_set(r, total, IO_OK, 0)


# Write all len bytes, suspending whenever the descriptor's buffer is
# full. Returns len, or a negative errno (-EIO for zero progress); use
# task_write_all_result to learn how much was written before a failure.
int task_write_all(int fd, char* buf, int len):
	io_result r
	if (task_write_all_result(fd, buf, len, &r) == IO_OK): return len
	if (r.native_error == 0): return 0 - IO_ERRNO_EIO
	return 0 - r.native_error


# Accept one connection, suspending until a peer arrives. The returned
# descriptor is already non-blocking. listen_fd itself must be
# non-blocking too.
int task_accept(int listen_fd):
	while (1):
		int fd = socket_accept_connection(listen_fd)
		if (fd == -11): /* EAGAIN */
			int revents = task_await_fd(listen_fd, poll_in)
			if (revents < 0):
				return revents
		else:
			if (fd >= 0): socket_set_nonblocking(fd)
			return fd


# task_accept that also reports the peer address through peer.
int task_accept_from(int listen_fd, sockaddr_in* peer):
	while (1):
		int fd = socket_accept_connection_from(listen_fd, peer)
		if (fd == -11): /* EAGAIN */
			int revents = task_await_fd(listen_fd, poll_in)
			if (revents < 0):
				return revents
		else:
			if (fd >= 0): socket_set_nonblocking(fd)
			return fd


# Connect fd (made non-blocking here) to ip:port, suspending during
# connection establishment. Returns 0 or a negative errno.
int task_connect_ipv4(int fd, int ip_address, int port):
	int err = socket_set_nonblocking(fd)
	if (err < 0):
		return err
	err = socket_connect_ipv4(fd, ip_address, port)
	if (err == 0): return 0
	if (err != -115): /* EINPROGRESS */
		return err
	int revents = task_await_fd(fd, poll_out)
	if (revents < 0):
		return revents
	# Retrying the connect reports the outcome without needing
	# getsockopt(SO_ERROR): 0 or -EISCONN on success, the failure
	# errno otherwise.
	err = socket_connect_ipv4(fd, ip_address, port)
	if ((err == 0) || (err == -106)): /* EISCONN */
		return 0
	return err


/* Worker processes: the escape hatch for blocking syscalls and
   CPU-bound work. Separate address spaces need no synchronization. */


# Run path with the given NULL-terminated argv (stdin closed to
# /dev/null, stdout piped, stderr inherited), suspending while the
# child works. Stores the child's malloc'd stdout text through
# stdout_out (0 allowed) and returns the decoded exit status (or 128 +
# signum), or a negative errno.
int task_process_run(char* path, char** argv, char** stdout_out):
	if (cast(int, stdout_out) != 0): *stdout_out = 0
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null
	opts.stdout_mode = process_pipe
	process* p = process_spawn(path, argv, opts)
	free(cast(void*, opts))
	if (cast(int, p) == 0):
		return -12 /* ENOMEM: pipe or fork failed */

	socket_set_nonblocking(p.stdout_fd)
	process_capture buffer
	process_capture_init(&buffer)
	int err = 0
	while (1):
		int count = process_capture_read(&buffer, p.stdout_fd)
		if (count == -11): /* EAGAIN */
			count = task_await_fd(p.stdout_fd, poll_in)
			if (count < 0):
				err = count
				break
		else if (count < 0):
			err = count
			break
		else if (count == 0): break

	# The pipe is closed; the child is exiting or already gone. Reap
	# without blocking the loop.
	int status = process_try_wait(p)
	while (status == process_status_running):
		int slept = task_sleep_ms(2)
		if (slept < 0):
			err = slept
			process_kill(p, sigkill)
			process_wait(p)
			break
		status = process_try_wait(p)

	char* text = process_capture_take(&buffer)
	process_free(p)
	if (err < 0):
		free(text)
		return err
	if (cast(int, stdout_out) != 0): *stdout_out = text
	else: free(text)
	return status
