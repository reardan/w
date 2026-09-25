/*
Readiness waits that follow the caller's execution context
(docs/projects/async.md, "Blocking libraries on tasks").

Library code that reads or writes sockets (libs/standard/net/tls.w,
libs/standard/web/connection.w, ...) calls io_wait when a non-blocking
descriptor reports EAGAIN. Inside a task (lib/task.w) that suspends
only the calling task; everywhere else it returns -EAGAIN at once, so
code that runs outside the task runtime keeps the behavior it always
had (EAGAIN from a blocking socket's SO_RCVTIMEO is still a timeout).

This module deliberately knows nothing about tasks: lib/task.w installs
io_wait_hook the first time a scheduler is created. That keeps the
dependency one-way, so the protocol libraries can call io_wait without
importing the scheduler, generators or the event loop.
*/


# fd, poll events, timeout_ms (-1 = none) -> revents or a negative errno
type io_wait_fn = fn(int, int, int) -> int


io_wait_fn* io_wait_hook


# Wait until fd has one of events (a poll mask). Returns the revents
# mask, a negative errno (-ETIMEDOUT, -ECANCELED from the task
# runtime), or -EAGAIN when the caller is not running inside a task.
int io_wait(int fd, int events, int timeout_ms):
	if (cast(int, io_wait_hook) == 0):
		return -11 /* EAGAIN */
	return io_wait_hook(fd, events, timeout_ms)


# 1 when io_wait would suspend a task rather than fail with -EAGAIN.
# Libraries use this to decide whether to put a descriptor into
# non-blocking mode.
type io_wait_active_fn = fn() -> int


io_wait_active_fn* io_wait_active_hook


int io_wait_available():
	if (cast(int, io_wait_active_hook) == 0):
		return 0
	return io_wait_active_hook()
