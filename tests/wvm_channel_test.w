# wbuild: target=wvm_channel_test tag=tests dep=wv2
# wbuild: step="bin/wv2 x64 tests/wvm_channel_test.w -o bin/wvm_channel_test"
# wbuild: step="bin/wvm_channel_test" timeout=30000
import lib.testing
import lib.vmm.box
import lib.vmm.guest_agent


vm_box_session* channel_test_session():
	int[2] pair
	assert_equal(0, socket_pair(&pair[0]))
	int pid = fork()
	asserts(c"fork guest service", pid >= 0)
	if (pid == 0):
		close(pair[0])
		int status = box_guest_serve(pair[1], 1)
		close(pair[1])
		exit(status)
	close(pair[1])
	vm_box_session* session = new vm_box_session()
	mem_fill[char](cast(char*, session), 0, sizeof(vm_box_session))
	session.fd = pair[0]
	session.alive = 1
	session.child = new process()
	mem_fill[char](cast(char*, session.child), 0, sizeof(process))
	session.child.pid = pid
	session.child.stdin_fd = -1
	session.child.stdout_fd = -1
	session.child.stderr_fd = -1
	socket_set_nonblocking(session.fd)
	char[4] hello
	assert_equal(1, box_channel_io(session.fd, &hello[0], 4, 0, 1, process_monotonic_ms() + 2000))
	assert_equal(box_channel_magic, load_int32(&hello[0]))
	return session


process_result* channel_test_exec(vm_box_session* session, char* script, int timeout_ms, int limit):
	char** args = strv_new(3)
	strv_set(args, 0, c"/bin/sh")
	strv_set(args, 1, c"-c")
	strv_set(args, 2, script)
	process_result* result = box_session_exec(session, args, c"/", timeout_ms, limit)
	free(cast(void*, args))
	asserts(c"command returned result", result != 0)
	return result


void test_channel_persistent_commands():
	vm_box_session* session = channel_test_session()
	process_result* result = channel_test_exec(session, c"printf 'out'; printf 'err' >&2; exit 7", 1000, 1024)
	assert_equal(7, result.status)
	assert_strings_equal(c"out", result.stdout_text)
	assert_strings_equal(c"err", result.stderr_text)
	process_result_free(result)
	result = channel_test_exec(session, c"printf 'a\\000b'; pwd", 1000, 1024)
	assert_equal(0, result.status)
	assert_equal(5, result.stdout_length)
	assert_equal(0, cast(int, result.stdout_text[1]))
	assert_equal(98, cast(int, result.stdout_text[2]))
	process_result_free(result)
	box_session_close(session)


void test_channel_deadline_and_output_bound():
	vm_box_session* session = channel_test_session()
	process_result* result = channel_test_exec(session, c"sleep 5", 50, 1024)
	assert_equal(process_status_timeout, result.status)
	process_result_free(result)
	result = channel_test_exec(session, c"while :; do printf '12345678'; printf 'abcdefgh' >&2; done", 1000, 37)
	assert_equal(box_status_output_limit, result.status)
	asserts(c"bounded stdout", result.stdout_length <= 37)
	asserts(c"bounded stderr", result.stderr_length <= 37)
	process_result_free(result)
	result = channel_test_exec(session, c"exit 3", 1000, 1024)
	assert_equal(3, result.status)
	process_result_free(result)
	box_session_cancel(session)
	assert_equal(0, session.alive)
	assert_equal(-1, session.fd)
	box_session_close(session)


void test_channel_validation_and_disconnect():
	char** args = strv_new(2)
	strv_set(args, 0, c"/bin/echo")
	strv_set(args, 1, c"spaces ; $(are literal)")
	int length = 0
	char* request = box_channel_request(args, c"/tmp", 100, 100, &length)
	asserts(c"request encoded", request != 0)
	char* cwd = 0
	char** decoded = box_channel_decode(request, request + 24, &cwd)
	asserts(c"request decoded", decoded != 0)
	assert_strings_equal(c"/tmp", cwd)
	assert_strings_equal(args[1], decoded[1])
	free(cwd)
	box_channel_args_free(decoded)
	save_int32(request + 8, 129)
	assert_equal(0, cast(int, box_channel_decode(request, request + 24, &cwd)))
	save_int32(request + 8, 2)
	save_int32(request + 28, -1)
	assert_equal(0, cast(int, box_channel_decode(request, request + 24, &cwd)))
	free(request)
	assert_equal(0, cast(int, box_channel_request(args, 0, 0, 100, &length)))
	strv_set(args, 0, c"relative")
	assert_equal(0, cast(int, box_channel_request(args, 0, 100, 100, &length)))
	free(cast(void*, args))
	vm_box_session* session = channel_test_session()
	process_kill(session.child, sigkill)
	process_wait(session.child)
	process_result* result = channel_test_exec(session, c"exit 0", 100, 100)
	assert_equal(box_status_transport, result.status)
	assert_equal(0, session.alive)
	process_result_free(result)
	box_session_close(session)
