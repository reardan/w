/*
Process management: spawn/exec, pipes, wait/status, timeouts, env/cwd.

process_spawn forks and execs a program with per-stream stdio control
(inherit, pipe or /dev/null), an optional working directory and an
optional environment vector (see lib/env.w). process_run is the
convenience wrapper a test runner wants: pipe everything, feed stdin,
drain stdout and stderr concurrently with poll, and enforce a timeout.

Status convention: process_wait and friends return the decoded status —
the exit code 0..255 for a normal exit, 128 + signum when a signal killed
the child (the shell convention, so SIGKILL reads as 137) — or a negative
kernel errno when the wait itself failed. The raw wait4 status stays in
process.status. Distinct sentinels report non-statuses:
process_status_running() (-1000) and process_status_timeout() (-1001);
both are outside the errno range (-4095..-1), so the three failure kinds
cannot collide.

Timeouts poll with WNOHANG + nanosleep against a CLOCK_MONOTONIC deadline
rather than signal-based timers: x86-64 signal handlers would need an
SA_RESTORER trampoline the runtime does not provide (see the
rt_sigaction note in lib/__arch__/x64/syscalls.w).
*/
import lib.lib
import lib.env


/* stdio modes for spawn_options */

int process_inherit():
	return 0

int process_pipe():
	return 1

int process_null():
	return 2


/* Sentinels returned by the wait family (outside the errno range). */

int process_status_running():
	return -1000

int process_status_timeout():
	return -1001


/* Common signal numbers for process_kill. */

int sigint():
	return 2

int sigkill():
	return 9

int sigterm():
	return 15


/* NULL-terminated char* vector builder (argv/envp for execve). */

# A vector with room for capacity entries, every slot NULL.
char** strv_new(int capacity):
	char* vector = malloc((capacity + 1) * __word_size__)
	int i = 0
	while (i <= capacity):
		save_word(vector + i * __word_size__, 0)
		i = i + 1
	return cast(char**, vector)


void strv_set(char** v, int i, char* s):
	save_word(cast(char*, v) + i * __word_size__, cast(int, s))


char* strv_get(char** v, int i):
	return env_entry_at(v, i)


struct spawn_options:
	char** env       # 0 = inherit the current environment
	char* cwd        # 0 = inherit the current directory
	int stdin_mode   # process_inherit / process_pipe / process_null
	int stdout_mode
	int stderr_mode


spawn_options* spawn_options_new():
	spawn_options* opts = new spawn_options()
	opts.env = 0
	opts.cwd = 0
	opts.stdin_mode = process_inherit()
	opts.stdout_mode = process_inherit()
	opts.stderr_mode = process_inherit()
	return opts


struct process:
	int pid
	int stdin_fd     # parent's write end, -1 when not piped
	int stdout_fd    # parent's read end, -1 when not piped
	int stderr_fd    # parent's read end, -1 when not piped
	int status       # raw wait4 status, valid once reaped
	int reaped


# The kernel writes two 32-bit fds regardless of architecture.
int process_make_pipe(int* read_end, int* write_end):
	char* kernel_fds = malloc(8)
	int err = pipe(cast(int*, kernel_fds))
	if (err < 0):
		free(kernel_fds)
		return err
	*read_end = load_int32(kernel_fds)
	*write_end = load_int32(kernel_fds + 4)
	free(kernel_fds)
	return 0


# Child-side helper: point target_fd (0, 1 or 2) at fd and drop the
# original descriptor.
void process_redirect(int fd, int target_fd):
	dup2(fd, target_fd)
	if (fd > 2):
		close(fd)


# Child-side helper: open /dev/null onto target_fd. Mode 0 reads (stdin),
# mode 1 writes (stdout/stderr).
void process_redirect_null(int target_fd, int mode):
	int fd = open(c"/dev/null", mode, 0)
	if (fd >= 0):
		process_redirect(fd, target_fd)


void process_close_fd_if_open(int fd):
	if (fd >= 0):
		close(fd)


# Fork and exec path with the given NULL-terminated argv. opts may be 0
# for all defaults. Returns 0 when pipe or fork creation failed; exec or
# chdir failure inside the child surfaces as exit status 127 (the shell
# convention for "command not found").
process* process_spawn(char* path, char** argv, spawn_options* opts):
	spawn_options* defaults = 0
	if (opts == 0):
		defaults = spawn_options_new()
		opts = defaults

	int stdin_read = -1
	int stdin_write = -1
	int stdout_read = -1
	int stdout_write = -1
	int stderr_read = -1
	int stderr_write = -1
	int err = 0
	if (opts.stdin_mode == process_pipe()):
		err = process_make_pipe(&stdin_read, &stdin_write)
	if ((err == 0) & (opts.stdout_mode == process_pipe())):
		err = process_make_pipe(&stdout_read, &stdout_write)
	if ((err == 0) & (opts.stderr_mode == process_pipe())):
		err = process_make_pipe(&stderr_read, &stderr_write)

	int pid = 0
	if (err == 0):
		pid = fork()
		if (pid < 0):
			err = pid

	if (err != 0):
		process_close_fd_if_open(stdin_read)
		process_close_fd_if_open(stdin_write)
		process_close_fd_if_open(stdout_read)
		process_close_fd_if_open(stdout_write)
		process_close_fd_if_open(stderr_read)
		process_close_fd_if_open(stderr_write)
		if (defaults != 0):
			free(defaults)
		return 0

	if (pid == 0):
		# Child. Drop the parent's pipe ends first so EOF propagates
		# (a retained stdin write end would keep the child's stdin
		# open forever).
		process_close_fd_if_open(stdin_write)
		process_close_fd_if_open(stdout_read)
		process_close_fd_if_open(stderr_read)
		if (opts.stdin_mode == process_pipe()):
			process_redirect(stdin_read, 0)
		if (opts.stdin_mode == process_null()):
			process_redirect_null(0, 0)
		if (opts.stdout_mode == process_pipe()):
			process_redirect(stdout_write, 1)
		if (opts.stdout_mode == process_null()):
			process_redirect_null(1, 1)
		if (opts.stderr_mode == process_pipe()):
			process_redirect(stderr_write, 2)
		if (opts.stderr_mode == process_null()):
			process_redirect_null(2, 1)
		if (opts.cwd != 0):
			if (chdir(opts.cwd) < 0):
				exit(127)
		char** envp = opts.env
		if (envp == 0):
			envp = env_current()
		execve(path, argv, envp)
		exit(127)

	# Parent: drop the child's pipe ends.
	process_close_fd_if_open(stdin_read)
	process_close_fd_if_open(stdout_write)
	process_close_fd_if_open(stderr_write)
	if (defaults != 0):
		free(defaults)

	process* p = new process()
	p.pid = pid
	p.stdin_fd = stdin_write
	p.stdout_fd = stdout_read
	p.stderr_fd = stderr_read
	p.status = 0
	p.reaped = 0
	return p


# Exit code for a normal exit, 128 + signum for a signal death.
int process_decode_status(int status):
	int sig = status & 127
	if (sig == 0):
		return (status >> 8) & 255
	return 128 + sig


# Close the parent's write end of the child's stdin, delivering EOF.
void process_close_stdin(process* p):
	if (p.stdin_fd >= 0):
		close(p.stdin_fd)
		p.stdin_fd = -1


# Blocking reap. Returns the decoded status, or a negative errno when
# wait4 failed.
int process_wait(process* p):
	if (p.reaped):
		return process_decode_status(p.status)
	# Pre-zero: the kernel writes a 32-bit status, W ints are word-sized.
	int status = 0
	int err = wait4(p.pid, &status, 0, 0)
	if (err < 0):
		return err
	p.status = status
	p.reaped = 1
	return process_decode_status(status)


# Non-blocking reap (WNOHANG). Returns process_status_running() while the
# child lives, otherwise like process_wait.
int process_try_wait(process* p):
	if (p.reaped):
		return process_decode_status(p.status)
	int status = 0
	int err = wait4(p.pid, &status, 1, 0)
	if (err < 0):
		return err
	if (err == 0):
		return process_status_running()
	p.status = status
	p.reaped = 1
	return process_decode_status(status)


int process_kill(process* p, int sig):
	if (p.reaped):
		return 0
	return kill(p.pid, sig)


# Milliseconds on the monotonic clock. Only differences are meaningful.
int process_monotonic_ms():
	int* ts = malloc(2 * __word_size__)
	clock_gettime(1, ts)
	int seconds = 0
	int nanos = 0
	if (__word_size__ == 8):
		seconds = load_int64(cast(char*, ts))
		nanos = load_int64(cast(char*, ts) + 8)
	else:
		seconds = load_int32(cast(char*, ts))
		nanos = load_int32(cast(char*, ts) + 4)
	free(ts)
	return seconds * 1000 + nanos / 1000000


void process_sleep_ms(int ms):
	char* ts = malloc(2 * __word_size__)
	save_word(ts, ms / 1000)
	save_word(ts + __word_size__, (ms % 1000) * 1000000)
	nanosleep(cast(int*, ts), 0)
	free(ts)


# Wait up to timeout_ms. On expiry returns process_status_timeout() and
# leaves the child running so the caller decides between process_kill and
# more waiting. timeout_ms <= 0 degrades to a blocking process_wait.
int process_wait_timeout(process* p, int timeout_ms):
	if (timeout_ms <= 0):
		return process_wait(p)
	int deadline = process_monotonic_ms() + timeout_ms
	int decoded = process_try_wait(p)
	while (decoded == process_status_running()):
		if ((deadline - process_monotonic_ms()) <= 0):
			return process_status_timeout()
		process_sleep_ms(2)
		decoded = process_try_wait(p)
	return decoded


# Like process_wait_timeout, but on expiry SIGKILLs and reaps the child.
# Still returns process_status_timeout() in that case; the post-kill raw
# status is in p.status.
int process_wait_or_kill(process* p, int timeout_ms):
	int decoded = process_wait_timeout(p, timeout_ms)
	if (decoded != process_status_timeout()):
		return decoded
	process_kill(p, sigkill())
	process_wait(p)
	return process_status_timeout()


void process_free(process* p):
	process_close_stdin(p)
	process_close_fd_if_open(p.stdout_fd)
	process_close_fd_if_open(p.stderr_fd)
	free(p)


/* poll-based capture (process_run) */

# pollfd is int32 fd, int16 events, int16 revents: 8 bytes on both
# architectures. POLLIN 1, POLLOUT 4, POLLERR 8, POLLHUP 16.
void process_pollfd_set(char* fds, int i, int fd, int events):
	save_int32(fds + i * 8, fd)
	save_int16(fds + i * 8 + 4, events)
	save_int16(fds + i * 8 + 6, 0)


int process_pollfd_revents(char* fds, int i):
	return load_int16(fds + i * 8 + 6)


struct process_capture:
	char* data
	int length
	int capacity


void process_capture_init(process_capture* buffer):
	buffer.capacity = 4096
	buffer.length = 0
	buffer.data = malloc(buffer.capacity)


# Read up to 4096 bytes from fd into the buffer, growing as needed.
# Returns the read() result.
int process_capture_read(process_capture* buffer, int fd):
	if ((buffer.length + 4096) > buffer.capacity):
		int new_capacity = buffer.capacity * 2
		buffer.data = realloc(buffer.data, buffer.length, new_capacity)
		buffer.capacity = new_capacity
	int count = read(fd, buffer.data + buffer.length, 4096)
	if (count > 0):
		buffer.length = buffer.length + count
	return count


# NUL-terminate and hand the accumulated bytes to the caller.
char* process_capture_take(process_capture* buffer):
	if ((buffer.length + 1) > buffer.capacity):
		buffer.data = realloc(buffer.data, buffer.length, buffer.length + 1)
	buffer.data[buffer.length] = 0
	return buffer.data


struct process_result:
	int status           # decoded status, or process_status_timeout()
	char* stdout_text    # malloc'd, NUL-terminated
	int stdout_length
	char* stderr_text    # malloc'd, NUL-terminated
	int stderr_length


void process_result_free(process_result* result):
	free(result.stdout_text)
	free(result.stderr_text)
	free(result)


# Run path to completion with stdio piped: write stdin_text (0 for none)
# to the child, drain stdout and stderr concurrently with poll (so a child
# filling one stream cannot deadlock against the other), and enforce
# timeout_ms (<= 0 for no timeout; on expiry the child is SIGKILLed and
# the partial output is returned with status process_status_timeout()).
# opts may be 0; only its env and cwd fields apply, the stdio modes are
# forced to pipes. Returns 0 when the spawn itself failed.
process_result* process_run(char* path, char** argv, spawn_options* opts, char* stdin_text, int timeout_ms):
	spawn_options* run_opts = spawn_options_new()
	if (opts != 0):
		run_opts.env = opts.env
		run_opts.cwd = opts.cwd
	run_opts.stdin_mode = process_pipe()
	run_opts.stdout_mode = process_pipe()
	run_opts.stderr_mode = process_pipe()
	process* p = process_spawn(path, argv, run_opts)
	free(run_opts)
	if (p == 0):
		return 0

	int stdin_length = 0
	int stdin_offset = 0
	if (stdin_text != 0):
		stdin_length = strlen(stdin_text)
	else:
		process_close_stdin(p)

	process_capture out_buffer
	process_capture err_buffer
	process_capture_init(&out_buffer)
	process_capture_init(&err_buffer)

	int deadline = 0
	if (timeout_ms > 0):
		deadline = process_monotonic_ms() + timeout_ms

	char* fds = malloc(3 * 8)
	int timed_out = 0
	int stdout_open = 1
	int stderr_open = 1
	while (stdout_open | stderr_open | (p.stdin_fd >= 0)):
		int nfds = 0
		int stdin_slot = -1
		int stdout_slot = -1
		int stderr_slot = -1
		if (p.stdin_fd >= 0):
			stdin_slot = nfds
			process_pollfd_set(fds, nfds, p.stdin_fd, 4)
			nfds = nfds + 1
		if (stdout_open):
			stdout_slot = nfds
			process_pollfd_set(fds, nfds, p.stdout_fd, 1)
			nfds = nfds + 1
		if (stderr_open):
			stderr_slot = nfds
			process_pollfd_set(fds, nfds, p.stderr_fd, 1)
			nfds = nfds + 1

		int wait_ms = -1
		if (timeout_ms > 0):
			wait_ms = deadline - process_monotonic_ms()
			if (wait_ms <= 0):
				timed_out = 1
		if (timed_out == 0):
			int ready = poll(cast(int*, fds), nfds, wait_ms)
			if (ready < 0):
				timed_out = 1
			if (ready == 0):
				timed_out = 1
		if (timed_out):
			process_kill(p, sigkill())
			process_close_stdin(p)
			stdout_open = 0
			stderr_open = 0
		else:
			if (stdin_slot >= 0):
				if (process_pollfd_revents(fds, stdin_slot) != 0):
					# POLLOUT guarantees PIPE_BUF (4096) writable
					# bytes, so a bounded write cannot block.
					int chunk = stdin_length - stdin_offset
					if (chunk > 4096):
						chunk = 4096
					int written = write(p.stdin_fd, stdin_text + stdin_offset, chunk)
					if (written > 0):
						stdin_offset = stdin_offset + written
					if ((written < 0) | (stdin_offset >= stdin_length)):
						process_close_stdin(p)
			if (stdout_slot >= 0):
				if (process_pollfd_revents(fds, stdout_slot) != 0):
					if (process_capture_read(&out_buffer, p.stdout_fd) <= 0):
						stdout_open = 0
			if (stderr_slot >= 0):
				if (process_pollfd_revents(fds, stderr_slot) != 0):
					if (process_capture_read(&err_buffer, p.stderr_fd) <= 0):
						stderr_open = 0
	free(fds)

	int decoded = 0
	if (timed_out):
		process_wait(p)
		decoded = process_status_timeout()
	else:
		# Streams are drained but the child may still be running (it
		# can close its stdio and keep working); the deadline applies
		# to the reap too.
		int remaining_ms = 0
		if (timeout_ms > 0):
			remaining_ms = deadline - process_monotonic_ms()
			if (remaining_ms <= 0):
				remaining_ms = 1
		decoded = process_wait_or_kill(p, remaining_ms)

	process_result* result = new process_result()
	result.status = decoded
	result.stdout_length = out_buffer.length
	result.stdout_text = process_capture_take(&out_buffer)
	result.stderr_length = err_buffer.length
	result.stderr_text = process_capture_take(&err_buffer)
	process_free(p)
	return result
