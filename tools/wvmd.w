# wbuild: binary=wvmd arch=x64
# Foreground persistent Linux-box scheduler; no host-execution fallback.
import tools.__arch__.wvmd_platform
import lib.vmm.control
import lib.vmm.box_snapshot
import lib.wvm_client
import lib.vmm.cell_worker


char* wvmd_hex(char* data, int length):
	char* result = cast(char*, malloc(length * 2 + 1))
	char* digits = c"0123456789abcdef"
	for i in range(length):
		int value = cast(int, data[i]) & 255
		result[i * 2] = digits[value >> 4]
		result[i * 2 + 1] = digits[value & 15]
	result[length * 2] = 0
	return result


void wvmd_worker(json_value* config):
	if (vms_worker_snapshot != 0):
		vms_cell_worker(config)
		return
	vm_box_options* options = box_options_new()
	options.kernel = vms_text(config, c"kernel")
	options.initrd = vms_text(config, c"initrd")
	options.channel_directory = vms_text(config, c"channel_directory")
	options.fs_root = vms_text(config, c"fs_root")
	if (vms_number(config, c"private_workspace", 0)): options.workspace_mb = vms_number(config, c"workspace_mb", 64)
	options.cpus = vms_number(config, c"cpus", 1)
	options.memory_mb = vms_number(config, c"memory_mb", 256)
	options.timeout_ms = vms_number(config, c"timeout_ms", 30000)
	vm_box_session* box = 0
	if (vms_worker_box != 0): box = box_snapshot_restore_in(vms_worker_box, options.timeout_ms, options.channel_directory)
	else: box = box_session_open(options)
	free(options)
	json_value* ready = json_object()
	int status = 0
	if (box == 0): status = 125
	json_object_set(ready, c"status", json_int(status))
	if (box != 0): json_object_set(ready, c"channel_directory", json_string(box.directory))
	jsonrpc_write_value(1, ready)
	json_free(ready)
	if (box == 0): return
	box_snapshot* snapshot = 0
	frame_reader* reader = frame_reader_new(0)
	while (1):
		json_value* request = jsonrpc_read_message(reader)
		if (request == 0): break
		char* operation = vms_text(request, c"operation")
		if (operation != 0):
			status = 125
			if (strcmp(operation, c"template") == 0):
				box_snapshot* captured = box_snapshot_create_cow(box, 30000)
				if (captured != 0):
					if (vm_backing_send(vms_worker_export, captured.fd) && vm_backing_send(vms_worker_export, captured.ram_fd)): status = 0
					else: status = box_status_transport
					box_snapshot_free(captured)
			else if (strcmp(operation, c"snapshot") == 0):
				box_snapshot* captured = box_snapshot_create(box, 30000)
				if (captured != 0):
					box_snapshot_free(snapshot)
					snapshot = captured
					status = 0
			else if (strcmp(operation, c"restore") == 0 && snapshot != 0):
				vm_box_session* restored = box_snapshot_restore_in(snapshot, 30000, vms_text(config, c"channel_directory"))
				if (restored != 0):
					box_session_close(box)
					box = restored
					status = 0
			json_value* answer = json_object()
			if (box.alive == 0): status = box_status_transport
			json_object_set(answer, c"status", json_int(status))
			json_object_set(answer, c"channel_directory", json_string(box.directory))
			int sent = jsonrpc_write_value(1, answer)
			json_free(answer)
			json_free(request)
			if (sent < 0 || status < 0): break
			continue
		json_value* input_args = vms_field(request, c"argv")
		int count = json_array_length(input_args)
		char** args = strv_new(count)
		for i in range(count): strv_set(args, i, json_array_get(input_args, i).string_value)
		process_result* result = box_session_exec(box, args, vms_text(request, c"cwd"), vms_number(request, c"timeout_ms", 30000), vms_number(request, c"output_limit", 65536))
		free(cast(void*, args))
		json_free(request)
		json_value* answer = json_object()
		status = 125
		if (result != 0):
			status = result.status
			char* output = wvmd_hex(result.stdout_text, result.stdout_length)
			json_object_set(answer, c"stdout_hex", json_string(output))
			free(output)
			output = wvmd_hex(result.stderr_text, result.stderr_length)
			json_object_set(answer, c"stderr_hex", json_string(output))
			free(output)
			process_result_free(result)
		json_object_set(answer, c"status", json_int(status))
		int sent = jsonrpc_write_value(1, answer)
		json_free(answer)
		if (sent < 0 || status < 0): break
	frame_reader_free(reader)
	box_snapshot_free(snapshot)
	box_session_close(box)


int wvmd_positive(char* text):
	int value = 0
	int at = 0
	while (text[at] != 0):
		if (text[at] < '0' || text[at] > '9' || value > 1048576): return -1
		value = value * 10 + text[at] - '0'
		at = at + 1
	return value


int main(int argc, int argv):
	char** args = cast(char**, argv)
	int platform_status = wvmd_platform_main(argc, args)
	if (platform_status >= 0): return platform_status
	if (argc >= 4 && strcmp(args[1], c"call") == 0):
		json_value* params = json_object()
		if (argc == 5):
			json_free(params)
			params = json_parse(args[4])
		if (params == 0): return 2
		json_value* response = wvm_client_call(args[2], args[3], params, 15000)
		json_free(params)
		if (response == 0): return 125
		char* text = json_stringify(response)
		print_string(text, c"\n")
		free(text)
		json_free(response)
		return 0
	if (argc < 2 || strcmp(args[1], c"serve") != 0):
		print_string(c"usage: wvmd serve [--socket PATH] [--max-active N] [--max-pending N] [--cpus N] [--memory-mb N] [--workspace-mb N] [--cgroup PARENT --host-cpu-percent N --host-memory-mb N --host-pids N]", c"\n")
		print_string(c"       wvmd call SOCKET METHOD [JSON_PARAMS]", c"\n")
		return 2
	char* path = c"bin/wvmd.sock"
	int active = 4
	int pending = 16
	int cpus = 8
	int memory_mb = 2048
	char* cgroup_parent = 0
	int host_cpu = 800
	int host_memory = 4096
	int host_pids = 512
	int host_options = 0
	int disk_mb = 1024
	int at = 2
	while (at + 1 < argc):
		char* option = args[at]
		char* value = args[at + 1]
		at = at + 2
		if (strcmp(option, c"--socket") == 0): path = value
		else if (strcmp(option, c"--max-active") == 0): active = wvmd_positive(value)
		else if (strcmp(option, c"--max-pending") == 0): pending = wvmd_positive(value)
		else if (strcmp(option, c"--cpus") == 0): cpus = wvmd_positive(value)
		else if (strcmp(option, c"--memory-mb") == 0): memory_mb = wvmd_positive(value)
		else if (strcmp(option, c"--workspace-mb") == 0): disk_mb = wvmd_positive(value)
		else if (strcmp(option, c"--cgroup") == 0): cgroup_parent = value
		else if (strcmp(option, c"--host-cpu-percent") == 0):
			host_cpu = wvmd_positive(value)
			host_options = 1
		else if (strcmp(option, c"--host-memory-mb") == 0):
			host_memory = wvmd_positive(value)
			host_options = 1
		else if (strcmp(option, c"--host-pids") == 0):
			host_pids = wvmd_positive(value)
			host_options = 1
		else: return 2
	if (host_options && cgroup_parent == 0): return 2
	if (at != argc || disk_mb < 1 || disk_mb > 1048576): return 2
	vm_scheduler* scheduler = vms_new(active, pending, cpus, memory_mb, wvmd_worker)
	if (scheduler == 0): return 2
	if (cgroup_parent != 0):
		scheduler.cgroup = vm_cgroup_new(cgroup_parent, host_cpu, host_memory, host_pids)
		if (scheduler.cgroup == 0):
			println(c"wvmd: cannot install delegated cgroup v2 quotas")
			vms_free(scheduler)
			return 125
	scheduler.max_disk_mb = disk_mb
	int status = vms_serve(scheduler, path)
	if (vms_free(scheduler) == 0):
		char* error = c"wvmd: resource cleanup failed\n"
		write(2, error, strlen(error))
		return 125
	return status
