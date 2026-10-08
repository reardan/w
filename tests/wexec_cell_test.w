# wbuild: target=wexec_cell_test tag=tests dep=wv2 dep=wvmd_cell_fixture
# wbuild: step="bin/wv2 tools/wexec_main.w -o bin/wexec_cell_runner"
# wbuild: step="bin/wv2 x64 tests/wexec_cell_test.w -o bin/wexec_cell_test"
# wbuild: step="bin/wexec_cell_test" timeout=30000
import lib.testing
import lib.vmm.control
import lib.vmm.cell_worker
import lib.ci_skip
import lib.file
import lib.wvm_client


void wexec_cell_worker(json_value* config):
	vms_cell_worker(config)


json_value* wexec_cell_step(char* socket_path):
	json_value* step = json_object()
	json_value* args = json_array()
	json_array_push(args, json_string(c"bin/wvmd_cell_fixture"))
	json_array_push(args, json_string(c"private"))
	json_object_set(step, c"cmd", args)
	json_object_set(step, c"sandbox", json_string(c"cell"))
	json_object_set(step, c"vm_socket", json_string(socket_path))
	json_object_set(step, c"timeout_ms", json_int(1000))
	json_object_set(step, c"expect_stdout", json_string(c"private"))
	return step


int wexec_cell_run_step(json_value* step):
	json_value* manifest = json_object()
	json_value* targets = json_array()
	json_value* target = json_object()
	json_value* steps = json_array()
	json_array_push(steps, json_clone(step))
	json_object_set(target, c"name", json_string(c"cell"))
	json_object_set(target, c"steps", steps)
	# Declared inputs would normally permit caching. Sandbox state must
	# still be consulted on every invocation, including reused handles.
	json_object_set(target, c"inputs", json_array())
	json_array_push(targets, target)
	json_object_set(manifest, c"targets", targets)
	string_builder* path = string_new()
	string_append(path, c"bin/wexec_cell_manifest_")
	string_append_int(path, getpid())
	string_append(path, c".json")
	char* text = json_stringify(manifest)
	file_write_text(path.data, text)
	free(text)
	json_free(manifest)
	char** args = strv_new(4)
	strv_set(args, 0, c"bin/wexec_cell_runner")
	strv_set(args, 1, c"-f")
	strv_set(args, 2, path.data)
	strv_set(args, 3, c"cell")
	process_result* result = process_run(c"bin/wexec_cell_runner", args, 0, 0, 10000)
	free(cast(void*, args))
	unlink(path.data)
	string_free(path)
	asserts(c"wexec runner launched", result != 0)
	int status = result.status
	if (status != 0):
		println(result.stdout_text)
		println(result.stderr_text)
	process_result_free(result)
	return status


void test_wexec_cell_failure_never_executes_on_host():
	json_value* step = wexec_cell_step(c"/nonexistent/wvmd.sock")
	json_value* args = json_array()
	json_array_push(args, json_string(c"/bin/sh"))
	json_array_push(args, json_string(c"-c"))
	json_array_push(args, json_string(c"echo unsafe > bin/wexec_cell_host_escape"))
	json_object_set(step, c"cmd", args)
	unlink(c"bin/wexec_cell_host_escape")
	assert_equal(1, wexec_cell_run_step(step))
	asserts(c"unavailable daemon never falls back", file_read_text(c"bin/wexec_cell_host_escape") == 0)
	json_object_set(step, c"sandbox", json_string(c"unknown"))
	assert_equal(1, wexec_cell_run_step(step))
	asserts(c"unknown sandbox never falls back", file_read_text(c"bin/wexec_cell_host_escape") == 0)
	json_free(step)


void test_wexec_cell_daemon_roundtrip():
	int fd = kvm_open_system()
	if (fd < 0):
		test_skip_kvm(c"SKIP: KVM unavailable for wexec cell roundtrip")
		return
	close(fd)
	string_builder* path = string_new()
	string_append(path, c"bin/wexec_cell_")
	string_append_int(path, getpid())
	string_append(path, c".sock")
	int pid = fork()
	if (pid == 0):
		vm_scheduler* scheduler = vms_new(2, 2, 2, 1024, wexec_cell_worker)
		int status = vms_serve(scheduler, path.data)
		vms_free(scheduler)
		exit(status)
	asserts(c"daemon forked", pid > 0)
	json_value* params = json_object()
	json_value* stats = 0
	int deadline = time_monotonic_ms() + 5000
	while (stats == 0 && time_monotonic_ms() < deadline):
		stats = wvm_client_result(path.data, c"stats", params, 100)
		if (stats == 0): process_sleep_ms(2)
	asserts(c"daemon ready", stats != 0)
	json_free(stats)
	json_value* step = wexec_cell_step(path.data)
	assert_equal(0, wexec_cell_run_step(step))
	assert_equal(0, wexec_cell_run_step(step))
	json_object_set(params, c"image", json_string(c"bin/wvmd_cell_fixture"))
	json_value* created = wvm_client_result(path.data, c"template_create", params, 5000)
	asserts(c"explicit template created", created != 0)
	int id = vms_number(created, c"template", 0)
	json_free(created)
	json_object_set(step, c"vm_template", json_int(id))
	assert_equal(0, wexec_cell_run_step(step))
	json_free(step)
	json_object_set(params, c"template", json_int(id))
	json_value* removed = wvm_client_result(path.data, c"template_destroy", params, 2000)
	asserts(c"explicit template destroyed", removed != 0)
	json_free(removed)
	stats = wvm_client_result(path.data, c"stats", params, 1000)
	assert_equal(3, vms_number(stats, c"spawned", -1))
	assert_equal(0, vms_number(stats, c"template_reserved_mb", -1))
	assert_equal(0, vms_number(stats, c"active", -1))
	assert_equal(0, vms_number(stats, c"memory_mb", -1))
	json_free(stats)
	json_value* stopped = wvm_client_result(path.data, c"stop", params, 1000)
	asserts(c"daemon stops", stopped != 0)
	json_free(stopped)
	json_free(params)
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)
	char* state = strjoin(path.data, c".state")
	assert_equal(0, dir_remove_all(state))
	free(state)
	string_free(path)
