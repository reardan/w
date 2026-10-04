# wbuild: target=wvmd_test tag=tests dep=wv2
# wbuild: step="bin/wv2 x64 tests/wvmd_test.w -o bin/wvmd_test"
# wbuild: step="bin/wvmd_test" timeout=30000
# Pure control-plane test workers speak the worker protocol and never execute
# guest commands on the host. Real boxes are exercised separately below.
import lib.testing
import lib.vmm.control
import lib.wvm_client


void wvmd_test_worker(json_value* config):
	json_value* ready = json_object()
	json_object_set(ready, c"status", json_int(0))
	jsonrpc_write_value(1, ready)
	json_free(ready)
	frame_reader* reader = frame_reader_new(0)
	while (1):
		json_value* request = jsonrpc_read_message(reader)
		if (request == 0): break
		json_value* args = vms_field(request, c"argv")
		char* name = json_array_get(args, 0).string_value
		if (strcmp(name, c"/wait") == 0): process_sleep_ms(1000)
		if (strcmp(name, c"/crash") == 0): exit(9)
		json_value* response = json_object()
		json_object_set(response, c"status", json_int(7))
		json_object_set(response, c"stdout_hex", json_string(c"610062"))
		json_object_set(response, c"stderr_hex", json_string(c"657272"))
		jsonrpc_write_value(1, response)
		json_free(response)
		json_free(request)
	frame_reader_free(reader)


json_value* wvmd_test_config(int cpus, int memory_mb):
	json_value* value = json_object()
	json_object_set(value, c"kernel", json_string(c"unused-test-kernel"))
	json_object_set(value, c"initrd", json_string(c"unused-test-initrd"))
	json_object_set(value, c"cpus", json_int(cpus))
	json_object_set(value, c"memory_mb", json_int(memory_mb))
	json_object_set(value, c"lease_ms", json_int(10000))
	return value


int wvmd_test_submit(vm_scheduler* scheduler, int cpus, int memory_mb):
	json_value* config = wvmd_test_config(cpus, memory_mb)
	json_value* answer = vms_submit(scheduler, config)
	int id = vms_number(answer, c"session", 0)
	json_free(config)
	json_free(answer)
	return id


void wvmd_test_until(vm_scheduler* scheduler, vms_session* session, int state):
	int deadline = time_monotonic_ms() + 5000
	while (session.state != state && time_monotonic_ms() < deadline):
		vms_tick(scheduler)
		process_sleep_ms(2)
	assert_equal(state, session.state)


void test_scheduler_admission_and_queue():
	vm_scheduler* scheduler = vms_new(2, 1, 2, 256, wvmd_test_worker)
	int first_id = wvmd_test_submit(scheduler, 1, 128)
	vms_tick(scheduler)
	int second_id = wvmd_test_submit(scheduler, 1, 128)
	vms_tick(scheduler)
	int third_id = wvmd_test_submit(scheduler, 1, 128)
	asserts(c"three reservations accepted", first_id > 0 && second_id > 0 && third_id > 0)
	assert_equal(0, wvmd_test_submit(scheduler, 1, 128))
	assert_equal(0, wvmd_test_submit(scheduler, 3, 128))
	assert_equal(0, wvmd_test_submit(scheduler, 1, 512))
	vms_session* first = vms_find(scheduler, first_id)
	vms_session* second = vms_find(scheduler, second_id)
	vms_session* third = vms_find(scheduler, third_id)
	wvmd_test_until(scheduler, first, vms_ready)
	wvmd_test_until(scheduler, second, vms_ready)
	assert_equal(2, scheduler.active)
	assert_equal(2, scheduler.cpus)
	assert_equal(256, scheduler.memory_mb)
	assert_equal(vms_queued, third.state)
	int pid = first.pid
	vms_destroy(scheduler, first)
	asserts(c"destroy reaps worker", kill(pid, 0) < 0)
	wvmd_test_until(scheduler, third, vms_ready)
	assert_equal(2, scheduler.active)
	assert_equal(0, scheduler.queued)
	vms_free(scheduler)


void test_scheduler_commands_crash_and_expiry():
	vm_scheduler* scheduler = vms_new(1, 1, 1, 256, wvmd_test_worker)
	vms_session* session = vms_find(scheduler, wvmd_test_submit(scheduler, 1, 128))
	wvmd_test_until(scheduler, session, vms_ready)
	char** args = strv_new(1)
	strv_set(args, 0, c"/success")
	json_value* params = wvm_client_exec_params(session.id, args, 0, 1000, 16)
	json_value* answer = vms_exec(scheduler, session, params)
	assert_equal(1, vms_number(answer, c"command", 0))
	json_free(answer)
	answer = vms_exec(scheduler, session, params)
	asserts(c"concurrent command rejected", vms_text(answer, c"error") != 0)
	json_free(answer)
	wvmd_test_until(scheduler, session, vms_ready)
	assert_equal(7, session.status)
	answer = vms_result(session, params)
	assert_strings_equal(c"610062", vms_text(answer, c"stdout_hex"))
	assert_equal(3, vms_number(answer, c"stdout_hex_bytes", 0))
	json_free(answer)
	json_object_set(params, c"offset", json_int(1))
	json_object_set(params, c"length", json_int(1))
	answer = vms_result(session, params)
	assert_strings_equal(c"00", vms_text(answer, c"stdout_hex"))
	json_free(answer)
	json_free(params)
	strv_set(args, 0, c"/crash")
	params = wvm_client_exec_params(session.id, args, 0, 1000, 16)
	answer = vms_exec(scheduler, session, params)
	json_free(answer)
	json_free(params)
	wvmd_test_until(scheduler, session, vms_failed)
	assert_equal(0, scheduler.active)
	assert_equal(0, scheduler.cpus)
	assert_equal(0, scheduler.memory_mb)
	int id = session.id
	session.lease_deadline = time_monotonic_ms() - 1
	vms_tick(scheduler)
	asserts(c"expired session removed", vms_find(scheduler, id) == 0)
	assert_equal(1, scheduler.expired)
	free(cast(void*, args))
	vms_free(scheduler)


void test_scheduler_deadline_kills_worker():
	vm_scheduler* scheduler = vms_new(1, 0, 1, 256, wvmd_test_worker)
	vms_session* session = vms_find(scheduler, wvmd_test_submit(scheduler, 1, 128))
	wvmd_test_until(scheduler, session, vms_ready)
	char** args = strv_new(1)
	strv_set(args, 0, c"/wait")
	json_value* params = wvm_client_exec_params(session.id, args, 0, 10, 16)
	json_value* answer = vms_exec(scheduler, session, params)
	json_free(answer)
	json_free(params)
	free(cast(void*, args))
	int pid = session.pid
	session.operation_deadline = time_monotonic_ms() - 1
	vms_tick(scheduler)
	assert_equal(vms_failed, session.state)
	assert_equal(124, session.status)
	asserts(c"deadline reaps worker", kill(pid, 0) < 0)
	vms_free(scheduler)


void test_control_socket_roundtrip():
	string_builder* path = string_new()
	string_append(path, c"bin/wvmd_test_")
	string_append_int(path, getpid())
	string_append(path, c".sock")
	int pid = fork()
	if (pid == 0):
		vm_scheduler* scheduler = vms_new(2, 2, 2, 512, wvmd_test_worker)
		int status = vms_serve(scheduler, path.data)
		vms_free(scheduler)
		exit(status)
	asserts(c"server forks", pid > 0)
	json_value* config = wvmd_test_config(1, 128)
	json_value* envelope = 0
	int deadline = time_monotonic_ms() + 5000
	while (envelope == 0 && time_monotonic_ms() < deadline):
		envelope = wvm_client_call(path.data, c"stats", config, 1000)
		if (envelope == 0): process_sleep_ms(5)
	asserts(c"socket server responds", envelope != 0)
	assert_equal(0, vms_number(vms_field(envelope, c"result"), c"active", -1))
	json_free(envelope)
	envelope = wvm_client_call(path.data, c"vm_spawn", config, 1000)
	asserts(c"spawn responds", envelope != 0)
	int session_id = vms_number(vms_field(envelope, c"result"), c"session", 0)
	asserts(c"spawn returns id", session_id > 0)
	json_free(envelope)
	json_object_set(config, c"private_workspace", json_int(1))
	envelope = wvm_client_call(path.data, c"vm_spawn", config, 1000)
	asserts(c"cannot forge writable workspace", vms_text(vms_field(envelope, c"result"), c"error") != 0)
	json_free(envelope)
	json_free(config)
	json_value* params = wvm_client_session_params(session_id)
	int ready = 0
	while (ready == 0 && time_monotonic_ms() < deadline):
		envelope = wvm_client_call(path.data, c"vm_status", params, 1000)
		asserts(c"status responds", envelope != 0)
		char* state = vms_text(vms_field(envelope, c"result"), c"state")
		ready = state != 0 && strcmp(state, c"ready") == 0
		json_free(envelope)
	assert_equal(1, ready)
	envelope = wvm_client_call(path.data, c"stop", params, 1000)
	asserts(c"stop responds", envelope != 0)
	json_free(envelope)
	json_free(params)
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)
	asserts(c"socket cleaned", socket_connect_unix_path(path.data) < 0)
	string_free(path)


void test_control_rejects_malformed_inputs():
	assert_equal(0, vms_json_safe(c"{\"argv\": [\"/bin/echo\\u0000hidden\"]}"))
	string_builder* nested = string_new()
	for i in range(40): string_append_char(nested, '[')
	for i in range(40): string_append_char(nested, ']')
	assert_equal(0, vms_json_safe(nested.data))
	string_free(nested)
	frame_reader* reader = frame_reader_new(-1)
	char* bad = c"Content-Length: 9999999999999999999999999999\r\n\r\n"
	mem_copy[char](reader.buffer, bad, strlen(bad))
	reader.length = strlen(bad)
	asserts(c"overflow header rejected", vms_take_frame(reader, 8192) == 0)
	assert_equal(1, reader.error)
	frame_reader_free(reader)


void test_scheduler_repeated_cleanup_no_fd_leak():
	list[dir_entry*] before = dir_read(c"/proc/self/fd")
	int baseline = before.length
	dir_entries_free(before)
	vm_scheduler* scheduler = vms_new(1, 0, 1, 128, wvmd_test_worker)
	for i in range(12):
		vms_session* session = vms_find(scheduler, wvmd_test_submit(scheduler, 1, 128))
		wvmd_test_until(scheduler, session, vms_ready)
		vms_destroy(scheduler, session)
	assert_equal(0, scheduler.active)
	assert_equal(0, scheduler.cpus)
	assert_equal(0, scheduler.memory_mb)
	assert_equal(1, scheduler.sessions.length)
	vms_free(scheduler)
	list[dir_entry*] after = dir_read(c"/proc/self/fd")
	assert_equal(baseline, after.length)
	dir_entries_free(after)


int wvmd_test_server(char* path):
	int pid = fork()
	if (pid == 0):
		vm_scheduler* scheduler = vms_new(1, 1, 1, 256, wvmd_test_worker)
		int status = vms_serve(scheduler, path)
		vms_free(scheduler)
		exit(status)
	asserts(c"daemon starts", pid > 0)
	return pid


json_value* wvmd_test_server_ready(char* path):
	json_value* params = json_object()
	json_value* answer = 0
	int deadline = time_monotonic_ms() + 5000
	while (answer == 0 && time_monotonic_ms() < deadline):
		answer = wvm_client_call(path, c"stats", params, 1000)
		if (answer == 0): process_sleep_ms(10)
	json_free(params)
	asserts(c"daemon socket ready", answer != 0)
	return answer


void test_daemon_crash_recovers_owned_workspace():
	string_builder* path = string_new()
	string_append(path, c"bin/wvmd_crash_")
	string_append_int(path, getpid())
	char* source = strjoin(path.data, c"_source")
	assert_equal(0, mkdir(source, 448))
	char* original = strjoin(source, c"/original")
	asserts(c"source file created", file_write_text(original, c"source unchanged"))
	int pid = wvmd_test_server(path.data)
	json_value* answer = wvmd_test_server_ready(path.data)
	json_free(answer)
	json_value* config = wvmd_test_config(1, 128)
	json_object_set(config, c"workspace", json_string(source))
	json_object_set(config, c"workspace_mb", json_int(1))
	answer = wvm_client_call(path.data, c"vm_spawn", config, 1000)
	asserts(c"private session accepted", answer != 0)
	int id = vms_number(vms_field(answer, c"result"), c"session", 0)
	asserts(c"private session ID", id > 0)
	json_free(answer)
	json_free(config)
	json_value* params = wvm_client_session_params(id)
	int ready = 0
	int deadline = time_monotonic_ms() + 5000
	while (ready == 0 && time_monotonic_ms() < deadline):
		answer = wvm_client_call(path.data, c"vm_status", params, 1000)
		asserts(c"private session status", answer != 0)
		char* state = vms_text(vms_field(answer, c"result"), c"state")
		ready = state != 0 && strcmp(state, c"ready") == 0
		json_free(answer)
		if (ready == 0): process_sleep_ms(10)
	assert_equal(1, ready)
	assert_equal(0, kill(pid, sigkill))
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	pid = wvmd_test_server(path.data)
	answer = wvmd_test_server_ready(path.data)
	asserts(c"crash workspace recovered", vms_number(vms_field(answer, c"result"), c"recovered", 0) >= 1)
	assert_equal(0, vms_number(vms_field(answer, c"result"), c"active", -1))
	json_free(answer)
	char* content = file_read_text(original)
	assert_strings_equal(c"source unchanged", content)
	free(content)
	answer = wvm_client_call(path.data, c"stop", params, 1000)
	asserts(c"restarted daemon stops", answer != 0)
	json_free(answer)
	json_free(params)
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)
	char* state_path = strjoin(path.data, c".state")
	assert_equal(0, dir_remove_all(state_path))
	free(state_path)
	assert_equal(0, dir_remove_all(source))
	free(original)
	free(source)
	string_free(path)
