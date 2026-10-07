# Linux x64 PID-1 guest-side command service. Commands use direct execve,
# stdin /dev/null, independent stdout/stderr pipes and bounded captures.
import lib.vmm.channel
import lib.vmm.workspace


# Commands retain uid 0 for image compatibility but cannot regain Linux
# administrative capabilities, remount the bounded workspace or load modules.
# Keep only CHOWN/DAC_OVERRIDE/DAC_READ_SEARCH/FOWNER/FSETID so guest root
# can work with mapped-xattr files owned by the host uid.
# Bounding-set removal plus no_new_privs also covers setuid/file-cap execs.
int box_guest_drop_capabilities():
	for capability in range(5, 41):
		int status = syscall7(157, 24, capability, 0, 0, 0, 0)
		if (status < 0 && status != -22): return 0
	if (syscall7(157, 38, 1, 0, 0, 0, 0) < 0): return 0
	char[8] header
	char[24] data
	mem_fill[char](&header[0], 0, 8)
	mem_fill[char](&data[0], 0, 24)
	save_int32(&header[0], 0x20080522)
	save_int32(&data[0], 31)
	save_int32(&data[0] + 4, 31)
	return syscall(126, cast(int, &header[0]), cast(int, &data[0]), 0) == 0


process* box_guest_spawn(char** args, char* cwd, int channel_fd):
	int out_read = -1
	int out_write = -1
	int err_read = -1
	int err_write = -1
	if (process_make_pipe(&out_read, &out_write) < 0): return 0
	if (process_make_pipe(&err_read, &err_write) < 0):
		close(out_read)
		close(out_write)
		return 0
	int guest_pid1 = getpid() == 1
	int pid = fork()
	if (pid == 0):
		close(out_read)
		close(err_read)
		close(channel_fd)
		if (syscall(112, 0, 0, 0) < 0): exit(125) # setsid
		process_redirect_null(0, 0)
		process_redirect(out_write, 1)
		process_redirect(err_write, 2)
		if (cwd != 0):
			if (chdir(cwd) < 0): exit(127)
		if (guest_pid1 && box_guest_drop_capabilities() == 0): exit(125)
		execve(args[0], args, env_current())
		exit(127)
	close(out_write)
	close(err_write)
	if (pid < 0):
		close(out_read)
		close(err_read)
		return 0
	process* child = new process()
	child.pid = pid
	child.stdin_fd = -1
	child.stdout_fd = out_read
	child.stderr_fd = err_read
	child.status = 0
	child.reaped = 0
	child.win_handle = 0
	socket_set_nonblocking(out_read)
	socket_set_nonblocking(err_read)
	return child


void box_guest_cleanup(process* child):
	# Guest PID 1 owns the entire session. Kill daemonized descendants too;
	# a test service running outside PID 1 may kill only its command group.
	if (getpid() == 1): kill(-1, sigkill)
	else: kill(0 - child.pid, sigkill)
	process_kill(child, sigkill)
	process_wait(child)
	if (getpid() == 1):
		int status = 0
		while (wait4(-1, &status, 1, 0) > 0): status = 0


process_result* box_guest_exec(char** args, char* cwd, int timeout_ms, int output_limit, int channel_fd):
	process_result* result = box_channel_result(125)
	process* child = box_guest_spawn(args, cwd, channel_fd)
	if (child == 0): return result
	free(result.stdout_text)
	free(result.stderr_text)
	result.stdout_text = cast(char*, malloc(output_limit + 1))
	result.stderr_text = cast(char*, malloc(output_limit + 1))
	int deadline = process_monotonic_ms() + timeout_ms
	int out_open = 1
	int err_open = 1
	int status = process_status_running
	char[24] fds
	char[4096] buffer
	int stop = 0
	while (stop == 0):
		if (deadline - process_monotonic_ms() <= 0):
			result.status = process_status_timeout
			break
		process_pollfd_set(&fds[0], 0, child.stdout_fd, 1)
		process_pollfd_set(&fds[0], 1, child.stderr_fd, 1)
		process_pollfd_set(&fds[0], 2, channel_fd, 0)
		if (out_open == 0): process_pollfd_set(&fds[0], 0, -1, 0)
		if (err_open == 0): process_pollfd_set(&fds[0], 1, -1, 0)
		int ready = poll(cast(int*, &fds[0]), 3, 10)
		if (ready < 0 && ready != -4): break
		if (process_pollfd_revents(&fds[0], 2) & 24): break
		for i in range(2):
			if (process_pollfd_revents(&fds[0], i) != 0):
				int fd = child.stdout_fd
				if (i == 1): fd = child.stderr_fd
				int count = read(fd, &buffer[0], 4096)
				if (count == 0):
					if (i == 0): out_open = 0
					else: err_open = 0
				if (count < 0 && count != -4 && count != -11): stop = 1
				if (count > 0):
					int length = result.stdout_length
					char* destination = result.stdout_text
					if (i == 1):
						length = result.stderr_length
						destination = result.stderr_text
					int retained = count
					if (retained > output_limit - length):
						retained = output_limit - length
						result.status = box_status_output_limit
						stop = 1
					mem_copy[char](destination + length, &buffer[0], retained)
					if (i == 0): result.stdout_length = length + retained
					else: result.stderr_length = length + retained
		if (status == process_status_running): status = process_try_wait(child)
		if (stop == 0 && status != process_status_running):
			# Kill descendants on leader exit so inherited pipes cannot hold
			# a completed command open. Remaining buffered bytes still drain.
			if (getpid() == 1): kill(-1, sigkill)
			else: kill(0 - child.pid, sigkill)
			if (out_open == 0 && err_open == 0):
				result.status = status
				stop = 1
	box_guest_cleanup(child)
	process_free(child)
	result.stdout_text[result.stdout_length] = 0
	result.stderr_text[result.stderr_length] = 0
	return result


# One request at a time, no pipelining. Every malformed frame terminates the
# channel before execution. Idle sessions wait for their owner; once a
# request starts, incomplete frames have a ten-second transport deadline.
int box_guest_serve(int fd, int is_socket):
	if (socket_set_nonblocking(fd) < 0): return 125
	char[24] header
	save_int32(&header[0], box_channel_magic)
	if (box_channel_io(fd, &header[0], 4, 1, is_socket, process_monotonic_ms() + 10000) == 0): return 125
	while (1):
		char[8] readable
		process_pollfd_set(&readable[0], 0, fd, 1)
		int ready = poll(cast(int*, &readable[0]), 1, 600000)
		if (ready == 0 || ready == -4): continue
		if (ready < 0): return 125
		int deadline = process_monotonic_ms() + 10000
		if (box_channel_io(fd, &header[0], 24, 0, is_socket, deadline) == 0): return 125
		int length = load_int32(&header[0] + 4)
		if (length < 0 || length > box_channel_max_request - 24): return 125
		char* payload = cast(char*, malloc(length + 1))
		int ok = box_channel_io(fd, payload, length, 0, is_socket, deadline)
		char* cwd = 0
		char** args = 0
		if (ok): args = box_channel_decode(&header[0], payload, &cwd)
		free(payload)
		if (args == 0): return 125
		process_result* result = box_guest_exec(args, cwd, load_int32(&header[0] + 12), load_int32(&header[0] + 16), fd)
		box_channel_args_free(args)
		if (cwd != 0): free(cwd)
		save_int32(&header[0], box_channel_magic)
		save_int32(&header[0] + 4, result.status)
		save_int32(&header[0] + 8, result.stdout_length)
		save_int32(&header[0] + 12, result.stderr_length)
		deadline = process_monotonic_ms() + 2000
		ok = box_channel_io(fd, &header[0], 16, 1, is_socket, deadline)
		if (ok): ok = box_channel_io(fd, result.stdout_text, result.stdout_length, 1, is_socket, deadline)
		if (ok): ok = box_channel_io(fd, result.stderr_text, result.stderr_length, 1, is_socket, deadline)
		process_result_free(result)
		if (ok == 0): return 125
	return 125


# Requested shares fail closed: readiness is never sent after a failed mount.
# A positive limit imports boot-only files into bounded tmpfs. There is no
# live host filesystem device, so snapshots capture every workspace byte.
int box_guest_workspace(int workspace_mb):
	if (workspace_mb < 0 || workspace_mb > 32768): return 0
	mkdir(c"/work", 493)
	if (workspace_mb == 0):
		return syscall7(165, cast(int, c"work"), cast(int, c"/work"), cast(int, c"9p"), 6, cast(int, c"trans=virtio,version=9p2000.L"), 0) == 0
	string_builder* options = string_new()
	string_append(options, c"size=")
	string_append_int(options, workspace_mb)
	string_append(options, c"m,mode=0700")
	int status = syscall7(165, cast(int, c"tmpfs"), cast(int, c"/work"), cast(int, c"tmpfs"), 6, cast(int, options.data), 0)
	string_free(options)
	if (status < 0): return 0
	int input = open(c"/wvm-import", 65536 | 131072 | 524288, 0)
	int output = open(c"/work", 65536 | 131072 | 524288, 0)
	vm_workspace workspace
	mem_fill[char](cast(char*, &workspace), 0, sizeof(vm_workspace))
	workspace.max_bytes = workspace_mb * 1048576
	workspace.max_entries = 100000
	workspace.deadline = process_monotonic_ms() + 30000
	int ok = input >= 0 && output >= 0
	if (ok): ok = workspace_copy_dir(&workspace, input, output, 0)
	if (input >= 0): close(input)
	if (output >= 0): close(output)
	if (ok): ok = dir_remove_all(c"/wvm-import") == 0
	return ok
