# wbuild: target=wvmd_box_test tag=tests dep=wv2 dep=wvmd dep=wvm_init dep=wvm_box_fixture
# wbuild: step="bin/wv2 x64 tests/wvmd_box_test.w -o bin/wvmd_box_test"
# wbuild: step="bin/wvmd_box_test" timeout=90000
import lib.testing
import lib.ci_skip
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


int wvmd_box_shmem(char* group):
	char* path = strjoin(group, c"/memory.stat")
	char* text = file_read_text(path)
	free(path)
	asserts(c"real cgroup memory accounting readable", text != 0)
	int value = -1
	int at = 0
	while (text[at]):
		if (starts_with(text + at, c"shmem ")):
			value = atoi(text + at + 6)
			break
		while (text[at] && text[at] != '\n'): at = at + 1
		if (text[at]): at = at + 1
	free(text)
	asserts(c"cgroup exposes shmem charge", value >= 0)
	return value


void wvmd_box_quota_clean(char* group, int baseline):
	char* path = strjoin(group, c"/cgroup.procs")
	int deadline = process_monotonic_ms() + 10000
	int clean = 0
	while (process_monotonic_ms() < deadline):
		char* pids = file_read_text(path)
		asserts(c"real cgroup process accounting readable", pids != 0)
		# Kernel charge retirement can lag process exit. File page cache may
		# remain charged; check anonymous memfd shmem rather than total cache.
		clean = strlen(pids) == 0 && wvmd_box_shmem(group) <= baseline + 65536
		free(pids)
		if (clean): break
		process_sleep_ms(10)
	free(path)
	asserts(c"workers and sealed Linux backing released from quota", clean)


void test_daemon_real_concurrent_boxes():
	char* kernel = env_get(c"WVM_TEST_KERNEL")
	if (kernel == 0):
		println(c"SKIP: set WVM_TEST_KERNEL for concurrent daemon Linux boxes")
		return
	char* cgroup = env_get(c"WVM_TEST_CGROUP")
	if (cgroup == 0): test_skip(c"SKIP: set WVM_TEST_CGROUP for Linux box host quota integration")
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
	char** command = strv_new(20)
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
	strv_set(command, 11, c"1024")
	if (cgroup != 0):
		strv_set(command, 12, c"--cgroup")
		strv_set(command, 13, cgroup)
		strv_set(command, 14, c"--host-memory-mb")
		strv_set(command, 15, c"2048")
		strv_set(command, 16, c"--host-cpu-percent")
		strv_set(command, 17, c"400")
		strv_set(command, 18, c"--host-pids")
		strv_set(command, 19, c"128")
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
	json_value* initial_stats = vms_field(envelope, c"result")
	json_value* host_quotas = vms_field(initial_stats, c"host_quotas")
	asserts(c"quota mode reported", host_quotas != 0)
	assert_equal(cgroup != 0, host_quotas.int_value)
	char* quota_path = 0
	int baseline_shmem = 0
	if (cgroup != 0):
		string_builder* quota = string_from(cgroup)
		string_append(quota, c"/wvmd-")
		string_append_int(quota, daemon.pid)
		quota_path = strclone(quota.data)
		string_free(quota)
		baseline_shmem = wvmd_box_shmem(quota_path)
	json_free(envelope)
	json_object_set(params, c"kernel", json_string(kernel))
	json_object_set(params, c"initrd", json_string(c"bin/wvmd_box_test.cpio"))
	json_object_set(params, c"cpus", json_int(1))
	json_object_set(params, c"memory_mb", json_int(256))
	json_object_set(params, c"lease_ms", json_int(60000))
	char* workspace = strjoin(path.data, c".workspace")
	assert_equal(0, mkdir(workspace, 448))
	char* base = strjoin(workspace, c"/base.txt")
	asserts(c"workspace lower created", file_write_text(base, c"immutable base") > 0)
	free(base)
	json_object_set(params, c"workspace", json_string(workspace))
	json_object_set(params, c"workspace_mb", json_int(1))
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
	# Synchronous harness bridge must preserve binary output and run IDs.
	process_result* synchronous = wvm_client_exec_wait(path.data, ids[0], args, c"/", 1000, 128)
	asserts(c"synchronous client result", synchronous != 0)
	assert_equal(9, synchronous.status)
	assert_equal(3, synchronous.stdout_length)
	assert_equal(0, cast(int, synchronous.stdout_text[1]))
	process_result_free(synchronous)
	strv_set(args, 1, c"snapshot-write")
	synchronous = wvm_client_exec_wait(path.data, ids[0], args, c"/", 1000, 128)
	assert_equal(0, synchronous.status)
	process_result_free(synchronous)
	json_value* snapshot_params = wvm_client_session_params(ids[0])
	answer = wvmd_box_call(path.data, c"vm_snapshot", snapshot_params)
	json_free(answer)
	answer = wvmd_box_wait(path.data, ids[0], c"ready")
	assert_equal(0, vms_number(answer, c"status", -1))
	json_free(answer)
	strv_set(args, 1, c"snapshot-read")
	for i in range(2):
		synchronous = wvm_client_exec_wait(path.data, ids[0], args, c"/", 1000, 128)
		assert_equal(0, synchronous.status)
		process_result_free(synchronous)
		answer = wvmd_box_call(path.data, c"vm_restore", snapshot_params)
		json_free(answer)
		answer = wvmd_box_wait(path.data, ids[0], c"ready")
		assert_equal(0, vms_number(answer, c"status", -1))
		json_free(answer)
	json_free(snapshot_params)
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
	assert_equal(11, vms_number(answer, c"completed_commands", -1))
	json_free(answer)
	# Export a live box into the daemon registry. Template backing survives
	# source destruction, supports independent clones, and is revoked only
	# after the final admitted clone releases its reference.
	args = strv_new(2)
	strv_set(args, 0, c"/test")
	strv_set(args, 1, c"snapshot-write")
	synchronous = wvm_client_exec_wait(path.data, ids[2], args, c"/", 1000, 128)
	asserts(c"template source command", synchronous != 0 && synchronous.status == 0)
	process_result_free(synchronous)
	strv_set(args, 1, c"workspace")
	synchronous = wvm_client_exec_wait(path.data, ids[2], args, c"/", 1000, 128)
	asserts(c"private workspace command before capture", synchronous != 0 && synchronous.status == 0)
	process_result_free(synchronous)
	json_value* capture = wvm_client_session_params(ids[2])
	json_object_set(capture, c"backend", json_string(c"box"))
	answer = wvmd_box_call(path.data, c"template_create", capture)
	json_free(answer)
	answer = wvmd_box_wait(path.data, ids[2], c"ready")
	assert_equal(0, vms_number(answer, c"status", -1))
	json_free(answer)
	answer = wvmd_box_call(path.data, c"vm_result", capture)
	int template = vms_number(answer, c"template", 0)
	asserts(c"CoW box template exported", template > 0)
	json_free(answer)
	json_free(capture)
	for i in range(1, 3): wvm_client_destroy(path.data, ids[i])
	if (quota_path != 0):
		asserts(c"sealed template retains full RAM charge after source exits", wvmd_box_shmem(quota_path) >= baseline_shmem + 256 * 1048576)
	assert_equal(0, dir_remove_all(workspace))
	free(workspace)
	json_value* clone = json_object()
	json_object_set(clone, c"backend", json_string(c"box"))
	json_object_set(clone, c"template", json_int(template))
	for i in range(2):
		ids[i] = wvm_client_open(path.data, clone, 30000)
		asserts(c"clone from daemon box template", ids[i] > 0)
	answer = wvmd_box_call(path.data, c"template_destroy", clone)
	json_free(answer)
	answer = wvm_client_result(path.data, c"vm_spawn", clone, 1000)
	asserts(c"destroyed box template rejects new clones", answer == 0)
	json_free(answer)
	json_free(clone)
	strv_set(args, 1, c"workspace-change")
	synchronous = wvm_client_exec_wait(path.data, ids[0], args, c"/", 1000, 128)
	asserts(c"first cloned workspace changed", synchronous != 0 && synchronous.status == 0)
	process_result_free(synchronous)
	strv_set(args, 1, c"workspace-check")
	synchronous = wvm_client_exec_wait(path.data, ids[1], args, c"/", 1000, 128)
	asserts(c"second clone retains independent work files", synchronous != 0 && synchronous.status == 0)
	process_result_free(synchronous)
	strv_set(args, 1, c"snapshot-read")
	for i in range(2):
		synchronous = wvm_client_exec_wait(path.data, ids[i], args, c"/", 1000, 128)
		asserts(c"independent clone retains captured filesystem", synchronous != 0 && synchronous.status == 0)
		process_result_free(synchronous)
		wvm_client_destroy(path.data, ids[i])
	free(cast(void*, args))
	answer = wvmd_box_call(path.data, c"stats", params)
	assert_equal(0, vms_number(answer, c"template_reserved_mb", -1))
	assert_equal(0, vms_number(answer, c"memory_mb", -1))
	assert_equal(0, vms_number(answer, c"active", -1))
	assert_equal(0, vms_number(answer, c"queued", -1))
	assert_equal(0, vms_number(answer, c"cpus", -1))
	assert_equal(0, vms_number(answer, c"workspace_reserved_mb", -1))
	assert_equal(0, vms_number(answer, c"shared_region_bytes", -1))
	assert_equal(0, vms_number(answer, c"cleanup_failures", -1))
	json_free(answer)
	if (quota_path != 0): wvmd_box_quota_clean(quota_path, baseline_shmem)
	answer = wvmd_box_call(path.data, c"stop", params)
	json_free(answer)
	json_free(params)
	assert_equal(0, process_wait_or_kill(daemon, 10000))
	process_free(daemon)
	if (quota_path != 0):
		int quota_fd = open(quota_path, 65536, 0)
		if (quota_fd >= 0): close(quota_fd)
		asserts(c"daemon removed its empty quota leaf", quota_fd < 0)
		free(quota_path)
	string_free(path)
	assert_equal(0, unlink(c"bin/wvmd_box_test.cpio"))
