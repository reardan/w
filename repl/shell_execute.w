# Execute a parsed shell plan with a frontend-supplied simple-command
# callback. Pipelines fork all stages before waiting: output is streamed
# through kernel pipes, never buffered in memory or a temporary file.
import repl.shell_plan
import lib.process


type shell_execute_callback = fn(char*, int) -> int


int shell_execute_redirects(shell_command* command):
	for i in range(command.redirects.length):
		shell_redirect* r = command.redirects[i]
		if (r.mode == 3):
			if (dup2(r.source_fd, r.fd) < 0):
				println2(c"shell: cannot duplicate descriptor")
				return 1
		else:
			int flags = 0
			if (r.mode == 1): flags = 577 # O_WRONLY | O_CREAT | O_TRUNC (Linux)
			if (r.mode == 2): flags = 1089 # O_WRONLY | O_CREAT | O_APPEND (Linux)
			int fd = open(r.path, flags, 438)
			if (fd < 0):
				print2(c"shell: cannot open ")
				println2(r.path)
				return 1
			if (fd != r.fd):
				int ok = dup2(fd, r.fd)
				close(fd)
				if (ok < 0): return 1
	return 0


int shell_execute_command(shell_command* command, shell_execute_callback* run, int isolated):
	int status = shell_execute_redirects(command)
	if (status != 0): return status
	if (command.text[0] == 0): return 0
	return run(command.text, isolated)


# Single commands run in the parent, so cd/export and session functions
# retain their effects. Save all stdio descriptors before applying any
# redirection, then restore them even on failure (including closed fds).
int shell_execute_single(shell_command* command, shell_execute_callback* run):
	if (command.redirects.length == 0): return shell_execute_command(command, run, 0)
	int[3] saved
	for i in range(3): saved[i] = -1
	int failed = 0
	for i in range(3):
		saved[i] = sys_fcntl(i, 0, 10) # F_DUPFD, avoid the redirected 0/1/2
		if ((saved[i] < 0) && (saved[i] != -9)): failed = 1
	int status = 1
	if (failed == 0): status = shell_execute_command(command, run, 0)
	for i in range(3):
		if (saved[i] >= 0):
			dup2(saved[i], i)
			close(saved[i])
		elif (saved[i] == -9): close(i)
	return status


int shell_execute_wait(int pid):
	int status = 0
	int result = wait4(pid, &status, 0, 0)
	while (result == -4): result = wait4(pid, &status, 0, 0)
	if (result < 0): return 125
	return process_decode_status(status)


int shell_execute_pipeline(shell_pipeline* pipeline, shell_execute_callback* run):
	if (pipeline.commands.length == 1): return shell_execute_single(pipeline.commands[0], run)
	list[int] children = new list[int]
	int previous = -1
	int failed = 0
	for i in range(pipeline.commands.length):
		int next_read = -1
		int next_write = -1
		if (i + 1 < pipeline.commands.length):
			if (process_make_pipe(&next_read, &next_write) < 0):
				failed = 1
				break
		int pid = fork()
		if (pid == 0):
			if (previous >= 0): process_redirect(previous, 0)
			if (next_write >= 0): process_redirect(next_write, 1)
			if (next_read >= 0): close(next_read)
			int status = shell_execute_command(pipeline.commands[i], run, 1)
			exit(status & 255)
		if (previous >= 0): close(previous)
		if (next_write >= 0): close(next_write)
		previous = next_read
		if (pid < 0):
			failed = 1
			break
		children.push(pid)
	if (previous >= 0): close(previous)
	if (failed):
		println2(c"shell: cannot start pipeline")
		for i in range(children.length): kill(children[i], 9)
	int status = 125
	for i in range(children.length):
		int child_status = shell_execute_wait(children[i])
		if (failed == 0): status = child_status
	children.free()
	return status


# && and || have equal precedence and associate left to right. Skipped
# pipelines leave the previous status intact, as in a POSIX shell.
int shell_execute_plan(shell_plan* plan, shell_execute_callback* run):
	int status = 0
	for i in range(plan.pipelines.length):
		shell_pipeline* pipeline = plan.pipelines[i]
		int execute = pipeline.condition == 0
		if ((pipeline.condition == 1) && (status == 0)): execute = 1
		if ((pipeline.condition == 2) && (status != 0)): execute = 1
		if (execute): status = shell_execute_pipeline(pipeline, run)
	return status
