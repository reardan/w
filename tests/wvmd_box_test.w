# wbuild: target=wvmd_box_test tag=tests dep=wv2 dep=wvmd dep=wvm_init dep=wvm_box_fixture
# wbuild: step="bin/wv2 x64 tests/wvmd_box_test.w -o bin/wvmd_box_test"
# wbuild: step="bin/wvmd_box_test" timeout=90000
import lib.testing
import lib.wvm_client
import lib.vmm.scheduler
import lib.file


void wvmd_box_hex(string_builder* archive, int value):
	char* digits = c"0123456789abcdef"
	for i in range(8):
		string_append_char(archive, digits[(value >> ((7 - i) * 4)) & 15])


void wvmd_box_pad(string_builder* archive):
	while (archive.length % 4): string_append_char(archive, 0)


# Minimal newc writer, including console device before PID 1 starts.
void wvmd_box_entry(string_builder* archive, char* name, int mode, char* data, int size, int major, int minor):
	string_append(archive, c"070701")
	wvmd_box_hex(archive, 1)
	wvmd_box_hex(archive, mode)
	wvmd_box_hex(archive, 0)
	wvmd_box_hex(archive, 0)
	wvmd_box_hex(archive, 1)
	wvmd_box_hex(archive, 0)
	wvmd_box_hex(archive, size)
	wvmd_box_hex(archive, 0)
	wvmd_box_hex(archive, 0)
	wvmd_box_hex(archive, major)
	wvmd_box_hex(archive, minor)
	wvmd_box_hex(archive, strlen(name) + 1)
	wvmd_box_hex(archive, 0)
	string_append_bytes(archive, name, strlen(name) + 1)
	wvmd_box_pad(archive)
	if (size > 0): string_append_bytes(archive, data, size)
	wvmd_box_pad(archive)


void wvmd_box_file(string_builder* archive, char* name, char* path):
	int fd = open(path, 0, 0)
	asserts(c"initramfs source opened", fd >= 0)
	int size = file_size(fd)
	close(fd)
	char* data = file_read_text(path)
	asserts(c"initramfs source read", data != 0)
	wvmd_box_entry(archive, name, 33261, data, size, 0, 0)
	free(data)


json_value* wvmd_box_call(char* socket_path, char* method, json_value* params):
	json_value* envelope = wvm_client_call(socket_path, method, params, 15000)
	asserts(c"daemon RPC answered", envelope != 0)
	json_value* result = vms_field(envelope, c"result")
	asserts(c"daemon RPC result", result != 0)
	asserts(c"daemon operation accepted", vms_text(result, c"error") == 0)
	json_value* owned = json_clone(result)
	json_free(envelope)
	return owned


json_value* wvmd_box_wait(char* socket_path, int id, char* state):
	json_value* params = wvm_client_session_params(id)
	int deadline = time_monotonic_ms() + 30000
	json_value* answer = 0
	while (time_monotonic_ms() < deadline):
		answer = wvmd_box_call(socket_path, c"vm_status", params)
		if (strcmp(vms_text(answer, c"state"), state) == 0): break
		asserts(c"guest session did not fail", strcmp(vms_text(answer, c"state"), c"failed") != 0)
		json_free(answer)
		answer = 0
		process_sleep_ms(10)
	json_free(params)
	asserts(c"session became ready", answer != 0)
	return answer


void test_daemon_real_concurrent_boxes():
	char* kernel = env_get(c"WVM_TEST_KERNEL")
	if (kernel == 0):
		println(c"SKIP: set WVM_TEST_KERNEL for concurrent daemon Linux boxes")
		return
	string_builder* archive = string_new()
	wvmd_box_entry(archive, c"dev", 16877, 0, 0, 0, 0)
	wvmd_box_entry(archive, c"dev/console", 8576, 0, 0, 5, 1)
	wvmd_box_file(archive, c"init", c"bin/wvm_init")
	wvmd_box_file(archive, c"test", c"bin/wvm_box_fixture")
	wvmd_box_entry(archive, c"TRAILER!!!", 0, 0, 0, 0, 0)
	io_result written
	assert_equal(IO_OK, file_write_text_checked(c"bin/wvmd_box_test.cpio", archive.data, archive.length, &written))
	string_free(archive)
	string_builder* path = string_new()
	string_append(path, c"bin/wvmd_box_test_")
	string_append_int(path, getpid())
	string_append(path, c".sock")
	char** command = strv_new(13)
	strv_set(command, 0, c"bin/wvmd")
	strv_set(command, 1, c"serve")
	strv_set(command, 2, c"--socket")
	strv_set(command, 3, path.data)
	strv_set(command, 4, c"--max-active")
	strv_set(command, 5, c"2")
	strv_set(command, 6, c"--max-pending")
	strv_set(command, 7, c"1")
	strv_set(command, 8, c"--cpus")
	strv_set(command, 9, c"2")
	strv_set(command, 10, c"--memory-mb")
	strv_set(command, 11, c"512")
	process* daemon = process_spawn(command[0], command, 0)
	free(cast(void*, command))
	asserts(c"daemon started", daemon != 0)
	int deadline = time_monotonic_ms() + 5000
	json_value* params = json_object()
	json_value* envelope = 0
	while (envelope == 0 && time_monotonic_ms() < deadline):
		envelope = wvm_client_call(path.data, c"stats", params, 1000)
		if (envelope == 0): process_sleep_ms(10)
	asserts(c"daemon ready", envelope != 0)
	json_free(envelope)
	json_object_set(params, c"kernel", json_string(kernel))
	json_object_set(params, c"initrd", json_string(c"bin/wvmd_box_test.cpio"))
	json_object_set(params, c"cpus", json_int(1))
	json_object_set(params, c"memory_mb", json_int(256))
	json_object_set(params, c"lease_ms", json_int(60000))
	int[3] ids
	for i in range(3):
		json_value* answer = wvmd_box_call(path.data, c"vm_spawn", params)
		ids[i] = vms_number(answer, c"session", 0)
		json_free(answer)
	for i in range(2):
		json_value* answer = wvmd_box_wait(path.data, ids[i], c"ready")
		print_int(c"concurrent Linux session launch ms: ", vms_number(answer, c"launch_ms", -1))
		json_free(answer)
	json_value* third = wvm_client_session_params(ids[2])
	json_value* answer = wvmd_box_call(path.data, c"vm_status", third)
	assert_strings_equal(c"queued", vms_text(answer, c"state"))
	json_free(answer)
	json_free(third)
	char** args = strv_new(2)
	strv_set(args, 0, c"/test")
	strv_set(args, 1, c"output")
	for turn in range(2):
		for i in range(2):
			json_value* request = wvm_client_exec_params(ids[i], args, c"/", 1000, 128)
			answer = wvmd_box_call(path.data, c"vm_exec", request)
			assert_equal(turn + 1, vms_number(answer, c"command", 0))
			json_free(answer)
			json_free(request)
		for i in range(2):
			answer = wvmd_box_wait(path.data, ids[i], c"ready")
			assert_equal(9, vms_number(answer, c"status", -1))
			json_free(answer)
			json_value* request = wvm_client_session_params(ids[i])
			answer = wvmd_box_call(path.data, c"vm_result", request)
			assert_strings_equal(c"610062", vms_text(answer, c"stdout_hex"))
			assert_equal(12, vms_number(answer, c"stderr_hex_bytes", -1))
			json_free(answer)
			json_free(request)
	free(cast(void*, args))
	json_value* first = wvm_client_session_params(ids[0])
	answer = wvmd_box_call(path.data, c"vm_destroy", first)
	json_free(answer)
	json_free(first)
	answer = wvmd_box_wait(path.data, ids[2], c"ready")
	json_free(answer)
	answer = wvmd_box_call(path.data, c"stats", params)
	assert_equal(2, vms_number(answer, c"active", -1))
	assert_equal(0, vms_number(answer, c"queued", -1))
	assert_equal(4, vms_number(answer, c"completed_commands", -1))
	json_free(answer)
	answer = wvmd_box_call(path.data, c"stop", params)
	json_free(answer)
	json_free(params)
	assert_equal(0, process_wait_or_kill(daemon, 10000))
	process_free(daemon)
	string_free(path)
	assert_equal(0, unlink(c"bin/wvmd_box_test.cpio"))
