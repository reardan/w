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
	int i = 0
	while (i < size):
		text[i] = 'a' + (i % 26)
		i = i + 1
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
	assert_equal(process_status_timeout(), result.status)
	# Nowhere near the 5s the child asked for.
	assert1(elapsed < 3000)
	process_result_free(result)


void test_wait_timeout_leaves_child_running():
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/sleep")
	strv_set(argv, 1, c"5")
	process* p = process_spawn(c"/bin/sleep", argv, 0)
	assert1(p != 0)
	assert_equal(process_status_timeout(), process_wait_timeout(p, 100))
	# Still alive: try_wait sees it running, then the kill path reaps it.
	assert_equal(process_status_running(), process_try_wait(p))
	assert_equal(0, process_kill(p, sigkill()))
	assert_equal(128 + sigkill(), process_wait(p))
	process_free(p)


void test_signal_death_decodes_as_128_plus_signum():
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/sleep")
	strv_set(argv, 1, c"5")
	process* p = process_spawn(c"/bin/sleep", argv, 0)
	assert1(p != 0)
	assert_equal(0, process_kill(p, sigterm()))
	assert_equal(128 + sigterm(), process_wait(p))
	# Reaped results are cached.
	assert_equal(128 + sigterm(), process_wait(p))
	assert_equal(128 + sigterm(), process_try_wait(p))
	process_free(p)


void test_spawn_with_piped_streams_and_manual_wait():
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe()
	opts.stdout_mode = process_pipe()
	opts.stderr_mode = process_null()
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
