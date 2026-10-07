# wbuild: x64
import lib.testing
import lib.process


char** argv_1(char* a0):
	char** argv = strv_new(1)
	strv_set(argv, 0, a0)
	return argv


char** argv_sh(char* command):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/sh")
	strv_set(argv, 1, c"-c")
	strv_set(argv, 2, c"")
	strv_set(argv, 2, command)
	return argv


void test_spawn_echo_captures_stdout():
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/echo")
	strv_set(argv, 1, c"hello from child")
	process_result* result = process_run(c"/bin/echo", argv, 0, 0, 5000)
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_strings_equal(c"hello from child\x0a", result.stdout_text)
	assert_equal(0, result.stderr_length)
	process_result_free(result)


void test_exit_status_is_reported():
	process_result* result = process_run(c"/bin/sh", argv_sh(c"exit 3"), 0, 0, 5000)
	assert1(result != 0)
	assert_equal(3, result.status)
	process_result_free(result)


void test_stdin_pipe_roundtrip_through_cat():
	process_result* result = process_run(c"/bin/cat", argv_1(c"/bin/cat"), 0, c"pipe roundtrip\x0a", 5000)
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_strings_equal(c"pipe roundtrip\x0a", result.stdout_text)
	process_result_free(result)


void test_large_stdin_does_not_deadlock():
	# 256KB through cat overflows the 64KB pipe buffer in both directions,
	# so this only completes when stdin writes interleave with draining.
	int size = 262144
	char* text = malloc(size + 1)
	for i in range(size): text[i] = 'a' + (i % 26)
	text[size] = 0
	process_result* result = process_run(c"/bin/cat", argv_1(c"/bin/cat"), 0, text, 10000)
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_equal(size, result.stdout_length)
	assert_strings_equal(text, result.stdout_text)
	free(text)
	process_result_free(result)


void test_stdout_and_stderr_are_split():
	process_result* result = process_run(c"/bin/sh", argv_sh(c"echo to-out; echo to-err 1>&2"), 0, 0, 5000)
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_strings_equal(c"to-out\x0a", result.stdout_text)
	assert_strings_equal(c"to-err\x0a", result.stderr_text)
	process_result_free(result)


void test_env_control():
	spawn_options* opts = spawn_options_new()
	opts.env = env_copy_with(env_current(), c"W_PROCESS_TEST_VAR", c"from-parent")
	process_result* result = process_run(c"/bin/sh", argv_sh(c"echo $W_PROCESS_TEST_VAR"), opts, 0, 5000)
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_strings_equal(c"from-parent\x0a", result.stdout_text)
	process_result_free(result)
	free(opts)


void test_cwd_control():
	spawn_options* opts = spawn_options_new()
	opts.cwd = c"/tmp"
	process_result* result = process_run(c"/bin/sh", argv_sh(c"pwd"), opts, 0, 5000)
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_strings_equal(c"/tmp\x0a", result.stdout_text)
	process_result_free(result)
	free(opts)


void test_exec_failure_reports_127():
	char** argv = argv_1(c"/no/such/program")
	process_result* result = process_run(c"/no/such/program", argv, 0, 0, 5000)
	assert1(result != 0)
	assert_equal(127, result.status)
	process_result_free(result)


void test_timeout_kills_the_child():
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/sleep")
	strv_set(argv, 1, c"5")
	int start = process_monotonic_ms()
	process_result* result = process_run(c"/bin/sleep", argv, 0, 0, 200)
	int elapsed = process_monotonic_ms() - start
	assert1(result != 0)
	assert_equal(process_status_timeout, result.status)
	# Nowhere near the 5s the child asked for.
	assert1(elapsed < 3000)
	process_result_free(result)


void test_wait_timeout_leaves_child_running():
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/sleep")
	strv_set(argv, 1, c"5")
	process* p = process_spawn(c"/bin/sleep", argv, 0)
	assert1(p != 0)
	assert_equal(process_status_timeout, process_wait_timeout(p, 100))
	# Still alive: try_wait sees it running, then the kill path reaps it.
	assert_equal(process_status_running, process_try_wait(p))
	assert_equal(0, process_kill(p, sigkill))
	assert_equal(128 + sigkill, process_wait(p))
	process_free(p)


void test_signal_death_decodes_as_128_plus_signum():
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/sleep")
	strv_set(argv, 1, c"5")
	process* p = process_spawn(c"/bin/sleep", argv, 0)
	assert1(p != 0)
	assert_equal(0, process_kill(p, sigterm))
	assert_equal(128 + sigterm, process_wait(p))
	# Reaped results are cached.
	assert_equal(128 + sigterm, process_wait(p))
	assert_equal(128 + sigterm, process_try_wait(p))
	process_free(p)


void test_spawn_with_piped_streams_and_manual_wait():
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe
	opts.stdout_mode = process_pipe
	opts.stderr_mode = process_null
	process* p = process_spawn(c"/bin/cat", argv_1(c"/bin/cat"), opts)
	assert1(p != 0)
	assert1(p.stdin_fd >= 0)
	assert1(p.stdout_fd >= 0)
	assert_equal(-1, p.stderr_fd)
	char* message = c"manual pipe\x0a"
	assert_equal(strlen(message), write(p.stdin_fd, message, strlen(message)))
	process_close_stdin(p)
	char* buffer = malloc(64)
	int count = read(p.stdout_fd, buffer, 63)
	assert_equal(strlen(message), count)
	buffer[count] = 0
	assert_strings_equal(message, buffer)
	assert_equal(0, process_wait(p))
	process_free(p)
	free(opts)


void test_getpid_wrapper():
	assert1(getpid() > 1)


void test_wait_any_reaps_first_finished_child():
	char** slow_argv = strv_new(2)
	strv_set(slow_argv, 0, c"/bin/sleep")
	strv_set(slow_argv, 1, c"5")
	process* slow = process_spawn(c"/bin/sleep", slow_argv, 0)
	assert1(slow != 0)
	process* fast = process_spawn(c"/bin/true", argv_1(c"/bin/true"), 0)
	assert1(fast != 0)
	list[process*] kids = new list[process*]
	kids.push(slow)
	kids.push(fast)
	int idx = process_wait_any(kids, 1)
	assert_equal(1, idx)
	assert_equal(1, fast.reaped)
	assert_equal(0, process_wait(fast))
	assert_equal(0, process_kill(slow, sigkill))
	assert_equal(128 + sigkill, process_wait(slow))
	process_free(slow)
	process_free(fast)
	free(cast(void*, kids))


void test_wait_any_nonblocking_while_running():
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/sleep")
	strv_set(argv, 1, c"5")
	process* p = process_spawn(c"/bin/sleep", argv, 0)
	assert1(p != 0)
	list[process*] kids = new list[process*]
	kids.push(p)
	assert_equal(process_status_running, process_wait_any(kids, 0))
	assert_equal(0, process_kill(p, sigkill))
	assert_equal(0, process_wait_any(kids, 1))
	assert_equal(128 + sigkill, process_wait(p))
	process_free(p)
	free(cast(void*, kids))


/* fd hygiene, reaping and process groups (issue #534) */

# 1 when needle occurs in haystack.
int text_contains(char* haystack, char* needle):
	int i = 0
	while (haystack[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (haystack[i + j] == needle[j])): j = j + 1
		if (needle[j] == 0): return 1
		i = i + 1
	return 0


# /proc/<pid>/stat into a fresh string, or 0 once the pid is gone.
char* proc_stat_text(int pid):
	char* path = strjoin(c"/proc/", strjoin(itoa(pid), c"/stat"))
	int fd = open(path, 0, 0)
	free(path)
	if (fd < 0): return 0
	char* buffer = malloc(1024)
	int count = read(fd, buffer, 1023)
	close(fd)
	# A zombie reaped between open and read fails the read with ESRCH:
	# that is "gone" too, not an empty stat line to parse.
	if (count <= 0):
		free(buffer)
		return 0
	buffer[count] = 0
	return buffer


# The fields after "(comm) ": state is field 0, ppid 1, pgrp 2.
char* proc_stat_after_comm(char* stat):
	int i = strlen(stat) - 1
	while ((i > 0) && (stat[i] != ')')): i = i - 1
	return stat + i + 2


int proc_stat_pgrp(int pid):
	char* stat = proc_stat_text(pid)
	if (stat == 0): return -1
	char* rest = proc_stat_after_comm(stat)
	int field = 0
	while (field < 2):
		while (rest[0] != ' '): rest = rest + 1
		rest = rest + 1
		field = field + 1
	int pgrp = atoi(rest)
	free(stat)
	return pgrp


# 1 while pid is a live (non-zombie) process. A SIGKILLed grandchild is
# reparented and may sit as a zombie until its new parent reaps it,
# which is dead enough for this test.
int proc_alive(int pid):
	char* stat = proc_stat_text(pid)
	if (stat == 0): return 0
	char state = proc_stat_after_comm(stat)[0]
	free(stat)
	return (state != 'Z') && (state != 'X')


char* fd_probe_path():
	return strjoin(c"/tmp/w_process_fd_probe_", itoa(getpid()))


# The child lists its own descriptors: a file the parent opened without
# close-on-exec must not show up there unless keep_fds asks for it.
process_result* list_child_fds(int keep_fds):
	spawn_options* opts = spawn_options_new()
	opts.keep_fds = keep_fds
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/ls")
	strv_set(argv, 1, c"-l")
	strv_set(argv, 2, c"/proc/self/fd/")
	process_result* result = process_run(c"/bin/ls", argv, opts, 0, 5000)
	free(opts)
	return result


void test_child_does_not_inherit_parent_fds():
	char* path = fd_probe_path()
	int fd = open(path, 64 | 2, 420)  # O_CREAT | O_RDWR, no O_CLOEXEC
	assert1(fd > 2)
	assert_equal(0, sys_fcntl(fd, f_getfd, 0) & fd_cloexec)
	process_result* result = list_child_fds(0)
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_equal(0, text_contains(result.stdout_text, path))
	process_result_free(result)
	# Control: with keep_fds the same listing does see it, so the
	# check above can tell a leak from a broken probe.
	result = list_child_fds(1)
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_equal(1, text_contains(result.stdout_text, path))
	process_result_free(result)
	close(fd)
	unlink(path)
	free(path)


void test_make_pipe_ends_are_close_on_exec():
	int read_end = -1
	int write_end = -1
	assert_equal(0, process_make_pipe(&read_end, &write_end))
	assert_equal(fd_cloexec, sys_fcntl(read_end, f_getfd, 0) & fd_cloexec)
	assert_equal(fd_cloexec, sys_fcntl(write_end, f_getfd, 0) & fd_cloexec)
	close(read_end)
	close(write_end)


void test_free_reaps_an_exited_child():
	process* p = process_spawn(c"/bin/true", argv_1(c"/bin/true"), 0)
	assert1(p != 0)
	int pid = p.pid
	# Let it exit without being waited for: a zombie until reaped.
	int deadline = process_monotonic_ms() + 5000
	char state = 'R'
	while ((state != 'Z') && (process_monotonic_ms() < deadline)):
		char* stat = proc_stat_text(pid)
		assert1(stat != 0)
		state = proc_stat_after_comm(stat)[0]
		free(stat)
		if (state != 'Z'): process_sleep_ms(5)
	assert_equal('Z', state)
	process_free(p)
	# Reaped: the pid is no longer our child at all (ECHILD).
	int status = 0
	assert_equal(-10, wait4(pid, &status, 1, 0))


void test_free_kills_and_reaps_a_running_child():
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/sleep")
	strv_set(argv, 1, c"30")
	process* p = process_spawn(c"/bin/sleep", argv, 0)
	assert1(p != 0)
	int pid = p.pid
	int start = process_monotonic_ms()
	process_free(p)
	assert1((process_monotonic_ms() - start) < 3000)
	int status = 0
	assert_equal(-10, wait4(pid, &status, 1, 0))


void test_new_group_child_leads_its_own_group():
	spawn_options* opts = spawn_options_new()
	opts.new_group = 1
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/sleep")
	strv_set(argv, 1, c"30")
	process* p = process_spawn(c"/bin/sleep", argv, opts)
	free(opts)
	assert1(p != 0)
	# The parent-side setpgid means this holds as soon as spawn returns.
	assert_equal(p.pid, proc_stat_pgrp(p.pid))
	process_free(p)
	# The default stays in the caller's group (terminal Ctrl-C reaches it).
	p = process_spawn(c"/bin/sleep", argv, 0)
	assert1(p != 0)
	assert_equal(proc_stat_pgrp(getpid()), proc_stat_pgrp(p.pid))
	process_free(p)


void test_timeout_kills_the_whole_group():
	spawn_options* opts = spawn_options_new()
	opts.new_group = 1
	# The shell backgrounds a grandchild sleep, reports its pid, then
	# waits on it: only a group kill takes the grandchild down too.
	process_result* result = process_run(c"/bin/sh", argv_sh(c"/bin/sleep 30 & echo $!; wait"), opts, 0, 500)
	free(opts)
	assert1(result != 0)
	assert_equal(process_status_timeout, result.status)
	int grandchild = atoi(result.stdout_text)
	assert1(grandchild > 0)
	process_result_free(result)
	int deadline = process_monotonic_ms() + 5000
	while (proc_alive(grandchild) && (process_monotonic_ms() < deadline)): process_sleep_ms(10)
	assert_equal(0, proc_alive(grandchild))
