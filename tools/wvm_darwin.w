# Native Apple Silicon CLI and exec-created cell worker.
import lib.vmm.darwin_cell_snapshot
import lib.vmm.darwin_protocol
import lib.file

c_lib "/usr/lib/libSystem.B.dylib"
extern int dvm_isatty(int fd) = "isatty"


int dvm_write_deadline(int fd, char* data, int length, int deadline);


void dvm_cli_error(char* text):
	# Diagnostics must not bypass the I/O deadline when stderr is full.
	int deadline = dhv_now_ms() + 100
	dvm_write_deadline(2, c"wvm: ", 5, deadline)
	dvm_write_deadline(2, text, strlen(text), deadline)
	dvm_write_deadline(2, c"\n", 1, deadline)


int dvm_positive(char* text):
	if (text == 0 || text[0] == 0): return -1
	int n = 0
	int at = 0
	while (text[at]):
		if (text[at] < '0' || text[at] > '9' || n > 10000000): return -1
		n = n * 10 + text[at] - '0'
		at = at + 1
	return n


int dvm_exec_valid(json_value* params):
	if (dvm_keys(params, c"session argv timeout_ms output_limit stdin_hex request protocol") == 0): return 0
	json_value* args = vms_field(params, c"argv")
	if (args == 0 || args.type != json_type_array() || json_array_length(args) < 1 || json_array_length(args) > 128): return 0
	int total = 0
	for i in range(json_array_length(args)):
		json_value* arg = json_array_get(args, i)
		if (arg.type != json_type_string()): return 0
		total = total + strlen(arg.string_value)
		if (total > 4096): return 0
	json_value* input = vms_field(params, c"stdin_hex")
	if (input != 0):
		if (input.type != json_type_string()): return 0
		int bytes = strlen(input.string_value)
		if (bytes > 4096 || bytes % 2 != 0): return 0
		for i in range(bytes):
			int ch = cast(int, input.string_value[i])
			if ((ch < '0' || ch > '9') && (ch < 'a' || ch > 'f')): return 0
	int timeout = vms_number(params, c"timeout_ms", 30000)
	int limit = vms_number(params, c"output_limit", 65536)
	return timeout >= 1 && timeout <= 600000 && limit >= 1 && limit <= 1048576


json_value* dvm_cell_result(darwin_cell* cell, int request):
	json_value* answer = json_object()
	json_object_set(answer, c"protocol", json_int(1))
	json_object_set(answer, c"request", json_int(request))
	json_object_set(answer, c"status", json_int(cell.status))
	char* text = dvm_hex(cell.output.data, cell.output.length)
	json_object_set(answer, c"stdout_hex", json_string(text))
	free(text)
	text = dvm_hex(cell.errors.data, cell.errors.length)
	json_object_set(answer, c"stderr_hex", json_string(text))
	free(text)
	if (cell.error != 0): json_object_set(answer, c"diagnostic", json_string(cell.error))
	json_object_set(answer, c"fault_pc", json_int(cell.fault_pc))
	json_object_set(answer, c"fault_syndrome", json_int(cell.fault_syndrome))
	return answer


int dvm_worker():
	# FD3 is the sole inherited template. The parent owns the channel and
	# guest bytes never become control messages. The worker is always exec'd.
	dvm_signal(13, 1)
	dhv_watchdog_parent_pid = dhv_getppid()
	int available = dhv_probe()
	if (available != 0): return 77
	darwin_cell* cell = darwin_cell_snapshot_from_fd(3)
	close(3)
	if (cell == 0): return 125
	json_value* ready = json_object()
	json_object_set(ready, c"protocol", json_int(1))
	json_object_set(ready, c"request", json_int(0))
	json_object_set(ready, c"status", json_int(0))
	int sent = dvm_send_bounded(1, ready, 3000)
	json_free(ready)
	frame_reader* reader = frame_reader_new(0)
	frame_reader_set_max_body(reader, 8192)
	reader.max_header_bytes = 64
	int last_request = 0
	while (sent):
		json_value* request = dvm_read_deadline(reader, 8192, 3600000)
		if (request == 0): break
		int sequence = vms_number(request, c"request", -1)
		if (vms_number(request, c"protocol", -1) != 1 || sequence <= last_request || dvm_exec_valid(request) == 0):
			json_free(request)
			break
		last_request = sequence
		if (darwin_cell_snapshot_reset(cell) == 0):
			json_free(request)
			break
		json_value* values = vms_field(request, c"argv")
		int count = json_array_length(values)
		char** args = strv_new(count)
		for i in range(count): strv_set(args, i, json_array_get(values, i).string_value)
		char* owned_input = 0
		char* input_hex = vms_text(request, c"stdin_hex")
		if (input_hex != 0):
			int length = strlen(input_hex) / 2
			owned_input = cast(char*, malloc(length + 1))
			for i in range(length):
				int value = 0
				for j in range(2):
					int digit = cast(int, input_hex[i * 2 + j]) - '0'
					if (digit > 9): digit = digit - 39
					value = value * 16 + digit
				owned_input[i] = cast(char, value)
			cell.input = owned_input
			cell.input_length = length
		cell.output_limit = vms_number(request, c"output_limit", 65536)
		if (darwin_cell_stack(cell, count, args)):
			darwin_cell_run(cell, vms_number(request, c"timeout_ms", 30000))
		free(cast(void*, args))
		free(owned_input)
		json_value* answer = dvm_cell_result(cell, sequence)
		json_free(request)
		sent = dvm_send_bounded(1, answer, 3000)
		json_free(answer)
	frame_reader_free(reader)
	darwin_cell_free(cell)
	return 0



# Redirected input is bounded and subject to the command deadline. Never
# wait for an interactive terminal. Restore the caller's descriptor flags.
string_builder* dvm_cli_input(int deadline):
	string_builder* input = string_new()
	if ((dvm_isatty(0) & 255) != 0): return input
	int flags = sys_fcntl(0, 3, 0)
	if (flags < 0): return input
	socket_set_nonblocking(0)
	char[4096] buffer
	int ok = 1
	while (1):
		int left = deadline - dhv_now_ms()
		if (left <= 0):
			ok = 0
			break
		int ready = poll_single(0, poll_in, left)
		if (ready == -4): continue
		if (ready <= 0):
			ok = 0
			break
		int count = read(0, buffer, 4096)
		if (count == 0): break
		if (count == -4 || count == 0 - net_eagain()): continue
		if (count < 0 || count > 4194304 - input.length):
			ok = 0
			break
		string_append_bytes(input, buffer, count)
	sys_fcntl(0, 4, flags)
	if (ok): return input
	string_free(input)
	return 0

int dvm_write_deadline(int fd, char* data, int length, int deadline):
	int flags = sys_fcntl(fd, 3, 0)
	if (flags < 0): return 0
	socket_set_nonblocking(fd)
	int sent = 0
	while (sent < length):
		int left = deadline - dhv_now_ms()
		if (left <= 0): break
		int ready = poll_single(fd, poll_out, left)
		if (ready == -4): continue
		if (ready <= 0): break
		int count = write(fd, data + sent, length - sent)
		if (count == -4 || count == 0 - net_eagain()): continue
		if (count <= 0): break
		sent = sent + count
	sys_fcntl(fd, 4, flags)
	return sent == length


int dvm_cli_main(int argc, char** args):
	dvm_signal(13, 1)
	if (argc == 2 && strcmp(args[1], c"worker") == 0): return dvm_worker()
	if (argc == 2 && strcmp(args[1], c"capabilities") == 0):
		json_value* value = dvm_capabilities()
		int status = dhv_probe()
		json_object_set(value, c"available", json_bool(status == 0))
		json_object_set(value, c"diagnostic", json_string(dhv_error_message(status)))
		char* text = json_stringify(value)
		println(text)
		free(text)
		json_free(value)
		if (status != 0): return 77
		return 0
	if (argc == 2 && strcmp(args[1], c"available") == 0):
		int status = dhv_probe()
		if (status == 0): return 0
		dvm_cli_error(dhv_error_message(status))
		return 77
	if (argc < 3 || strcmp(args[1], c"run") != 0):
		dvm_cli_error(c"usage: wvm run [--timeout-ms N] [--output-limit N] <file.w|static-arm64-elf> [args...]; available; capabilities")
		return 2
	int at = 2
	int timeout = 30000
	int output_limit = 4194304
	while (at < argc && args[at][0] == '-'):
		char* option = args[at]
		at = at + 1
		if (at >= argc): return 2
		int value = dvm_positive(args[at])
		at = at + 1
		if (strcmp(option, c"--timeout-ms") == 0): timeout = value
		else if (strcmp(option, c"--output-limit") == 0): output_limit = value
		else:
			dvm_cli_error(c"unsupported-option: Darwin cells reject filesystem, network, threads, quotas and live checkpoints")
			return 2
	if (at >= argc || timeout < 1 || timeout > 600000 || output_limit < 1 || output_limit > 4194304): return 2
	char* image = args[at]
	char* temporary = 0
	char* temp_directory = 0
	int length = strlen(image)
	if (length > 2 && image[length - 2] == '.' && image[length - 1] == 'w'):
		char* compiler = env_get(c"W_DARWIN_COMPILER")
		if (compiler == 0): compiler = c"bin/wv2_darwin"
		char[64] pattern
		strcpy(pattern, c"/tmp/wvm-compile.XXXXXX")
		if (mkdtemp(pattern) == 0): return 125
		temp_directory = strclone(pattern)
		temporary = strjoin(temp_directory, c"/guest")
		char** compile_args = strv_new(5)
		strv_set(compile_args, 0, compiler)
		strv_set(compile_args, 1, c"arm64")
		strv_set(compile_args, 2, image)
		strv_set(compile_args, 3, c"-o")
		strv_set(compile_args, 4, temporary)
		process_result* result = process_run(compiler, compile_args, 0, 0, 60000)
		free(cast(void*, compile_args))
		int compiled = result != 0 && result.status == 0
		if (result != 0): process_result_free(result)
		if (compiled == 0):
			dvm_cli_error(c"ARM64 guest compilation failed")
			unlink(temporary)
			free(temporary)
			rmdir(temp_directory)
			free(temp_directory)
			return 125
		image = temporary
	int deadline = dhv_now_ms() + timeout
	string_builder* input = dvm_cli_input(deadline)
	darwin_cell* cell = darwin_cell_new()
	int status = 125
	if (cell != 0 && input != 0):
		cell.input = input.data
		cell.input_length = input.length
		cell.output_limit = output_limit
		if (darwin_cell_load(cell, image) && darwin_cell_stack(cell, argc - at, &args[at])):
			darwin_cell_run(cell, deadline - dhv_now_ms())
		status = cell.status
		if (dvm_write_deadline(1, cell.output.data, cell.output.length, deadline) == 0): status = 125
		if (dvm_write_deadline(2, cell.errors.data, cell.errors.length, deadline) == 0): status = 125
		if (cell.error != 0): dvm_cli_error(cell.error)
	darwin_cell_free(cell)
	if (input != 0): string_free(input)
	else: dvm_cli_error(c"input limit or deadline exceeded")
	if (temporary != 0):
		unlink(temporary)
		free(temporary)
		rmdir(temp_directory)
		free(temp_directory)
	return status

# Native tools use the native bootstrap compiler and are signed after copying
# to a fresh inode. The no-skip gate also supports an isolated pinned seed.
# wbuild: target=wvm_darwin dep=build_darwin
# wbuild: step="bin/wv2_darwin arm64_darwin --strict tools/wvm.w -o bin/wvm_darwin.raw"
# wbuild: step="cp bin/wvm_darwin.raw bin/wvm_darwin.new"
# wbuild: step="codesign --force --sign - --entitlements tools/mac/hypervisor.entitlements bin/wvm_darwin.new"
# wbuild: step="mv -f bin/wvm_darwin.new bin/wvm_darwin"
# wbuild: target=wvmd_darwin dep=build_darwin dep=wvm_darwin
# wbuild: step="bin/wv2_darwin arm64_darwin --strict tools/wvmd.w -o bin/wvmd_darwin.raw"
# wbuild: step="cp bin/wvmd_darwin.raw bin/wvmd_darwin.new"
# wbuild: step="codesign --force --sign - --entitlements tools/mac/hypervisor.entitlements bin/wvmd_darwin.new"
# wbuild: step="mv -f bin/wvmd_darwin.new bin/wvmd_darwin"
# wbuild: target=vm_darwin_native_test data=tools/mac/run_vm_tests.sh data=tools/mac/vm_test_runner.py data=tools/mac/hypervisor.entitlements data=tools/mac/measure_vm_memory.py data=tools/mac/measure_vm_lifecycle.py data=tests/wvm_darwin_e2e.py data=tests/wvm_darwin_recovery.py data=tests/hv_darwin_test.w data=tests/wvm_darwin_fixture.w data=tests/wvm_darwin_cell_test.w data=tests/wvm_darwin_snapshot_fixture.w data=tests/wvm_darwin_cell_snapshot_fixture.w data=tests/wvm_darwin_pool_fixture.w data=tests/wvm_darwin_memory_fixture.w data=lib/vmm/darwin_hv.w data=lib/vmm/darwin_cell.w data=lib/vmm/darwin_snapshot.w data=lib/vmm/darwin_cell_snapshot.w data=lib/vmm/darwin_pool.w data=lib/vmm/darwin_control.w data=lib/vmm/darwin_protocol.w data=tools/wvm.w data=tools/wvmd.w data=tools/wvm_darwin.w data=tools/wvmd_darwin.w
# wbuild: step="sh tools/mac/run_vm_tests.sh" timeout=600000
